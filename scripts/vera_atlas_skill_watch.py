#!/usr/bin/env python3
"""Read genuine DSH skill and file-read tool/call records for Atlas.

No model calls, no session modifications, no skill execution. Historical calls
are intentionally not replayed as live activity on first installation.
"""
from __future__ import annotations
import argparse
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import time
from pathlib import Path

from vera_atlas_access import new_access_id, record_access

HOME = Path.home()
# Opt-in: no private DSH session scanning until a folder is explicitly set.
SESSIONS = Path(os.environ.get("VERA_ATLAS_DSH_SESSIONS_DIR",
                              str(HOME / "Library/Application Support/VeraAtlas/disabled-sessions")))
SKILLS = Path(os.environ.get("VERA_ATLAS_DSH_SKILLS_DIR",
                            str(HOME / "Library/Application Support/VeraAtlas/disabled-skills")))
STATE = HOME / "Library/Application Support/VeraAtlas/skill-watch-state.json"
LOCK = HOME / "Library/Application Support/VeraAtlas/skill-watch.lock"
EXTRA: set[str] = set()
VALID = re.compile(r"^[a-z0-9][a-z0-9_-]{0,79}$")
POLL_SECONDS = 2.0

def available() -> set[str]:
    result = set(EXTRA)
    if SKILLS.is_dir():
        for path in SKILLS.iterdir():
            if VALID.fullmatch(path.name) and (path / "SKILL.md").is_file():
                result.add(path.name)
    return result

def skill_id(name: str) -> str:
    return "k-" + hashlib.sha256(("dsh-skill:" + name).encode()).hexdigest()[:24]

ALLOWED_SUFFIX = frozenset({
    ".md", ".txt", ".py", ".swift", ".js", ".ts", ".mjs", ".html", ".json",
    ".yml", ".yaml", ".sh", ".plist", ".css", ".toml", ".xml", ".sql",
})
# Only metadata about local project files / canon. Never watch credential files.
SECRET_WORDS = ("secret", "credential", "token", ".env", "password", "private", "keychain")

# Closed catalog of real external-tool calls observed in native Harness sessions.
# Not a generic shell parser: no arguments, paths, payloads or message bodies are logged.
TOOL_CALLS = frozenset({
    "bash", "grep", "glob", "web_fetch", "web_search", "read_image",
    "send_message", "schedule_list", "schedule_view", "schedule_edit",
    "schedule_create", "team_task_get", "team_task_update", "team_task_create",
    "team_task_list", "subagent", "subagent_fork", "wait_agent",
    "list_agents", "plugin_manager", "job_list", "job_output", "job_kill",
    "workflow", "present", "working_directory", "load_workspace_dependencies",
    "todo_write", "get_goal", "update_goal", "create_goal",
})
def tool_id(name: str) -> str:
    return "t-" + hashlib.sha256(("dsh-tool:" + name).encode()).hexdigest()[:24]

def document_event(raw: object, cwd: str) -> tuple[str,str] | None:
    if not isinstance(raw, str) or not raw or len(raw) > 1024:
        return None
    path = Path(raw).expanduser()
    if not path.is_absolute():
        path = Path(cwd) / path
    try:
        path = path.resolve()
        roots = (HOME / "Documents", HOME / ".dsh")
        if not any(path.is_relative_to(root.resolve()) for root in roots):
            return None
        if path.suffix.lower() not in ALLOWED_SUFFIX or not path.is_file():
            return None
        if any(word in path.name.lower() for word in SECRET_WORDS):
            return None
        # Reuse the existing canonical nodes; never represent one known file twice.
        canon = HOME / ".dsh/AGENTS.md"
        if path == canon.resolve():
            return ("canon", "")
        workspace = HOME / "Documents/deepseek-harness/default-workspace"
        if path == (workspace / "reports/PROTOCOL.md").resolve():
            return ("protocol", "")
        if path == (workspace / "reports/protocols/INDEX.md").resolve():
            return ("index", "")
        for name in ("memory","journal","routes","models","dsh","learning"):
            if path == (HOME / ".dsh/nodes" / (name+".md")).resolve():
                return ("node-"+name, "")
        return ("document", "f-" + hashlib.sha256(("dsh-file:" + str(path)).encode()).hexdigest()[:24])
    except (OSError, ValueError):
        return None

def project_id_for_document(raw: object, cwd: str) -> str | None:
    """Use an actual allowed project root only, never infer a project from text."""
    path = Path(str(raw)).expanduser()
    if not path.is_absolute(): path = Path(cwd) / path
    try:
        path = path.resolve()
        # Project boundary is the directly nested folder under Codex.
        root = (HOME / "Documents/Codex").resolve()
        rel = path.relative_to(root)
        if len(rel.parts) < 2 or not path.is_file(): return None
        if any(word in path.name.lower() for word in SECRET_WORDS): return None
        return "p-" + hashlib.sha256(("atlas-project:" + str(root / rel.parts[0])).encode()).hexdigest()[:24]
    except (OSError,ValueError): return None

def document_id(raw: object, cwd: str) -> str | None:
    """Compatibility function for generic file IDs only; canon uses named nodes."""
    event = document_event(raw, cwd)
    return event[1] if event and event[0] == "document" else None

# Observed, native DSH event categories. Never inspect message/prompt contents.
STAGES = {
    "turn/start":"turn-start","turn/end":"turn-end",
    "step/start":"step-start","step/end":"step-end",
    "request/header":"request","assistant/attempt":"model-attempt",
    "assistant/message":"model-message","llm/retry":"model-retry",
    "model/selection":"model-select","job/registered":"job-start",
    "job/settled":"job-end","team/task":"team-task",
    "agent/inbox/spliced":"team-message",
    "subagent/catalog":"subagent-catalog",
    "tool/call":"tool-call","tool/result":"tool-result",
}
TOOL_NAME = re.compile(r"^[a-zA-Z][a-zA-Z0-9_:/.-]{0,100}$")


def session_actor_id(raw: str) -> str:
    return "h-" + hashlib.sha256(("dsh-session:" + raw).encode()).hexdigest()[:24]


def session_model_id(provider: object, model: object) -> str | None:
    if (not isinstance(provider,str) or not isinstance(model,str)
        or not (1 <= len(provider) <= 120) or not (1 <= len(model) <= 160)):
        return None
    return "m-" + hashlib.sha256(("dsh-model:" + provider + ":" + model).encode()).hexdigest()[:24]


def scan(path: Path, cursor: int, since_ms: int, allow: set[str]) -> tuple[int, list[tuple[str,str]]]:
    """Consume only NEW native events. Hash session/model IDs, never copy content."""
    zstd = shutil.which("zstd")
    if not zstd:
        raise FileNotFoundError("zstd executable is required for DSH session monitoring")
    proc = subprocess.Popen([zstd, "-dc", str(path)],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    newest = cursor
    found: list[tuple[str,str]] = []
    activity: list[tuple[str,str]] = []
    cwd = ""
    actor_id = session_actor_id(path.parent.name)
    role = "main"
    current_model = None
    recent_calls: dict[int,str] = {}
    activity_buckets: set[tuple[str,int]] = set()
    now_ms = int(time.time() * 1000)
    fast_type = re.compile(rb'^\s*\{\s*"type"\s*:\s*"([^"]+)"')
    fast_seq = re.compile(rb'"seq"\s*:\s*(\d+)')
    assert proc.stdout is not None
    try:
        for line in proc.stdout:
            # The native DSH envelope starts with type/seq/time. Inspect
            # only the small prefix, never grep huge assistant/tool payloads.
            # Old seqs are skipped *before* expensive JSON decoding; model
            # selections are kept to resolve the actual model of new events.
            prefix=line[:224]
            typematch=fast_type.match(prefix)
            if typematch is None: continue
            kind=typematch.group(1).decode("ascii",errors="ignore")
            if kind not in STAGES and kind not in ("session","subagent/descriptor"):
                continue
            if kind not in ("session","subagent/descriptor","model/selection"):
                seqmatch=fast_seq.search(prefix)
                if seqmatch is not None and int(seqmatch.group(1))<=cursor: continue
            try:
                obj=json.loads(line)
                event_type=obj.get("type")
                if event_type=="session":
                    cwd=str(obj.get("cwd") or "")
                    raw=str(obj.get("id") or path.parent.name)
                    actor_id=session_actor_id(raw)
                    role="worker" if obj.get("parentSession") else "main"
                    continue
                if event_type=="subagent/descriptor":
                    d=obj.get("data") or {}
                    if isinstance(d,dict):
                        current_model=session_model_id(d.get("agentProvider"),d.get("agentModel")) or current_model
                    continue
                if event_type not in STAGES:
                    continue
                data=obj.get("data") or {}
                if not isinstance(data,dict):
                    continue
                seq,ms=obj.get("seq"),obj.get("time")
                if not isinstance(seq,int) or not isinstance(ms,int):
                    continue
                newest=max(newest,seq)
                if event_type=="model/selection":
                    current_model=session_model_id(data.get("provider"),data.get("model")) or current_model
                active=(seq>cursor and ms>=max(since_ms, now_ms-30_000))
                # Preserve actual tool/call -> tool/result linking even when
                # some results arrive in another update of the compressed log.
                if event_type=="tool/call":
                    name=data.get("name")
                    if isinstance(name,str) and TOOL_NAME.fullmatch(name) and name not in ("skill","read","edit","write"):
                        recent_calls[seq]=tool_id(name)
                        if active: found.append(("tool",tool_id(name)))
                    elif active and name=="skill":
                        try:args=json.loads(data.get("arguments") or "{}")
                        except (TypeError,ValueError):args={}
                        skill=args.get("name") if isinstance(args,dict) else None
                        if isinstance(skill,str) and skill in allow:
                            found.append(("skill",skill_id(skill)))
                    elif active and name in ("read","edit","write") and cwd:
                        try:args=json.loads(data.get("arguments") or "{}")
                        except (TypeError,ValueError):args={}
                        if isinstance(args,dict):
                            doc=document_event(args.get("file_path"),cwd)
                            if doc:
                                found.append(doc)
                                if doc[0]=="document":
                                    proj=project_id_for_document(args.get("file_path"),cwd)
                                    if proj:found.append(("project-link",proj+":"+doc[1]))
                elif event_type=="tool/result":
                    message=data.get("message")
                    sources=obj.get("sourceEventSeqs") or []
                    linked=next((recent_calls[n] for n in sources if isinstance(n,int) and n in recent_calls),None)
                    if active and linked and isinstance(message,dict) and isinstance(message.get("isError"),bool):
                        outcome="error" if message["isError"] else "returned"
                        found.append(("tool-result-"+outcome,linked))
                if active:
                    stage=STAGES[event_type]
                    # Distinct real tool calls and job/task transitions
                    # must not collapse into one per-second pulse.
                    granular = stage in ("tool-call","tool-result","team-task","job-start","job-end")
                    bucket=(stage,seq if granular else ms//1000)
                    if bucket not in activity_buckets:
                        activity_buckets.add(bucket)
                        tool_ref = None
                        if event_type=="tool/call":
                            name=data.get("name")
                            if isinstance(name,str) and TOOL_NAME.fullmatch(name):
                                tool_ref=tool_id(name)
                        activity.append(("harness-event",actor_id+"|"+role+"|"+stage+"|"+(current_model or "")+"|"+(tool_ref or "")))
            except (ValueError,TypeError,AttributeError):
                continue
    finally:
        proc.stdout.close()
    if proc.wait(timeout=10)!=0:
        raise RuntimeError("zstd stream failed")
    # Most recent bounded activity is more useful than replaying bursts of
    # 100+ step events at once. Genuine tool/document records aren't capped.
    found.extend(activity[-32:])
    return newest,found


def run_once(dry_run: bool = False, files: list[Path] | None = None,
             state_path: Path = STATE, emit: bool = True) -> dict:
    state_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        state = json.loads(state_path.read_text())
        if not isinstance(state, dict): raise ValueError("invalid state")
    except (OSError, ValueError, TypeError):
        state = {"started_ms": int(time.time() * 1000), "cursors": {}}
    if not isinstance(state.get("cursors"), dict): state["cursors"] = {}
    allow = available()
    now = time.time()
    live_scan = files is None
    if files is None:
        files = list(SESSIONS.glob("*/**/session.v4.jsonl.zstd"))
    events = 0
    changes = 0
    for path in files:
        try:
            st = path.stat()
            if now - st.st_mtime > 86400 and str(path) not in state["cursors"]:
                continue
            key = str(path)
            prev = state["cursors"].get(key, {})
            sig = [st.st_ino, st.st_size, st.st_mtime_ns]
            if prev.get("sig") == sig:
                continue
            old_seq = prev.get("seq", -1) if prev.get("inode") == st.st_ino else -1
            newest, found = scan(path, old_seq, int(state["started_ms"]), allow)
            changes += 1
            for operation, opaque_id in found:
                if emit and not dry_run:
                    kwargs = ({"skill_id":opaque_id} if operation == "skill" else
                              {"document_id":opaque_id} if operation == "document" else
                              {"tool_id":opaque_id} if operation == "tool" else {})
                    record_op = "tool-result" if operation.startswith("tool-result-") else operation
                    if operation == "project-link":
                        project_id, document_id = opaque_id.split(":",1)
                        kwargs = {"project_id":project_id, "document_id":document_id}
                    if operation == "harness-event":
                        parts = opaque_id.split("|")
                        if len(parts) != 5:
                            continue
                        actor, role, stage, model, tool = parts
                        kwargs = {"actor_id":actor, "role":role, "stage":stage}
                        if model:
                            kwargs["model_id"]=model
                        if tool:
                            kwargs["tool_id"]=tool
                    if record_op == "tool-result":
                        kwargs = {"tool_id":opaque_id}
                    outcome = ("error" if operation == "tool-result-error" else
                               "returned" if operation == "tool-result-returned" else None)
                    if not record_access(record_op, new_access_id(), outcome=outcome, **kwargs):
                        raise RuntimeError("Atlas event writer failed")
                events += 1
            state["cursors"][key] = {"sig": sig, "inode": st.st_ino, "seq": newest}
        except (OSError, RuntimeError, subprocess.TimeoutExpired):
            continue
    # Do not rewrite an unchanged cursor file every two seconds: low disk churn.
    if not dry_run and (changes > 0 or not state_path.exists()):
        temp = state_path.with_suffix(".tmp")
        temp.write_text(json.dumps(state, separators=(",", ":")))
        os.chmod(temp, 0o600)
        os.replace(temp, state_path)
    return {"files_checked": changes, "access_events": events, "skill_catalog": len(allow)}

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    LOCK.parent.mkdir(parents=True, exist_ok=True)
    with LOCK.open("a+") as stream:
        os.chmod(LOCK, 0o600)
        try:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit("skill watcher already running")
        while True:
            out = run_once(dry_run=args.dry_run)
            if args.once or args.dry_run:
                print(json.dumps(out, ensure_ascii=False))
                break
            time.sleep(POLL_SECONDS)

if __name__ == "__main__":
    main()

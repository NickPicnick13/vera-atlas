#!/usr/bin/env python3
"""Privacy-safe local events for the Atlas memory-access signal.

Only a random access id, a fixed operation label and a timestamp are written.
Queries, snippets, file names, session ids and credentials are never recorded.
"""
from __future__ import annotations

import fcntl
import json
import os
import re
import uuid
from datetime import datetime
from pathlib import Path

ACCESS_PATH = Path.home() / "Library/Application Support/VeraAtlas/atlas-access.jsonl"
ACCESS_KEEP = 512
VALID_ID = re.compile(r"^[0-9a-f]{32}$")
OPERATIONS = frozenset({
    "flash", "shared-memory", "archive-index", "archive-store", "knowledge-graph",
    "chatgpt-memory", "chatgpt-memory-write", "canon", "protocol", "index",
    "node-memory", "node-journal", "node-routes", "node-models",
    "node-dsh", "node-learning", "skill-entry", "skill", "document", "tool", "tool-result", "project-link", "harness-event", "process-event",
})


def new_access_id() -> str:
    return uuid.uuid4().hex


def valid_access_id(value: object) -> bool:
    return isinstance(value, str) and VALID_ID.fullmatch(value) is not None


def record_access(operation: str, access_id: str, *, path: str | Path | None = None,
                  skill_id: str | None = None, document_id: str | None = None,
                  tool_id: str | None = None, outcome: str | None = None,
                  project_id: str | None = None, origin: str | None = None,
                  actor_id: str | None = None, role: str | None = None,
                  stage: str | None = None, model_id: str | None = None,
                  process_id: str | None = None, task_id: str | None = None) -> bool:
    """Append one metadata-only access event. Logging failure never breaks memory."""
    if not valid_access_id(access_id):
        return False
    safe_operation = operation if operation in OPERATIONS else "shared-memory"
    target = Path(path or os.environ.get("VERA_ATLAS_ACCESS_PATH") or ACCESS_PATH)
    record = {
        "type": "memory_access",
        "id": access_id,
        "timestamp": datetime.now().astimezone().isoformat(timespec="milliseconds"),
        "operation": safe_operation,
    }
    if safe_operation == "skill":
        if not isinstance(skill_id, str) or re.fullmatch(r"k-[0-9a-f]{24}", skill_id) is None:
            return False
        record["skill_id"] = skill_id
    if safe_operation == "document":
        if not isinstance(document_id, str) or re.fullmatch(r"f-[0-9a-f]{24}", document_id) is None:
            return False
        record["document_id"] = document_id
    if safe_operation == "project-link":
        if (not isinstance(project_id, str) or re.fullmatch(r"p-[0-9a-f]{24}", project_id) is None
            or not isinstance(document_id, str) or re.fullmatch(r"f-[0-9a-f]{24}", document_id) is None):
            return False
        record["project_id"] = project_id
        record["document_id"] = document_id
    if safe_operation in ("tool", "tool-result"):
        if not isinstance(tool_id, str) or re.fullmatch(r"t-[0-9a-f]{24}", tool_id) is None:
            return False
        record["tool_id"] = tool_id
        if origin is not None:
            if origin != "chatgpt":
                return False
            record["origin"] = origin
        if process_id is not None:
            if origin != "chatgpt" or not isinstance(process_id,str) or re.fullmatch(r"r-[0-9a-f]{24}",process_id) is None:
                return False
            record["process_id"] = process_id
        if safe_operation == "tool-result":
            if outcome not in ("returned", "error"):
                return False
            record["outcome"] = outcome
    if safe_operation == "harness-event":
        valid_stages = frozenset({
            "turn-start","turn-end","step-start","step-end","request",
            "model-attempt","model-message","model-retry","model-select",
            "job-start","job-end","team-task","team-message",
            "subagent-catalog","tool-call","tool-result"})
        if not isinstance(actor_id, str) or re.fullmatch(r"h-[0-9a-f]{24}", actor_id) is None:
            return False
        if role not in ("main", "worker") or stage not in valid_stages:
            return False
        record["actor_id"] = actor_id
        record["role"] = role
        record["stage"] = stage
        if model_id is not None:
            if not isinstance(model_id,str) or re.fullmatch(r"m-[0-9a-f]{24}",model_id) is None:
                return False
            record["model_id"] = model_id
        if tool_id is not None:
            if stage not in ("tool-call","tool-result") or not isinstance(tool_id,str) or re.fullmatch(r"t-[0-9a-f]{24}",tool_id) is None:
                return False
            record["tool_id"]=tool_id
    if safe_operation == "process-event":
        if not isinstance(model_id,str) or re.fullmatch(r"m-[0-9a-f]{24}", model_id) is None:
            return False
        if stage not in ("configured","snapshot","started","result","retry"):
            return False
        if stage != "configured":
            if not isinstance(process_id,str) or re.fullmatch(r"r-[0-9a-f]{24}",process_id) is None:
                return False
            if not isinstance(task_id,str) or re.fullmatch(r"q-[0-9a-f]{24}",task_id) is None:
                return False
            record["process_id"]=process_id
            record["task_id"]=task_id
        if stage == "result":
            if outcome not in ("completed","provider_error","harness_timeout"):
                return False
            record["outcome"]=outcome
        record["model_id"]=model_id
        record["stage"]=stage
    line = json.dumps(record, ensure_ascii=True, separators=(",", ":")) + "\n"
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(str(target), os.O_CREAT | os.O_RDWR | os.O_APPEND, 0o600)
        try:
            os.fchmod(fd, 0o600)
            fcntl.flock(fd, fcntl.LOCK_EX)
            with os.fdopen(fd, "a+", encoding="utf-8", closefd=False) as stream:
                stream.seek(0)
                lines = stream.readlines()
                # Keep an opaque, permanent topology index in the SAME bus.
                # Other consumers ignore this non-memory_access first row.
                previous = None
                if lines and len(lines[0]) < 8_000_000:
                    try:
                        candidate = json.loads(lines[0])
                        if isinstance(candidate, dict) and candidate.get("type") == "atlas_catalog":
                            previous = candidate
                    except ValueError:
                        pass
                history = lines[1:] if previous is not None else lines
                ids = set()
                links = set()
                chatgpt_tools = set()
                chatgpt_processes: list[tuple[str,str]] = []
                harness_actors = {}
                harness_models = set()
                harness_actor_models = set()
                process_models = set()
                process_tasks = set()
                process_instances = set()
                if previous is not None:
                    ids.update(i for i in previous.get("document_ids", [])
                               if isinstance(i, str) and re.fullmatch(r"f-[0-9a-f]{24}", i))
                    chatgpt_tools.update(i for i in previous.get("chatgpt_tool_ids", [])
                               if isinstance(i, str) and re.fullmatch(r"t-[0-9a-f]{24}", i))
                    for pair in previous.get("chatgpt_processes", []):
                        if (isinstance(pair,list) and len(pair)==2 and
                            isinstance(pair[0],str) and re.fullmatch(r"r-[0-9a-f]{24}",pair[0])
                            and isinstance(pair[1],str) and re.fullmatch(r"t-[0-9a-f]{24}",pair[1])):
                            pair=tuple(pair)
                            if pair not in chatgpt_processes:chatgpt_processes.append(pair)
                    for pair in previous.get("harness_actors", []):
                        if (isinstance(pair,list) and len(pair)==2 and
                            isinstance(pair[0],str) and re.fullmatch(r"h-[0-9a-f]{24}",pair[0])
                            and pair[1] in ("main","worker")):
                            harness_actors[pair[0]]=pair[1]
                    for mid in previous.get("harness_models", []):
                        if isinstance(mid,str) and re.fullmatch(r"m-[0-9a-f]{24}",mid):
                            harness_models.add(mid)
                    for pair in previous.get("harness_actor_models", []):
                        if (isinstance(pair,list) and len(pair)==2 and
                            isinstance(pair[0],str) and re.fullmatch(r"h-[0-9a-f]{24}",pair[0]) and
                            isinstance(pair[1],str) and re.fullmatch(r"m-[0-9a-f]{24}",pair[1])):
                            harness_actor_models.add(tuple(pair))
                    for mid in previous.get("process_models", []):
                        if isinstance(mid,str) and re.fullmatch(r"m-[0-9a-f]{24}",mid):
                            process_models.add(mid)
                    for tid in previous.get("process_tasks", []):
                        if isinstance(tid,str) and re.fullmatch(r"q-[0-9a-f]{24}",tid):
                            process_tasks.add(tid)
                    for triple in previous.get("process_instances", []):
                        if (isinstance(triple,list) and len(triple)==3 and
                            isinstance(triple[0],str) and re.fullmatch(r"r-[0-9a-f]{24}",triple[0]) and
                            isinstance(triple[1],str) and re.fullmatch(r"m-[0-9a-f]{24}",triple[1]) and
                            isinstance(triple[2],str) and re.fullmatch(r"q-[0-9a-f]{24}",triple[2])):
                            process_instances.add(tuple(triple))
                    for pair in previous.get("project_links", []):
                        if (isinstance(pair, list) and len(pair) == 2
                            and isinstance(pair[0], str) and isinstance(pair[1], str)
                            and re.fullmatch(r"p-[0-9a-f]{24}", pair[0])
                            and re.fullmatch(r"f-[0-9a-f]{24}", pair[1])):
                            links.add((pair[0], pair[1]))
                else:
                    # One-time migration of still-retained real access events.
                    for existing in history:
                        try:
                            item = json.loads(existing)
                        except ValueError:
                            continue
                        if not isinstance(item, dict) or item.get("type") != "memory_access":
                            continue
                        if (item.get("origin") == "chatgpt" and
                                item.get("operation") in ("tool","tool-result")):
                            tid = item.get("tool_id")
                            if isinstance(tid, str) and re.fullmatch(r"t-[0-9a-f]{24}", tid):
                                chatgpt_tools.add(tid)
                                process=item.get("process_id")
                                if isinstance(process,str) and re.fullmatch(r"r-[0-9a-f]{24}",process):
                                    pair=(process,tid)
                                    if pair not in chatgpt_processes:chatgpt_processes.append(pair)
                        if item.get("operation")=="harness-event":
                            actor, hrole, mid = item.get("actor_id"),item.get("role"),item.get("model_id")
                            if isinstance(actor,str) and re.fullmatch(r"h-[0-9a-f]{24}",actor) and hrole in ("main","worker"):
                                harness_actors[actor]=hrole
                                if isinstance(mid,str) and re.fullmatch(r"m-[0-9a-f]{24}",mid):
                                    harness_models.add(mid)
                                    harness_actor_models.add((actor,mid))
                        if item.get("operation")=="process-event":
                            mid, tid, proc = item.get("model_id"),item.get("task_id"),item.get("process_id")
                            if isinstance(mid,str) and re.fullmatch(r"m-[0-9a-f]{24}",mid):
                                process_models.add(mid)
                                if (isinstance(tid,str) and re.fullmatch(r"q-[0-9a-f]{24}",tid)
                                    and isinstance(proc,str) and re.fullmatch(r"r-[0-9a-f]{24}",proc)):
                                    process_tasks.add(tid)
                                    process_instances.add((proc,mid,tid))
                        doc = item.get("document_id")
                        if isinstance(doc, str) and re.fullmatch(r"f-[0-9a-f]{24}", doc):
                            ids.add(doc)
                            project = item.get("project_id")
                            if (isinstance(project, str)
                                and re.fullmatch(r"p-[0-9a-f]{24}", project)):
                                links.add((project, doc))
                # Repair a catalog written by a still-running older watcher:
                # retain actual ChatGPT action spans from the immutable
                # recent event history, even when its catalog lacks the new
                # chatgpt_processes field. No synthetic actions are created.
                for existing in history:
                    if '"origin":"chatgpt"' not in existing or '"process_id"' not in existing:
                        continue
                    try: item=json.loads(existing)
                    except ValueError: continue
                    if (item.get("origin")!="chatgpt" or
                        item.get("operation") not in ("tool","tool-result")):
                        continue
                    process, tool = item.get("process_id"), item.get("tool_id")
                    if (isinstance(process,str) and re.fullmatch(r"r-[0-9a-f]{24}",process)
                        and isinstance(tool,str) and re.fullmatch(r"t-[0-9a-f]{24}",tool)):
                        pair=(process,tool)
                        if pair not in chatgpt_processes:chatgpt_processes.append(pair)
                if safe_operation == "document":
                    ids.add(record["document_id"])
                elif safe_operation == "project-link":
                    ids.add(record["document_id"])
                    links.add((record["project_id"], record["document_id"]))
                elif safe_operation in ("tool","tool-result") and origin == "chatgpt":
                    chatgpt_tools.add(record["tool_id"])
                    if "process_id" in record:
                        pair=(record["process_id"],record["tool_id"])
                        if pair in chatgpt_processes:chatgpt_processes.remove(pair)
                        chatgpt_processes.append(pair)
                elif safe_operation=="harness-event":
                    harness_actors[record["actor_id"]]=record["role"]
                    if "model_id" in record:
                        harness_models.add(record["model_id"])
                        harness_actor_models.add((record["actor_id"],record["model_id"]))
                elif safe_operation == "process-event":
                    process_models.add(record["model_id"])
                    if "process_id" in record:
                        process_tasks.add(record["task_id"])
                        process_instances.add((record["process_id"],record["model_id"],record["task_id"]))
                # Retain recent individual actions, not unbounded log growth.
                chatgpt_processes=chatgpt_processes[-96:]
                catalog = {"type":"atlas_catalog","version":1,
                           "document_ids":sorted(ids),
                           "project_links":[list(x) for x in sorted(links)],
                           "chatgpt_tool_ids":sorted(chatgpt_tools),
                           "chatgpt_processes":[list(x) for x in chatgpt_processes],
                           "harness_actors":[[a,r] for a,r in sorted(harness_actors.items())],
                           "harness_models":sorted(harness_models),
                           "harness_actor_models":[list(x) for x in sorted(harness_actor_models)],
                           "process_models":sorted(process_models),
                           "process_tasks":sorted(process_tasks),
                           "process_instances":[list(x) for x in sorted(process_instances)]}
                needs_catalog = bool(ids or links or chatgpt_tools or chatgpt_processes or harness_actors or process_models)
                old_catalog = ({"type":"atlas_catalog","version":1,
                                "document_ids":previous.get("document_ids", []),
                                "project_links":previous.get("project_links", []),
                                "chatgpt_tool_ids":previous.get("chatgpt_tool_ids", []),
                                "chatgpt_processes":previous.get("chatgpt_processes", []),
                                "harness_actors":previous.get("harness_actors", []),
                                "harness_models":previous.get("harness_models", []),
                                "harness_actor_models":previous.get("harness_actor_models", []),
                                "process_models":previous.get("process_models", []),
                                "process_tasks":previous.get("process_tasks", []),
                                "process_instances":previous.get("process_instances", [])}
                               if previous is not None else None)
                changed = needs_catalog and catalog != old_catalog
                if len(history) >= ACCESS_KEEP or changed:
                    stream.seek(0)
                    stream.truncate(0)
                    if needs_catalog:
                        stream.write(json.dumps(catalog, separators=(",", ":")) + "\n")
                    stream.writelines(history[-(ACCESS_KEEP - 1):])
                stream.seek(0, os.SEEK_END)
                stream.write(line)
                stream.flush()
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)
        return True
    except Exception:
        return False


def begin_access(operation: str) -> str:
    """Start one read. A parent adapter may supply an id and own this event."""
    inherited = os.environ.get("VERA_ATLAS_ACCESS_ID", "")
    access_id = inherited if valid_access_id(inherited) else new_access_id()
    if os.environ.get("VERA_ATLAS_ACCESS_PARENT") != "1":
        record_access(operation, access_id)
    return access_id


def child_access_env(access_id: str) -> dict[str, str]:
    """Return an environment for nested memory readers to reuse, not duplicate, an event."""
    env = os.environ.copy()
    env["VERA_ATLAS_ACCESS_ID"] = access_id
    env["VERA_ATLAS_ACCESS_PARENT"] = "1"
    return env


def chatgpt_document_id(source: str) -> str | None:
    """Stable opaque node for a source whose read was confirmed by a ChatGPT tool result.

    Only use a stable provider document identifier, not a transient tool-call id.
    The source string is hashed, never stored in the Atlas event stream.
    """
    import hashlib
    if not isinstance(source, str) or not (1 <= len(source) <= 256):
        return None
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:/-]*", source) is None:
        return None
    return "f-" + hashlib.sha256(("chatgpt-doc:" + source).encode()).hexdigest()[:24]


def record_confirmed_external_tool(provider: str, tool: str,
                                   outcome: str = "returned") -> bool:
    """Explicit receipt after a confirmed external ChatGPT connector tool invocation.

    Only tool identity metadata. This does not claim to observe unseen calls or
    claim that a tool invocation succeeded.
    """
    import hashlib
    safe = re.compile(r"^[A-Za-z][A-Za-z0-9_-]{0,79}$")
    if not (isinstance(provider, str) and isinstance(tool, str)
            and safe.fullmatch(provider) and safe.fullmatch(tool)):
        return False
    opaque = "t-" + hashlib.sha256(("external-tool:" + provider + ":" + tool).encode()).hexdigest()[:24]
    return record_access("tool-result", new_access_id(), tool_id=opaque,
                         origin="chatgpt", outcome=outcome)


def record_confirmed_chatgpt_document(source: str, *, path: str | Path | None = None) -> bool:
    """Explicit bridge, invoked only AFTER a successful observed ChatGPT tool read.

    There is no universal hook for arbitrary ChatGPT tools. Local files use
    the same node identity as the existing DSH watcher to avoid duplicates.
    """
    document_id = chatgpt_document_id(source)
    if path is not None:
        from vera_atlas_skill_watch import document_event
        mapped = document_event(str(Path(path).expanduser().resolve()), str(Path.cwd()))
        if mapped is None:
            return False
        operation, local_id = mapped
        if operation != "document":
            return record_access(operation, new_access_id())
        document_id = local_id
    return bool(document_id and record_access("document", new_access_id(), document_id=document_id))


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Atlas: explicit confirmed ChatGPT document read receipt")
    parser.add_argument("--confirmed-chatgpt-read", metavar="STABLE_SOURCE_ID")
    parser.add_argument("--local-file", help="Optional local document path; reuse existing DSH graph identity")
    parser.add_argument("--confirmed-external-tool", nargs=2, metavar=("PROVIDER","TOOL"),
                        help="Receipt after a genuinely observed external connector tool result")
    parser.add_argument("--tool-outcome", choices=("returned","error"),
                        default="returned", help="Verified external connector outcome")
    args = parser.parse_args()
    if args.confirmed_external_tool:
        provider, tool = args.confirmed_external_tool
        if args.local_file and (provider != "DeepSeek" or tool != "mac_read_file"
                                or args.tool_outcome != "returned"):
            parser.error("local-file may accompany only a verified successful DeepSeek mac_read_file")
        if args.local_file:
            from vera_atlas_skill_watch import document_event
            mapped = document_event(str(Path(args.local_file).expanduser().resolve()),
                                    str(Path.cwd()))
            if mapped is None:
                parser.error("local-file is not an approved text document")
        if not record_confirmed_external_tool(provider, tool, outcome=args.tool_outcome):
            parser.error("invalid external tool identity")
        if args.local_file:
            if not record_confirmed_chatgpt_document(provider + ":" + tool,
                                                     path=args.local_file):
                parser.error("connector tool was recorded, but document event failed")
        print("atlas_external_tool_receipt=ok"
              + (" document_receipt=ok" if args.local_file else ""))
        raise SystemExit(0)
    if not args.confirmed_chatgpt_read:
        parser.error("confirmed read or external tool receipt required")
    if not record_confirmed_chatgpt_document(args.confirmed_chatgpt_read, path=args.local_file):
        parser.error("invalid or disallowed document source")
    print("atlas_chatgpt_document_receipt=ok")

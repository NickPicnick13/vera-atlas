#!/usr/bin/env python3
"""Optional Atlas delivery controller; no model calls, no extra daemon.

Checks real source events against explicit WebKit JS-merge acknowledgements.
An operator can connect their own existing repair foreman through a callback.
No inferred/private ChatGPT events and no automatic model invocation.
"""
from __future__ import annotations
from datetime import datetime
from pathlib import Path
import argparse
import json
import os
import re
import time

HOME = Path.home()
DATA = HOME / "Library/Application Support/VeraAtlas"
BUS = Path(os.environ.get("VERA_ATLAS_ACCESS_PATH", str(DATA / "atlas-access.jsonl")))
ACK = Path(os.environ.get("VERA_ATLAS_DELIVERY_ACK_PATH", str(DATA / "atlas-render-ack.json")))
STATE = DATA / "skill-watch-state.json"
INTERVAL_MS, GRACE_MS, WINDOW_MS = 30000, 35000, 120000
ID = re.compile(r"^[0-9a-f]{32}$")

def time_ms(value):
    try:
        return int(datetime.fromisoformat(str(value)).timestamp() * 1000)
    except (TypeError, ValueError, OverflowError):
        return 0

def tail_bus(path: Path) -> list[dict]:
    with path.open("rb") as f:
        size = f.seek(0, 2)
        f.seek(max(0, size - 180000))
        lines = f.read().splitlines()
    if size > 180000:
        lines = lines[1:]
    events = []
    for raw in lines[-600:]:
        try:
            obj = json.loads(raw)
            if isinstance(obj, dict) and obj.get("type") == "memory_access":
                events.append(obj)
        except (UnicodeDecodeError, ValueError):
            pass
    return events

def has_visual_route(event):
    op = event.get("operation")
    if op == "process-event":
        return event.get("stage") in ("result", "started", "retry")
    return op in {
        "flash", "shared-memory", "archive-index", "archive-store", "knowledge-graph",
        "chatgpt-memory", "chatgpt-memory-write", "canon", "protocol", "index",
        "node-memory", "node-journal", "node-routes", "node-models", "node-dsh",
        "node-learning", "skill-entry", "skill", "document", "tool", "tool-result",
        "project-link", "harness-event"
    }

def inspect(bus=BUS, ack_path=ACK, now_ms=None):
    """Classify only observed events; never fabricate a flash or a repair."""
    now = int(time.time()*1000) if now_ms is None else now_ms
    try:
        events = tail_bus(bus)
    except OSError:
        return {"status": "source_unavailable", "sampled": 0, "missing": 0}
    try:
        ack = json.loads(ack_path.read_text("utf-8"))
        if (ack.get("protocol") != 1 or ack.get("kind") != "javascript_accepted"
                or not isinstance(ack.get("ids"), list)):
            raise ValueError("invalid receipt")
    except (OSError, ValueError, TypeError):
        return {"status": "ack_unavailable", "sampled": len(events), "missing": 0}
    started = int(ack.get("started_ms") or 0)
    ids = {s for s in ack["ids"] if isinstance(s, str) and ID.fullmatch(s)}
    pid = int(ack.get("pid") or 0)
    if pid and now - int(ack.get("at_ms") or 0) > 60000:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return {"status": "widget_stopped", "sampled": len(events), "missing": 0}
        except PermissionError:
            pass
    seen = [e for e in events if has_visual_route(e) and
        ID.fullmatch(str(e.get("id", ""))) and
        max(started, now-WINDOW_MS) <= time_ms(e.get("timestamp")) <= now-GRACE_MS]
    missing = [e for e in seen if e["id"] not in ids]
    if sum(time_ms(e.get("timestamp")) >= started for e in events) > 500:
        return {"status": "high_volume_unverifiable", "sampled": len(seen), "missing": 0}
    if missing:
        return {"status": "delivery_gap", "sampled": len(seen), "missing": len(missing),
                "missing_flash": sum(e.get("operation")=="flash" for e in missing)}
    return {"status": "observed" if seen else "idle", "sampled": len(seen),
            "acknowledged": len(seen), "missing": 0, "ack_at_ms": ack.get("at_ms")}

def cycle(state, *, failures=0, now_ms=None, bus=BUS, ack_path=ACK, dispatcher=None):
    """One bounded check in the existing watcher; dispatcher is opt-in.

    A callback receives only (kind, aggregate evidence) and must return
    {"accepted": True} for a handoff. It is never installed by default.
    """
    now = int(time.time()*1000) if now_ms is None else now_ms
    ctl = state.setdefault("controller", {"protocol": 1, "incidents": {}})
    incidents = ctl.setdefault("incidents", {})
    if now-int(ctl.get("checked_ms", 0)) < INTERVAL_MS:
        return False
    ctl["checked_ms"] = now
    view = inspect(bus=bus, ack_path=ack_path, now_ms=now)
    ctl["observation"] = view
    ctl["blind_spot"] = "Uninstrumented ChatGPT tool calls have no automatic local hook"
    kind = ("source_to_bus" if failures else
            "bus_to_atlas" if view["status"] == "delivery_gap" else
            "widget_stopped" if view["status"] == "widget_stopped" else None)
    if not kind and view["status"] in ("observed", "idle"):
        for item in incidents.values():
            if item.get("state") in ("observing", "needs_attention"):
                item["state"] = "resolved_by_observation"
                item["resolved_ms"] = now
            elif item.get("state") == "assigned":
                if view["status"] == "observed" and view.get("ack_at_ms", 0) > item.get("sent_ms", now):
                    item["recovery_checks"] = item.get("recovery_checks", 0) + 1
                    if item["recovery_checks"] >= 2:
                        item["state"] = "delivery_recovered_pending_reviewer"
    if kind:
        item = incidents.setdefault(kind, {"state": "observing", "checks": 0,
                                            "first_ms": now})
        item["checks"] += 1
        item["last_ms"] = now
        item["evidence"] = {"missing": view.get("missing", 0),
                            "missing_flash": view.get("missing_flash", 0),
                            "watch_errors": failures}
        if item["checks"] >= 2 and item["state"] == "observing":
            if dispatcher is None:
                item["state"] = "needs_attention"
            else:
                # Persist a guard BEFORE invoking an explicitly supplied callback.
                item["state"] = "handoff_pending"
                response = dispatcher(kind, dict(item["evidence"]))
                item["state"] = "assigned" if (
                    isinstance(response, dict) and response.get("accepted") is True
                ) else "needs_attention"
                item["sent_ms"] = now
    return True

def main():
    parser = argparse.ArgumentParser(description="Read-only Atlas delivery status")
    parser.add_argument("command", choices=("inspect", "status"))
    args = parser.parse_args()
    if args.command == "inspect":
        print(json.dumps(inspect(), sort_keys=True))
    else:
        try:
            state = json.loads(STATE.read_text("utf-8")).get("controller", {})
        except (OSError, ValueError):
            state = {}
        print(json.dumps(state, sort_keys=True))

if __name__ == "__main__":
    main()

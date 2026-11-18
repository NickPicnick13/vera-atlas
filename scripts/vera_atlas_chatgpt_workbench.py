#!/usr/bin/env python3
"""Verified ChatGPT -> Atlas workbench span, no daemon or model inference.

Use as: python3 -B scripts/vera_atlas_chatgpt_workbench.py -- /bin/sh -c '...'
Only a shell command that actually starts generates a live action event.
The command text, paths, prompts, and output never enter the Atlas bus.
"""
from __future__ import annotations
import hashlib
import subprocess
import sys
import uuid

from vera_atlas_access import new_access_id, record_access

TOOL_ID = "t-" + hashlib.sha256(
    b"external-tool:DeepSeek:deepseek_job_start"
).hexdigest()[:24]


def main(arguments: list[str]) -> int:
    command = arguments[1:] if arguments and arguments[0] == "--" else arguments
    if not command:
        print("usage: vera_atlas_chatgpt_workbench.py -- COMMAND [ARGS...]",file=sys.stderr)
        return 2
    span = "r-" + uuid.uuid4().hex[:24]
    try:
        child = subprocess.Popen(command)
    except OSError as exc:
        print(f"unable to start workbench command: {type(exc).__name__}",file=sys.stderr)
        return 127

    try:
        record_access("tool",new_access_id(),tool_id=TOOL_ID,
                      origin="chatgpt",process_id=span)
    except Exception:
        pass  # Telemetry must never change a command's correctness.

    try:
        code = child.wait()
    except KeyboardInterrupt:
        child.terminate()
        code = child.wait()

    try:
        record_access("tool-result",new_access_id(),tool_id=TOOL_ID,
                      origin="chatgpt",process_id=span,
                      outcome="returned" if code==0 else "error")
    except Exception:
        pass
    return code


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

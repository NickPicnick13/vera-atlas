#!/usr/bin/env python3
"""Atomic ChatGPT Mac file read -> verified Atlas access (existing JSONL bus).

Use this as the Mac-local read adapter when the caller needs the file text and
an Atlas glow. Unlike a post-hoc receipt, an event is recorded only after bytes
were actually read and successfully decoded. No new service or database.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
from vera_atlas_access import new_access_id, record_access
from vera_atlas_skill_watch import document_event, project_id_for_document

MAX_BYTES = 262144

def read_and_emit(path: str, offset: int = 0, limit: int = 65536) -> dict:
    if not isinstance(offset, int) or offset < 0 or not 1 <= limit <= MAX_BYTES:
        raise ValueError("invalid offset or read limit")
    target = Path(path).expanduser().resolve()
    mapped = document_event(str(target), str(Path.cwd()))
    if not mapped:
        raise ValueError("file is outside approved text-document roots")
    operation, stable_id = mapped
    # Open and decode before recording. Failed reads must NEVER light the graph.
    with target.open("rb") as handle:
        handle.seek(offset)
        raw = handle.read(limit)
        end = handle.tell()
    if not raw:
        return {"ok": True, "document_id": stable_id or None,
                "operation": operation, "text": "", "next_offset": end,
                "has_more": False, "event_recorded": False}
    try:
        decoded = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        # A chunk may end within a UTF-8 codepoint; leave the trailing bytes
        # for the next read. Invalid data in the middle is a real error.
        if error.reason != "unexpected end of data" or error.start < len(raw) - 4:
            raise
        raw = raw[:error.start]
        decoded = raw.decode("utf-8")
        end = offset + len(raw)
    if not decoded:
        raise ValueError("failed to decode document text")
    if not record_access(operation, new_access_id(),
                         **({"document_id":stable_id} if operation == "document" else {})):
        raise RuntimeError("Atlas access event was not recorded")
    if operation == "document":
        project_id = project_id_for_document(str(target), str(Path.cwd()))
        if project_id:
            # Existing project route; failure of optional secondary event must
            # not turn a successfully recorded primary read into a fake error.
            record_access("project-link", new_access_id(),
                          project_id=project_id, document_id=stable_id)
    return {"ok":True, "operation":operation, "document_id":stable_id or None,
            "text":decoded, "next_offset":end,
            "has_more":target.stat().st_size > end, "event_recorded":True}

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", help="existing approved Mac text file")
    parser.add_argument("--offset", type=int, default=0)
    parser.add_argument("--limit", type=int, default=65536)
    args = parser.parse_args()
    try:
        print(json.dumps(read_and_emit(args.path, args.offset, args.limit), ensure_ascii=False))
    except (OSError, UnicodeError, ValueError, RuntimeError) as e:
        parser.exit(2, "atlas_read_error: " + str(e) + "\n")

if __name__ == "__main__":
    main()

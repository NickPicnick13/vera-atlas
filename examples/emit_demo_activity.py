#!/usr/bin/env python3
"""Emit actual DEMO-script steps. All model/task identities are synthetic."""
from __future__ import annotations
import argparse
import hashlib
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from vera_atlas_access import new_access_id, record_access

def opaque(prefix: str, value: str) -> str:
    return prefix + "-" + hashlib.sha256(value.encode("utf-8")).hexdigest()[:24]

def main() -> None:
    ap = argparse.ArgumentParser(description="Publish demo events (no AI calls)")
    ap.add_argument("--count", type=int, default=12)
    ap.add_argument("--delay", type=float, default=0.8)
    a = ap.parse_args()
    if not 1 <= a.count <= 100 or not 0 <= a.delay <= 5:
        ap.error("count 1..100, delay 0..5")
    models = [opaque("m", "DEMO-model-" + str(i)) for i in range(3)]
    for mid in models:
        assert record_access("process-event", new_access_id(),
                             model_id=mid, stage="configured")
    for i in range(a.count):
        model = models[i % len(models)]
        task = opaque("q", "DEMO-task-" + str(i % 5))
        request = opaque("r", "DEMO-process-" + uuid.uuid4().hex)
        assert record_access("process-event", new_access_id(), model_id=model,
               task_id=task, process_id=request, stage="started")
        time.sleep(a.delay)
        assert record_access("process-event", new_access_id(), model_id=model,
               task_id=task, process_id=request, stage="result", outcome="completed")
        print(f"DEMO step {i+1}/{a.count}: model={i%3} task={i%5}", flush=True)

if __name__ == "__main__":
    main()

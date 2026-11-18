# Integrations: real events, not simulated AI work

Vera Atlas has three boundaries: **event producer → local metadata bus → viewer**. The default graph and bundled demo labels are synthetic. Real data sources are opt-in.

## Synthetic demo

```sh
python3 -B examples/emit_demo_activity.py --count 15 --delay 0.8
```

This program genuinely executes the steps it logs, but **does not call any model**. Its model and task identities are explicitly fictional.

## Actual Python process

Import the event writer from `scripts/vera_atlas_access.py`. In a real task runner:

```python
import hashlib
import uuid
from scripts.vera_atlas_access import new_access_id, record_access

def opaque(prefix, domain, value):
    raw = (domain + ":" + value).encode("utf-8")
    return prefix + "-" + hashlib.sha256(raw).hexdigest()[:24]

model = opaque("m", "provider-model", "your-provider/model")
task = opaque("q", "task-class", "your-task")
attempt = opaque("r", "attempt", uuid.uuid4().hex)

# Emit only at the actual invocation site.
record_access("process-event", new_access_id(), model_id=model,
              task_id=task, process_id=attempt, stage="started")
try:
    do_real_work()  # Replace with an actual call.
except Exception:
    record_access("process-event", new_access_id(), model_id=model,
                  task_id=task, process_id=attempt, stage="result",
                  outcome="provider_error")
    raise
else:
    record_access("process-event", new_access_id(), model_id=model,
                  task_id=task, process_id=attempt, stage="result",
                  outcome="completed")
```

A source identity is not automatically an LLM; if you instrument ordinary scripts, describe them as scripts. `process-event` accepts `configured`, `snapshot`, `started`, `result`, `retry`; result outcomes are `completed`, `provider_error`, `harness_timeout`. `snapshot` restores historical topology without pretending a current action happened.

The default event file is `~/Library/Application Support/VeraAtlas/atlas-access.jsonl`; both producer and app can override it using the `VERA_ATLAS_ACCESS_PATH` environment variable when launched from a terminal.

## DeepSeek Harness — optional

Observe native session logs only after explicitly selecting your directories (requires compatible logs and `zstd`):

```sh
VERA_ATLAS_DSH_SESSIONS_DIR="$HOME/.dsh/sessions" \
VERA_ATLAS_DSH_SKILLS_DIR="$HOME/.dsh/skills" \
python3 -B scripts/vera_atlas_skill_watch.py
```

This is a passive foreground watcher; Ctrl+C stops it. `--once` scans once; `--dry-run` does not emit events. It never starts a model or an agent. Do not register it as a background service until you have checked your local paths and permissions.

Optional native DSH desktop running-state integration needs both `VERA_ATLAS_DSH_WORKSPACE` and `VERA_ATLAS_DSH_SECRET_FILE` set to **local paths**, not raw secret values. Without them, the app does not contact DSH Desktop. A Finder launch may not inherit terminal environment variables.

## ChatGPT / external commands — optional

For *verified command execution*, `scripts/vera_atlas_chatgpt_workbench.py` logs start only after the subprocess launches, and result after real exit status:

```sh
python3 -B scripts/vera_atlas_chatgpt_workbench.py -- /usr/bin/true
```

For a text document actually read successfully, `scripts/vera_atlas_chatgpt_read.py` provides a path-restricted read and confirmed event. Direct native ChatGPT tool and skill calls are **not** intercepted automatically. There is no universal ChatGPT tool event feed.

## Graph format

```json
{"nodes":[{"id":"demo-one","g":"core","w":0.8},
          {"id":"demo-two","g":"src","w":0.9}],
 "edges":[{"a":"demo-one","b":"demo-two","w":0.5}]}
```

Every edge endpoint must exist, stable IDs should not contain private strings and weights must be finite. By default the build packages `examples/demo-graph.json`. Replacing it with a private graph requires an explicit local modification — **never commit your real memory data**.

The publisher only shows events for the installed adapters, not every hidden operation of an external model.

## Delivery controller (optional, no model calls)

The event bus and the rendering layer are independent. A new WebKit delivery
receipt acknowledges each 32-hex event ID **after the JavaScript graph merge**
has been accepted. It cannot prove that a particular pixel was visible.
Receipts contain only IDs, a process PID and timestamps, not prompts or paths.

The public app writes the receipt to
`~/Library/Application Support/VeraAtlas/atlas-render-ack.json`
with mode 0600. An operator may override this path using
`VERA_ATLAS_DELIVERY_ACK_PATH` when launching the **app**; event
writers must use the same bus location as the app.

The existing opt-in DeepSeek session watcher performs bounded delivery checks
roughly every 30 seconds, storing one deduplicated incident in its **existing**
`skill-watch-state.json`. To inspect without changing anything:

```sh
python3 -B scripts/vera_atlas_controller.py inspect
python3 -B scripts/vera_atlas_controller.py status
```

The ""high_volume_unverifiable"" and ""ack_unavailable"" states are *unknown*,
not fabricated successful deliveries. An actual dropped event produces a
""delivery_gap"" status after a short grace period. The controller cannot infer
uninstrumented ChatGPT calls: producers must emit genuine events first.

**Repair handoff:** The public module provides an optional
`cycle(state, dispatcher=callable)` hook, receiving only aggregate
counts and an incident type. It never starts a model, repairs software, opens
a socket or connects to anyone by default. An operator can connect this hook
to their **existing** Harness foreman, with their own provider/approval checks.
The private production setup has a separately configured foreman adapter; no
credentials or private session identifiers are included in this repository.

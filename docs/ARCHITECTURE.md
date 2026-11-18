# Architecture

## Data flow

```text
REAL, OPT-IN SOURCE                    LOCAL PROCESS                    APP
  Python instrumented task  ────────┐
  ChatGPT confirmed wrapper ────────┼→ vera_atlas_access.py
  DeepSeek session watcher ─────────┘    │
                                          ↓
            ~/Library/Application Support/VeraAtlas/atlas-access.jsonl
                         │  atlas_catalog + last 512 events
                         ↓
     AtlasLiveData.swift → AtlasLiveMonitor.swift → WKWebView
                          │                         │
                    JS merge receipts ←──────────────┘
                          │                         │
                                      atlas.js → sphere.js (WebGL/2D)
```

The optional `vera_atlas_controller.py` checks the existing event bus against the WebKit JS acceptance receipts (`atlas-render-ack.json`). Its state lives in the existing skill-watch state, not a new database. An operator-supplied dispatcher callback may pass a confirmed incident to an existing foreman. The public build has **no default dispatcher**, cannot launch a model and does not claim to see uninstrumented ChatGPT calls. A JavaScript receipt is not proof of a physical pixel.

The app never launches a model. The demo emitter is an example **program** that truly runs, but its labels are **synthetic**, not an assertion of AI-provider work.

## Identity contract

The graph is a stable set of points, `{"nodes":[{"id":"...","g":"core","w":0.8}],"edges":[{"a":"...","b":"...","w":0.6}]}`. `g` describes rendering class; `w` is visual weight. Edges are undirected for topology; event deltas specify which paths to emphasize.

The event bus uses IDs rather than raw paths or text:

| Prefix | Entity |
| --- | --- |
| `m-` | Persistent model |
| `r-` | One distinct process/attempt |
| `q-` | Task class |
| `h-` | Harness actor/session |
| `t-` | Tool |
| `f-` | Document |
| `p-` | Project |
| `k-` | Skill |
| `d-` | System provenance hub |

Opaque IDs are generated in producer code. A stable model can have many simultaneous process nodes. One process can connect model → request → task. Each event has a unique 32-character hexadecimal access ID.

## Native rendering

The Swift Package builds a menu-bar agent with AppKit, WKWebView and the bundled local HTML/JS. `AtlasLiveData` loads a deterministic **synthetic** seed from the app bundle. It can merge a persisted topology catalog derived from real events. `AtlasLiveMonitor` periodically polls the local file and sends metadata-only deltas into the WebView. The renderer uses WebGL where available and falls back to Canvas.

On ultrawide monitors, centre geometry is isotropic; peripheral nodes acquire a progressively stronger lateral fit. A Command-drag of the desktop-background window selects the **destination by cursor position at mouse release**. AppKit refits the window to that display's visible frame (not the original monitor dimensions), triggers WebKit layout readback, persists the display ID and preserves an ordinary-size restore frame on the destination. Display-arrangement changes revalidate the selected screen. The ordinary sphere view is still available. Idle edges and continuous-work edges are independent switches; work can pulse without inventing a specific route. The reversible **Comets over lines** option is off by default: the moving pulse uses linear interpolation of the very same projected line segment; turning it on restores the legacy 3D-projected glow head and tail.

## Event bus

`scripts/vera_atlas_access.py` is the supported local writer. It validates operations and IDs, uses a file lock, limits event history and persists topology in a catalog row. The file is created with mode 0600.

Relevant operations:

- `harness-event`: a **real** selected model, actor stage or tool event.
- `process-event`: `configured`, `snapshot`, `started`, `result`, `retry`.
- `tool` / `tool-result`: confirmed tool start/result.
- `document`, `project-link`, `skill`: supported metadata from observed sources.

`configured` and historical `snapshot` stages build nodes but must **not** imitate new live activity. `started` lights work at the genuine call site; `result` lights an actual provider or subprocess result.

## Supported and unsupported scopes

- **Default:** completely synthetic graph, no personal memory integration, and no automatic scanning of private directories.
- **Opt-in Python source:** producer can send confirmed real actions into the metadata bus.
- **Opt-in DeepSeek Harness:** passive native session reader plus optional Desktop loopback status. It only supports formats actually implemented here.
- **ChatGPT:** the local shell wrapper can report commands that it directly executes; not a universal hook to ChatGPT's private runtime.
- **Arbitrary app processes / cloud providers:** not auto-discovered. Each requires an explicit event adapter with a trustworthy evidence source.

## Source map

`VeraDesktopGraph.swift` window/menus; `AtlasWindow.swift` dragging; `AtlasActivity.swift` optional DSH status; `AtlasLiveData.swift` graph and route synthesis; `AtlasLiveMonitor.swift` event transport; `sphere.js` projection; `atlas.js` browser adapter; `examples/generate_demo.py` reproducible visual test graph.

The public build script deliberately packages `examples/demo-graph.json` and **never** exports the developer's real Obsidian/DSH memory graph.

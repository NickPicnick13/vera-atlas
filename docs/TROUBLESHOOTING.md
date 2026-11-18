# Troubleshooting

**No activity?** When idle lines are disabled, dots alone are expected. Start the bundled demo with `python3 -B examples/emit_demo_activity.py` after opening the app. If the graph still does not flash, confirm `~/Library/Application Support/VeraAtlas/atlas-access.jsonl` is receiving new records and that the app uses the same file.

**No Dock icon?** This is an `LSUIElement` menu-bar app. Look for the graph glyph in the macOS menu bar. One running instance is allowed. The public bundle ID and lock are separate from the personal app.

**Flat centre / cropped edges?** Toggle «Вписывать граф в экран». The centre should remain round in that mode, while the edge deforms progressively. The ordinary 3D sphere deliberately allows off-screen nodes when over-zoomed. Try resetting the view.

**No Harness traces?** The passive watcher is OFF until an operator supplies `VERA_ATLAS_DSH_SESSIONS_DIR`. `zstd` and a compatible native session format are required. Historical files are not replayed as fake real-time activity.

**Event written but not visible?** Check that it arrived **after** the observer attached. `snapshot` and `configured` are topology-only events. Check `operation`, stable hashed IDs, stage, real action timestamp, and WebKit rendering. Rebuild only this community app after source changes, not your main Harness environment.

**Apple security notice?** The build has a local ad-hoc signature; it is not notarized. Any public downloadable binary needs its own maintainer signing and Apple notarization. Do not put signing credentials in a repository.

**Performance issue?** Disable idle edges and persistent work edges, and reproduce on the synthetic graph. Include the OS version, CPU/GPU, browser backend and minimal **redacted** event sample in reports; never attach private desktop screenshots or chat logs.

**Missing ChatGPT calls?** Direct ChatGPT skills or connector invocations have no universal hook. Only explicitly instrumented commands and confirmed reads are observable. Do not treat a missing pulse as evidence of model inactivity.

## Comets do not reappear after changing the checkbox

The comet and line-only styles are different draw paths, both tied to actual
recorded edges. Disabling comets leaves a bright pulse on the exact visible
segment; enabling them restores the 3D-projected glowing head and tail.

If the checkbox changes line brightness but no comet appears, check that the
latest JavaScript is **inside the app bundle** and that the app was restarted:

```sh
./make_app.sh
cmp sphere.js .build/app/VeraAtlas.app/Contents/Resources/sphere.js
node tests/atlas_comets_qa.js
```

Quit and reopen **only VeraAtlas.app**, not a separate AI runtime. An active
event is needed to see a comet. This test does not alter display settings.

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

## Comets disappear when a second Atlas is enabled

In the two-display mode, both are independently rendered WebGL scenes and
each reads the saved "Comets over lines" setting. The first graph paint
applies that setting immediately; the live diagnostic receives the
cometsEnabled flag and the visible cometSignals count from each view.
A former near-plane projection bug could drop the glow head while the
clipped line remained visible. This is fixed by a bounded offset from the visible edge and a luminous
core on narrow displays when the head would otherwise merge with the line.
The ultrawide animation is left unchanged. Run:

    node tests/atlas_comets_qa.js

The deterministic regression checks 50 camera poses and the narrow
1920x1050 display, verifying separate illuminated comet heads and that
switching comet mode does not erase visible pulses. Active
comets still require actual traced graph links; inactive graphs do not show
fictional motion.

## Atlas disappears after moving it to another display

The previous desktop-background window retained the primary display's width.
For example, a 3,840-pixel window on a 1,920-pixel second display could put
the graph centre at the display's far edge, making the window appear invisible.

The fixed Command-drag handler chooses the destination from the global mouse
position **during the drag** (40 ms pointer check) as well as at release. It
immediately snaps the window to the destination on crossing, even if macOS
does not deliver mouseUp to the former huge desktop-level window, and refits
the backdrop to that display's visible frame,
and remembers the display ID for next launch. It also keeps the normal panel
restoration on the chosen monitor. It does not modify monitor resolution,
brightness or display arrangement.

Run the app build script after updating source and restart only VeraAtlas.app:
the running app cannot pick up Swift changes without a restart. On Macs with
two attached displays, run the native selftest with the executable argument
--selftest-backdrop-displays; the selftest reports both target regions.

This selftest validates real AppKit screen selection and window geometry, not
visible pixels. Verify the finished drag visually on each display.

## Changing between Odyssey and Samsung without restarting

In single-display mode, Atlas has one live window and GPU scene. The optional
dual-display setting creates a second full WKWebView/WebGL scene. To switch without relaunching,
right-click the Atlas icon in the menu bar and select either
Move Atlas to the other display or the named screen under Show Atlas on display.
This preserves the graph state and updates the persisted destination.
Switching also works from the normal compact panel, centred on the target.

For authorized local diagnostics (not a network service), the existing app
listens for a local DistributedNotificationCenter notification named
bundle-id.select-display containing a numeric display_id field. It validates
the ID against connected monitors and invokes the same native switch action.
No second app is started. Tests verified switching both directions using native
window coordinates and a physical desktop capture before and after moving.

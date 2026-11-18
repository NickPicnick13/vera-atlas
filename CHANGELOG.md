# Changelog

## [0.1.0-rc.2] — 2026-11-18

- Added the reversible **Comets over lines** menu option (off by default):
  bright light pulses travel on the exact visible edge when off; the original
  3D comet head and tail return when enabled.
- Added a deterministic renderer test for both modes and restoration.
- Added opaque WebKit JavaScript delivery receipts and optional controller
  inspection in the existing passive observer, with no model calls by default.
- Documented safe handoff hooks and clear limits: uninstrumented ChatGPT calls
  and physical pixel visibility are not inferred.
- Fixed desktop-background window disappearing when dragged from a wide primary monitor to a narrower, differently positioned second display. Command-drag now retargets its visible frame on release, remembers the chosen display and restores the ordinary panel there.
- Added a native display-selection/geometry self-test that checks each attached monitor without starting another app instance.
- Made cross-screen Command-drag robust when the old low-level window stops receiving drag/mouseUp events: a short-lived pointer tracker snaps the background onto the destination as the cursor crosses the display boundary.
- Added instant display switching from the menu bar (next monitor or named display). Reuses one WebGL context and window; exercised on real primary and secondary Mac screens without restarting.
- Maintained the 4,506-node synthetic sample, separate app preferences and
  opt-in source access; no personal graph or raw session data is shipped.

## [0.1.0-rc.1] — 2026-11-18

First source release candidate for the public GitHub repository.

- Extracted the native AppKit/WKWebView graph and Swift package from a private prototype.
- Replaced the private memory snapshot with a reproducible 4,506-node **synthetic** seed and safe screenshot.
- Removed local build artifacts, private project handoffs, screen-capture debug commands and unrelated GSAP vendor code.
- Isolated local settings/bundle ID/process lock so the community build does not overwrite the working private installation.
- Disabled automatic DSH session, skills and Desktop-secret access by default; made optional sources explicit.
- Preserved model → distinct process/attempt → task routes with short-lived illumination.
- Added bilingual quick starts, integration docs, privacy notes, tests and a macOS CI workflow.

**Not included:** Apple notarization, independent reproduction on an unrelated Mac, or universal tool instrumentation.

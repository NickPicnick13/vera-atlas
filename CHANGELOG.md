# Changelog

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

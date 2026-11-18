# Public release checklist

**Status:** PUBLIC SOURCE RELEASE CANDIDATE — https://github.com/NickPicnick13/vera-atlas (MIT). Source-only, no notarized macOS binary; the personal installed app is separate.

## Automated gates

- [x] Fresh `git ls-files` and staged diff contain only the approved allowlist.
- [x] No real memory graph or generated binaries in Git.
- [x] Tests passed on the preparation Mac (5 Python tests, Node syntax, Swift build, code-sign, native export). Independent GitHub Actions result tracked separately.
- [x] A synthetic event follows a distinct model → request → task route; no actual API request is made.
- [x] Source and document scan shows no credentials, private absolute paths, Notion exports, chat transcripts, or private screenshots.
- [x] No DSH session scanning or secret reading without explicit opt-in variables.
- [x] macOS bundle identifier does not collide with the original app.
- [x] Screenshot is a **headless synthetic** rendering, not a desktop capture.

## Publication decisions and distribution policy

- [x] **License:** MIT, approved by the owner. See `LICENSE`.
- [x] **GitHub namespace and repo name:** `NickPicnick13/vera-atlas`, using the existing signed-in account.
- [x] **Visibility:** public, explicitly approved by the owner.
- [x] **Brand and attribution:** Vera Atlas, copyright 2026 NickPicNick (NickPicnick13), repository contact through GitHub.
- [x] **Vendored assets:** unused GSAP excluded. App uses Apple/system frameworks, Python standard library and project source; review rights for future dependencies separately.
- [x] **Public binary policy:** source only; if distributing `.app` later, sign and notarize properly.
- [ ] **Independent Mac visual acceptance:** optional follow-up on another machine; programmatic WebGL screenshot and source-host build already passed.

## Public repository and future updates

```sh
# Existing public repository: https://github.com/NickPicnick13/vera-atlas
# For future approved updates:
git diff --cached --check
git push origin main
```

The initial GitHub repository was created from the reviewed source index. Before any future push, check `git status`, `git diff --cached`, `git ls-files` and `git remote -v`. Never push access logs, local builds, or real memory exports.

## Future release milestones

Optional DSH adapter compatibility tests against public/synthetic session fixtures, signed distributable builds, accessibility pass, measurements with 50k+ synthetic nodes, more adapters for external process event sources, CI checks for secret patterns, more descriptive user-facing node labels without exposing source content.

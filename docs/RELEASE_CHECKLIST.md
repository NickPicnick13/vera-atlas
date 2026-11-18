# Public release checklist

**Status:** community source release candidate for `NickPicnick13/vera-atlas`. This repository is a sanitized copy, **not** the installed personal app. A notarized download is not provided.

## Automated gates

- [ ] Fresh `git ls-files` and staged diff contain only the approved allowlist.
- [ ] No real memory graph or generated binaries in Git.
- [ ] Tests pass on a clean macOS build: Python unittest, Node syntax, Swift compile, ad-hoc code-sign and native graph export.
- [ ] A synthetic event follows a distinct model → request → task route; no actual API request is made.
- [ ] Source and document scan shows no credentials, private absolute paths, Notion exports, chat transcripts, or private screenshots.
- [ ] No DSH session scanning or secret reading without explicit opt-in variables.
- [ ] macOS bundle identifier does not collide with the original app.
- [ ] Screenshot is a **headless synthetic** rendering, not a desktop capture.

## Owner decisions before publishing

- [x] **License:** MIT, approved by the owner. See `LICENSE`.
- [x] **GitHub namespace and repo name:** `NickPicnick13/vera-atlas`, using the existing signed-in account.
- [x] **Visibility:** public, explicitly approved by the owner.
- [x] **Brand and attribution:** Vera Atlas, copyright 2026 NickPicNick (NickPicnick13), repository contact through GitHub.
- [ ] **Third-party rights.** Check whether any upstream contributions/borrowed snippets require notices or permission. Unused GSAP is intentionally excluded.
- [x] **Public binary policy:** source only; if distributing `.app` later, sign and notarize properly.
- [ ] **Final visual inspection.** Approve the preview and on-screen macOS controls on a second Mac if available.

## Publish only after approval

```sh
# Example, after the owner has selected a GitHub account, license, and visibility:
# gh repo create <NAMESPACE>/vera-atlas --public --source=. --remote=origin --push
```

The initial GitHub repository was created from the reviewed source index. Before any future push, check `git status`, `git diff --cached`, `git ls-files` and `git remote -v`. Never push access logs, local builds, or real memory exports.

## Future release milestones

Optional DSH adapter compatibility tests against public/synthetic session fixtures, signed distributable builds, accessibility pass, measurements with 50k+ synthetic nodes, more adapters for external process event sources, CI checks for secret patterns, more descriptive user-facing node labels without exposing source content.

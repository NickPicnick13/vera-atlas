# Third-party and license review

- **Swift / AppKit / WebKit / WebGL:** Apple/system tools and browser APIs; not vendored source libraries.
- **Python:** standard library only for the default demo and metadata event writers.
- **GSAP:** NOT included. An earlier private working folder contained an unused `gsap.min.js` file under a separate GreenSock license. No GSAP code was copied into this release candidate.
- **Fonts:** system fonts only. No font assets distributed.
- **Screenshots:** included `docs/preview.png` was rendered from deterministic synthetic project data, with no private desktop content.
- **User-contributed content:** no private memory, source titles, chats or logs copied.

**Project license: MIT.** See `LICENSE` for permission and conditions. The owners of any third-party contributions retain their own copyright; add required notices if new dependencies are introduced.

# Contributing

Thanks for helping improve Vera Atlas. We prioritize **real observability over decorative activity**.

1. Reproduce your issue using `examples/demo-graph.json` or a separate synthetic fixture.
2. Make the smallest implementation change. Keep the original personal prototype and production watchers untouched.
3. Run `python3 -B -m unittest discover -s tests -v`, `node --check sphere.js`, `node --check atlas.js`, and `./make_app.sh` on macOS.
4. Explain the evidence source for every new event or highlighted route. A pulse without a verified action is a bug, not a feature.
5. Keep memory, chats, tokens, unredacted paths, paid-model outputs and screenshots of other desktop windows **out** of commits and issues.
6. Open a pull request with a concise description, reproducible steps and relevant test results.

## Code and documentation

Swift/AppKit owns the window and event transport. `sphere.js` owns projection and WebGL/Canvas rendering; `atlas.js` adapts UI and animation. Python adapters produce normalized metadata events.

New integrations should be opt-in and never change the main task's success or failure. Avoid background services, paid-model calls or privileged permissions for a demo.

No third-party fonts or proprietary assets may be added without a separate rights review.

**License:** MIT. Preserve copyright/license notices in copies and derivatives. See `LICENSE`.

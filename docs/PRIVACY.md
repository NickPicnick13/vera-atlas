# Privacy & data handling

This source release is **private-data-free by default**.

### Not present in the repository

- Local memory vaults, human chat transcripts, task outputs, contact information or account credentials.
- API keys, session cookies, provider access tokens, developer's Obsidian files or private Notion content.
- The original live graph and its 47k+ personal-memory nodes.
- Host screenshots, verbose logs, temporary caches, old builds and backup copies.
- Vendored GSAP: the source project contained an unused copy with separate licensing; it is not part of this repo or necessary to build.

### Demo mode

The 4,506-node demo is generated from a fixed pseudorandom seed. Its identifiers start with `demo-`; it contains no source files, memory snippets or private paths. The screenshot in `docs/preview.png` is a headless rendering of this synthetic graph, **not** a screenshot of a user's desktop.

### Telemetry

The default event bus is `~/Library/Application Support/VeraAtlas/atlas-access.jsonl`, permission 0600. It stores validated categories, opaque/hashing-derived IDs, timestamps, stages and outcomes. It is not a chat log. Do **not** log text prompts, responses, file bodies, command arguments, raw session IDs or secrets. Keep any private mapping from a hash ID to a real source on your own machine.

The renderer sees only sanitized graph topology and event deltas. The application does not send those records to a web service.

### Optional integrations

Native DSH observation is **off by default**. To enable it, the operator must explicitly provide session/skill folder paths to the watcher; optional Desktop API status also needs an explicit workspace and secret-file path. Those configuration values remain on the user's machine, not in the repo. No API key is bundled or generated.

### Safe sharing

Before pushing changes, inspect `git diff --cached` and `git ls-files`. Never add `.build/`, `.env`, `atlas-access.jsonl`, `.dsh/`, secret files, screenshot captures of your desktop or real source exports. If you inadvertently commit a credential, revoke it at the provider immediately, then remove it from Git history. Deleting one later commit does **not** undo an exposed secret.

This public version uses its own bundle identifier and preferences; installing it does not silently replace the original personal build.

See also [SECURITY.md](../SECURITY.md).

## Delivery receipts and controller

The optional controller only compares opaque event IDs with an app-owned
JavaScript-acceptance receipt. That small receipt is stored locally with
owner-only permissions and limited to the most recent 512 IDs. It contains no
raw filenames, prompts, chat messages, model responses or credentials. The
controller's aggregate state reuses the watcher state file. No auto-dispatch
or model invocation is configured in the public edition.

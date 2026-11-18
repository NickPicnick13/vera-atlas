# Security policy

The release candidate has no credential ingestion or network telemetry in demo mode. Optional DSH integration is enabled only by explicit local configuration.

## Security reports

Use GitHub **Private vulnerability reporting**, if enabled in repository settings, or contact the repository owner privately. Do not post exploit details or credentials publicly.

## In scope

Credential or memory-file exposure, unintended session scanning, path traversal outside permitted document roots, unsafe event-bus permissions, accidental prompts or answers in WebKit, or a build that embeds developer's real data.

## Handling

Do not paste live credentials, tokens, private paths, full logs, session dumps, or account identifiers into issues. Use a synthetic reproduction and describe expected versus actual behavior. If a credential was pushed, revoke it immediately and purge Git history; deleting the latest file alone is not enough.

## Local live control

The optional CLI sends only a fixed set of visual-setting commands to the
running app via DistributedNotificationCenter. Its app target is explicit;
it has no command execution, HTTP endpoint, raw file-reading command, or
remote API. It is intended for the trusted local Mac user, not as a
multi-user authorization boundary. The sender waits for an app-owned
acknowledgement, and absence of acknowledgement is a failure, not success.
No personal memory records or API keys are needed for this feature.

## Design boundaries

Event bus uses metadata-only validated IDs and a local 0600 file. Background source readers must be opt-in; telemetry failures must not kill the user's primary job. Never accept an event name or file path as proof that a model actually worked unless a trustworthy execution source confirms it.

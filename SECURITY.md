# Security and privacy

## Scope

Codex Usage Status is a local macOS status app. It connects to the local Codex
App Server over stdio and does not use a private web endpoint, inject UI into
Codex, or manage API keys.

The public repository and its release assets must never contain:

- ChatGPT credentials, refresh tokens, access tokens, API keys, or `auth.json`
- prompt text, conversation text, thread titles, or raw App Server messages
- local quota history, token-activity history, profile indexes, or account data
- machine-specific absolute paths that identify a developer's home directory

The app may create local state at runtime under the user's Application Support
directory. That state is not part of the repository or release ZIP and should
remain user-only readable/writable.

## Public-repository hygiene

Before opening the repository or publishing a release, maintainers should:

1. Inspect `git status` and the complete reachable history for secrets.
2. Confirm that `.gitignore` covers credentials and runtime state.
3. Inspect the ZIP inventory and confirm it contains only the signed app bundle.
4. Run `plutil -lint` and `codesign --verify --deep --strict` on the extracted app.
5. Publish the exact asset name `CodexUsageStatus.app.zip` from a GitHub Release.

A commit pushed to `main` is not a release and is not used by the in-app update
checker.

## Reporting a vulnerability

Please do not post credentials, tokens, private App Server output, or a working
exploit in a public issue. Use a private GitHub Security Advisory for this
repository. If private advisories are unavailable, open a minimal issue that
contains only a redacted description and request a private contact channel.

When reporting, include the app version, macOS version, reproduction steps, and
whether the issue affects the signed release ZIP or a source build. Redact all
account identifiers and local paths before submitting.

## Maintainer release boundary

The app's updater downloads a user-approved GitHub Release asset, verifies the
provided digest when available, extracts it, and performs strict code-signature
verification. It does not silently replace a running app. Release assets must
not include source archives, tests, credentials, token activity, history, or
AppleDouble files.
## User-configured Feed boundary

Optional reset announcements fetch a user-configured third-party HTTPS RSS or
Atom endpoint. Redirect hosts are revalidated, private/loopback/link-local
addresses are rejected by an initial DNS preflight, XML external entities are
disabled, and response bodies are capped at 2 MiB with a 20-second timeout.
This is a preflight hostname policy; the URLSession transport does not claim
connection-level DNS/IP pinning against DNS rebinding.

Feed state is persisted in owner-only Application Support using atomic JSON
writes and corruption quarantine. The full configured URL is retained because
it is user configuration; query credentials, if present, are never emitted to
logs, notifications, errors, or analytics. Feed content is untrusted plain
text and is advisory only. It cannot change official quota state, reset times,
history, or notification delegate ownership.

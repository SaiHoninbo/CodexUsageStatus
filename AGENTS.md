# Repository Engineering Boundaries

## Distribution authority

CodexUsageStatus is distributed and updated exclusively through the official
GitHub Release flow:

```text
GitHub Releases latest
  → CodexUsageStatus.app.zip
  → bundle/signature validation
  → backup current /Applications app
  → local replacement and relaunch
  → rollback on replacement failure
```

GitHub Releases is the sole canonical distribution and update channel, and
`CodexUsageStatus.app.zip` is the canonical release artifact. Any change to
this distribution contract requires an explicit Web GPT PM product decision.
Missing release credentials are reported as an external blocker and stop the
release path. Credential setup must not be initiated unless explicitly
authorized.

## Signing classes

- `candidate` and default local `package` are local-only and may be ad-hoc.
- Apple Development is allowed for local testing only.
- Public GitHub Release assets must use `Developer ID Application` signing.
- Public release assets must not be ad-hoc or Apple Development signed.
- Notarization/stapling is required for a canonical public release when the
  external Apple credentials and service are available; lack of those
  credentials is an external release gate, not a reason to change channels.

`CODEX_RELEASE_MODE=1` is the formal package guard. It requires an explicit
keychain identity and rejects every identity that does not resolve to a
`Developer ID Application` certificate. Candidate/local package behavior must
remain available without that certificate.

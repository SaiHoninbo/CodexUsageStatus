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
`CodexUsageStatus.app.zip` is the canonical release artifact.
Candidate and local test packages may use ad-hoc signing. A public GitHub
Release must use a stable Developer ID Application identity and complete the
notarization/stapling and Gatekeeper validation path before publication.
Missing signing credentials are an external blocker; report and stop. Any
change to this distribution contract requires an explicit Web GPT PM product
decision.

## Signing classes

- `candidate` and local test packages use ad-hoc code signing.
- Public GitHub Release assets use Developer ID Application signing with a
  valid notarization ticket and Gatekeeper readback.
- `codesign --verify --deep --strict` remains the release artifact integrity
  check.
- GitHub account/repository ownership is the distribution trust boundary, with
  the stable signature providing publisher identity for the public artifact.

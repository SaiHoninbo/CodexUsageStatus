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
Candidate, local test, and public GitHub Release packages use ad-hoc signing.
The GitHub repository and fixed asset validation are the distribution trust
boundary; no Apple publisher credential or notarization service is required.
Any change to this distribution contract requires an explicit Web GPT PM
product decision.

## Signing classes

- `candidate`, local test, and public GitHub Release assets use ad-hoc code
  signing.
- `codesign --verify --deep --strict` remains the release artifact integrity
  check.
- GitHub account/repository ownership and fixed bundle validation are the
  distribution trust boundary. Ad-hoc signing provides bundle integrity, not
  a stable Apple publisher identity claim.

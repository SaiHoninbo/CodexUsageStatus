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
The canonical public artifact uses ad-hoc code signing. No external release
credential is required. Any change to this distribution contract
requires an explicit Web GPT PM product decision.

## Signing classes

- `candidate`, local `package`, and public GitHub Release assets use ad-hoc
  code signing.
- `codesign --verify --deep --strict` remains the release artifact integrity
  check.
- GitHub account/repository ownership is the distribution trust boundary;
  ad-hoc signing does not claim Apple publisher identity or platform approval.

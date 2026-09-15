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
Candidate and local-test packages use ad-hoc signing. The active public
GitHub Release policy also remains ad-hoc until an explicit future PM cutover.
The dormant Developer ID + notarization path may be prepared in source, but it
must fail closed unless a Developer ID Application identity, matching private
key, expected Team ID, notary Keychain profile, and explicit PM cutover gate are
all present. Credential availability alone does not authorize publishing a
Developer ID release. The active ad-hoc path requires no Apple publisher
credential or notarization service.
Any change to this distribution contract requires an explicit Web GPT PM
product decision.

## Signing classes

- `candidate` and local test assets always use ad-hoc code signing.
- Public GitHub Release assets currently use ad-hoc code signing; this remains
  the active policy until an explicit PM cutover.
- A dormant Developer ID release path may be maintained, but it is not the
  active public-release policy and may not publish without all required Apple
  signing/notarization material plus explicit PM cutover.
- `codesign --verify --deep --strict` remains the release artifact integrity
  check.
- GitHub account/repository ownership and fixed bundle validation are the
  distribution trust boundary. Ad-hoc signing provides bundle integrity, not
  a stable Apple publisher identity claim.

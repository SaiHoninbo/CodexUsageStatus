# Codex Usage Status

[繁體中文](README.zh-TW.md) · **English**

Codex Usage Status is a macOS menu-bar HUD for monitoring the quota reported by the local Codex App Server. It keeps the quota summary visible while you work in Codex, without modifying the Codex window or calling private network endpoints.

## Download

Download the latest application from **GitHub Releases**:

<https://github.com/SaiHoninbo/CodexUsageStatus/releases/latest>

Direct download of the latest release asset:

<https://github.com/SaiHoninbo/CodexUsageStatus/releases/latest/download/CodexUsageStatus.app.zip>

Do not download the repository source archive for installation. The source archive does not contain a ready-to-run application bundle.

## Requirements

- macOS 14.0 or later
- Apple Silicon Mac (the distributed application is currently an arm64 build)
- A local Codex / ChatGPT App Server installation that can run `codex app-server --listen stdio://`

## Install

1. Download `CodexUsageStatus.app.zip` from the Releases page.
2. Double-click the ZIP to extract `CodexUsageStatus.app`.
3. Move the extracted app to `/Applications`.
4. On first launch, right-click `CodexUsageStatus.app` and choose **Open**.
5. If macOS blocks the app, open **System Settings → Privacy & Security**, scroll to the security message, and choose **Open Anyway**.
6. Launch Codex Usage Status. It appears as a menu-bar item and can show the floating HUD beside Codex.

Candidate, local test, and public release bundles use the canonical GitHub
Release path with an ad-hoc signature. The fixed GitHub repository, asset name,
bundle validation, and strict code-signature check are the release trust
boundary; no external signing credential is required.
Keeping the app in `/Applications` also gives the login-item registration a
stable path.

## Permissions

Most monitoring features do not require Accessibility permission. Enable Accessibility only when you want to use the HUD clipboard controls:

- **Paste clipboard**: sends `⌘V` to the foreground Codex window.
- **Paste and submit**: sends `⌘V`, waits for the paste to finish, then sends one Return/Enter.

Open **System Settings → Privacy & Security → Accessibility** and enable `CodexUsageStatus.app` when paste/event posting is not trusted. Because releases use ad-hoc signing, macOS may treat a replacement as a new app identity and require authorization again; only follow the remediation when the app reports that permission is actually unavailable.

Notification permission is optional. Quota and token activity continue to work if notifications are denied.

## What it shows

- Primary and secondary quota remaining percentages
- Reset countdown and stale/offline state
- Low-quota notifications and menu-bar color status
- Token Activity summaries and daily token buckets
- Thirty-day local quota and token history
- Account health and managed multi-account profiles
- Per-account quota and aggregate token activity views
- HUD placement that follows the Codex window across displays
- Clipboard-only and paste-and-submit controls
- A native right-click HUD menu for refresh, account scope, sync cadence, clipboard actions, update checks, and HUD reset
- Update checks for new GitHub Releases
- Optional Repo/Chat plan-progress notifications at the 25%, 50%, and 75% milestones (plan ratio only; no ETA or step text)

The popover is intentionally organized into four sections: **Overview** for
current quota and quick actions, **History** for quota and Token Activity
trends, **Accounts** for complete profile management and per-account local
activity, and **Settings** for global HUD, notifications, sync, and updates.
The app does not run a direct Git client or a third-party Feed poller.

The menu-bar title stays focused on the active account's quota, for example `Codex 78%`. Token activity and reset-credit details remain in the popover instead of replacing the quota summary.

### Desktop Turn activity

The Overview Turn card is sourced from Codex Desktop's local rollout/session
JSONL under the known `CODEX_HOME` roots. It observes lifecycle metadata such as
Turn start, turn-local token totals, completion, failure, and interruption;
private App Server Turn callbacks remain transport-only and do not compete with
that visible timeline. The observer is read-only, starts existing files at
their current end, and does not create a second Codex process.

This path is metadata-first: it does not read or persist prompts, conversation
text, agent messages, or raw rollout content. Completion notifications may read
the local `session_index.jsonl` name for the finished thread so the notification
can identify the program/work item; that name is not persisted by UsageStatus.
Turn notification content remains disabled until a safe content capability
exists. Quota, account identity, Reset Credit, and other App Server-backed data
continue to use the local App Server transport.

## Account and privacy boundary

The app talks to the local Codex App Server over its stdio interface. It does not use a private web endpoint, inject UI into Codex, or manage API keys.

- The public repository, release ZIP, history files, Token Activity files, profile index, and logs do not contain ChatGPT credentials or tokens. Managed profiles may keep a local `auth.json` inside the user's owner-only Application Support `CODEX_HOME` so the local App Server can run; it is never uploaded, bundled, committed, or copied into the public release.
- Prompt text, conversation text, thread titles, and raw App Server authentication data are not written to the app's history files.
- Rollout/session observation is read-only and metadata-only; it records only
  lifecycle identifiers, timestamps, durations, and turn-local token totals
  needed for the current Turn card and local ledger.
- Local history, token activity, and managed-account credentials are kept under the user's Application Support directory with user-only file permissions.
- Managed profiles use separate `CODEX_HOME` directories and separate App Server processes.
- The system `~/.codex` profile is not copied into the app bundle or release ZIP.

## Updates

The app checks the official GitHub Release API at startup and periodically while
running. When a newer version is available:

1. The app shows a compact update state in the Overview and a detailed state in Settings, and may display one notification for that release.
2. **下載並覆蓋** downloads the fixed `CodexUsageStatus.app.zip` asset from the verified official GitHub Release, validates the bundle and signature, replaces the running app, and relaunches the new version. **查看 Release** remains available as the manual fallback.

Version discovery and installation accept only the fixed official repository and
its `CodexUsageStatus.app.zip` asset; arbitrary release URLs, archive paths,
bundle identifiers, versions, and invalid code signatures are rejected. GitHub
Releases remains the only distribution and update authority.

### Release requirements for maintainers

Maintainers should publish a GitHub Release with:

- A semantic-version tag such as `v2.4.28`
- An asset named exactly `CodexUsageStatus.app.zip`
- The signed app bundle inside the ZIP
- No `._*`, `__MACOSX`, source, test, auth, token, or history files

Record the checksum and ad-hoc signature verification result for each published artifact in the release notes or maintainer evidence. A commit or ZIP pushed to `main` alone does not create an in-app release update.

Before uploading the ZIP, validate the exact publishable artifact. The validator
fails closed unless the archive contains only the expected app, has the
expected bundle identifier and semantic version, and passes strict bundle
verification. Local, candidate, and public-release artifacts use the same
ad-hoc validation path:

```bash
./script/validate_release_artifact.sh outputs/CodexUsageStatus.app.zip 2.4.93
# Public GitHub Release validation:
./script/validate_release_artifact.sh --public-release outputs/CodexUsageStatus.app.zip 2.4.93
```

The ZIP must pass this validator before it is uploaded to a GitHub Release.

## Building from source

Use the repository root where you cloned this project. The build and packaging
commands below use paths relative to that root; no machine-specific path is
required.

```text
<repository-root>
```

Build the macOS executable with Swift Package Manager:

```bash
swift build --disable-sandbox -c release
```

For a local canonical package archive, use the packaging script. It omits
release debug information that could otherwise contain local build paths:

```bash
./script/build_and_run.sh package
```

The packaging script creates an ad-hoc signed local package by default,
validates the bundle, and writes the single canonical artifact to:

```text
outputs/CodexUsageStatus.app.zip
```

The `package` mode creates an ad-hoc package by default. For a public GitHub
Release, set `CODEX_RELEASE_MODE=1`; this marks the package as the intended
public artifact while retaining the same ad-hoc signature and fixed-bundle
validation. Publish that exact validated ZIP as a separate maintainer action.
GitHub Releases is the only distribution channel.

For disposable runtime or UI evidence, use the `candidate` mode instead:

```bash
./script/build_and_run.sh candidate
```

`candidate` builds and ad-hoc signs a temporary app bundle beneath `/private/tmp`,
verifies its signature, prints the exact `.app` path, and does not launch the
app. It never writes `outputs/CodexUsageStatus.app.zip`; that repository artifact
is created only by the explicit `package` mode. A candidate is not a release
artifact and may be removed after verification.

Run the core checks with:

```bash
./script/run_core_tests.sh
```

## Troubleshooting

### The HUD is not visible

Make sure Codex is running and the local App Server can be started. Use the menu-bar item to open the popover and press **Refresh**. The HUD follows the Codex window only when it can identify a Codex window.

### Clipboard paste keeps asking for permission

Confirm that the currently running copy of `CodexUsageStatus.app` is enabled under Accessibility. If you replaced the app, re-enable the new path and restart the app before trying the button again.

### The update checker says no release is available

The app reads the official GitHub `releases/latest` API endpoint. Confirm that a
published, non-draft Release exists in the repository and that the latest tag
uses a semantic version. The **查看 Release** action always remains available as
the manual update fallback.

### macOS says the app cannot be opened

Use the right-click **Open** flow once, then use **System Settings → Privacy & Security → Open Anyway** if macOS still blocks the ad-hoc signed bundle.

## License

This project is released under the MIT License. See [LICENSE](LICENSE).

For security and privacy boundaries, see [SECURITY.md](SECURITY.md).

# Codex Usage Status

[繁體中文](README.zh-TW.md) · **English**

Codex Usage Status is a macOS menu-bar HUD for monitoring the quota reported by the local Codex App Server. It keeps the quota summary visible while you work in Codex, without modifying the Codex window or calling private network endpoints.

## Download

Download the latest signed application from **GitHub Releases**:

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

Published release artifacts are signed with the maintainer's Apple Development identity and are not notarized with Apple; local `package` builds remain ad-hoc unless the explicit release-signing mode is used. The first-launch confirmation may therefore be expected. Keeping the app in `/Applications` also gives the login-item registration a stable path.

## Permissions

Most monitoring features do not require Accessibility permission. Enable Accessibility only when you want to use the HUD clipboard controls:

- **Paste clipboard**: sends `⌘V` to the foreground Codex window.
- **Paste and submit**: sends `⌘V`, waits for the paste to finish, then sends one Return/Enter.

Open **System Settings → Privacy & Security → Accessibility** and enable `CodexUsageStatus.app` when paste/event posting is not trusted. A correctly signed in-app update keeps the app identity stable, so do not routinely remove and re-add the entry; only follow the remediation when the app reports that permission is actually unavailable.

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

The app uses Sparkle 2 as its single in-app update authority. It checks the
signed appcast at startup and periodically while running. When a newer version
is available:

1. The app shows a compact update state in the Overview and a detailed state in Settings, and may display one notification for that release.
2. **開始更新** hands the authenticated confirmation, download, signature verification, installation, termination, and relaunch flow to Sparkle.
3. **View Release Notes** opens the official GitHub Release page for review.

The app does not perform a second direct GitHub download path. If the signed
appcast or matching release asset is unavailable, Sparkle leaves the installed
bundle unchanged and the official Release page remains available as a manual
fallback. The appcast URL, Ed25519 public key, and release signing material are
release infrastructure; private signing keys never belong in this repo or an
app bundle. Formal packaging must provide the maintainer's public key through
`CODEX_SPARKLE_PUBLIC_ED_KEY`; release mode refuses to build when it is absent.

### Release requirements for maintainers

Maintainers should publish a GitHub Release with:

- A semantic-version tag such as `v2.4.28`
- An asset named exactly `CodexUsageStatus.app.zip`
- The signed app bundle inside the ZIP
- No `._*`, `__MACOSX`, source, test, auth, token, or history files

Record the checksum and formal signing identity for each published artifact in the release notes or maintainer evidence. A commit or ZIP pushed to `main` alone does not create an in-app release update.

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

The packaging script creates an ad-hoc signed app, validates the bundle, and writes the single canonical artifact to:

```text
outputs/CodexUsageStatus.app.zip
```

The default `package` mode is a local packaging convenience and its ad-hoc
signature is not a formal public release. For a public release, maintainers
must use the existing release-signing path by setting
`CODEX_RELEASE_MODE=1` together with an explicit
`CODEX_RELEASE_SIGNING_IDENTITY`; the script refuses to silently fall back to
ad-hoc signing in that mode. Publishing the resulting ZIP to a GitHub Release
is a separate explicit maintainer action.

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

A maintainer must publish the signed Sparkle appcast and matching GitHub Release asset first. The app checks the official repository's `releases/latest/download/appcast.xml` and only installs updates through Sparkle's authenticated path. The official Release page remains available as a manual fallback when the feed is unavailable.

### macOS says the app cannot be opened

Use the right-click **Open** flow once, then use **System Settings → Privacy & Security → Open Anyway** if macOS still blocks the ad-hoc signed bundle.

## License

This project is released under the MIT License. See [LICENSE](LICENSE).

For security and privacy boundaries, see [SECURITY.md](SECURITY.md).

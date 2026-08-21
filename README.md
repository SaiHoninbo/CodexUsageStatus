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

The application is currently ad-hoc signed and is not notarized with Apple. The first-launch confirmation is therefore expected. Keeping the app in `/Applications` also gives the login-item registration a stable path.

## Permissions

Most monitoring features do not require Accessibility permission. Enable Accessibility only when you want to use the HUD clipboard controls:

- **Paste clipboard**: sends `⌘V` to the foreground Codex window.
- **Paste and submit**: sends `⌘V`, waits for the paste to finish, then sends one Return/Enter.

Open **System Settings → Privacy & Security → Accessibility** and enable `CodexUsageStatus.app`. If the app was moved or replaced, macOS may show a new permission entry; remove an obsolete entry and enable the current app path.

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

The menu-bar title stays focused on the active account's quota, for example `Codex 78%`. Token activity and reset-credit details remain in the popover instead of replacing the quota summary.

## Account and privacy boundary

The app talks to the local Codex App Server over its stdio interface. It does not use a private web endpoint, inject UI into Codex, or manage API keys.

- The public repository, release ZIP, history files, Token Activity files, profile index, and logs do not contain ChatGPT credentials or tokens. Managed profiles may keep a local `auth.json` inside the user's owner-only Application Support `CODEX_HOME` so the local App Server can run; it is never uploaded, bundled, committed, or copied into the public release.
- Prompt text, conversation text, thread titles, and raw App Server authentication data are not written to the app's history files.
- Local history, token activity, and managed-account credentials are kept under the user's Application Support directory with user-only file permissions.
- Managed profiles use separate `CODEX_HOME` directories and separate App Server processes.
- The system `~/.codex` profile is not copied into the app bundle or release ZIP.

## Updates

The app checks the GitHub `latest release` endpoint at startup and periodically while running. When a newer version is available:

1. The app shows an update state in the popover and may display one notification for that release.
2. You choose **Download update**.
3. The ZIP is downloaded to the user's Application Support updates directory.
4. The app verifies the archive checksum when GitHub provides one and performs strict code-signature verification after extraction.
5. The app reveals the verified app in Finder so you can manually replace the copy in `/Applications`.

The updater does **not** silently overwrite or replace a running application. This is intentional while the distribution remains ad-hoc signed and not notarized.

### Release requirements for maintainers

The updater expects a GitHub Release with:

- A semantic-version tag such as `v2.4.26`
- An asset named exactly `CodexUsageStatus.app.zip`
- The signed app bundle inside the ZIP
- No `._*`, `__MACOSX`, source, test, auth, token, or history files

For the current `2.4.26 / build 46` package, the verified ZIP SHA-256 is:

```text
ae642ac40392b0f339957eb13f5bda1b315f5ea888046db555eb8a115a3e48a1
```

If there is no GitHub Release yet, the updater correctly reports that no formal release is available; committing a ZIP to `main` alone does not create a release update.

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

For a public or distributable package, use the packaging script instead. It
omits release debug information that could otherwise contain local build paths:

```bash
./script/build_and_run.sh package
```

The packaging script creates an ad-hoc signed app, validates the bundle, and writes the single canonical artifact to:

```text
outputs/CodexUsageStatus.app.zip
```

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

A maintainer must publish a GitHub Release first. The release must contain the exact asset name `CodexUsageStatus.app.zip`; a commit or a source ZIP is not enough.

### macOS says the app cannot be opened

Use the right-click **Open** flow once, then use **System Settings → Privacy & Security → Open Anyway** if macOS still blocks the ad-hoc signed bundle.

## License

This project is released under the MIT License. See [LICENSE](LICENSE).

For security and privacy boundaries, see [SECURITY.md](SECURITY.md).

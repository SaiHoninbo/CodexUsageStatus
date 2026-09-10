#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 [--notarize] <CodexUsageStatus.app.zip> [expected-version]" >&2
  exit 2
}

MODE="validate"
if [[ "${1:-}" == "--notarize" ]]; then
  MODE="notarize"
  shift
fi

ZIP_PATH="${1:-}"
EXPECTED_VERSION="${2:-}"
[[ -n "$ZIP_PATH" ]] || usage
[[ -f "$ZIP_PATH" ]] || { echo "release artifact does not exist: $ZIP_PATH" >&2; exit 3; }

# Notarization credentials are deliberately supplied by the caller through an
# existing notarytool keychain profile. No credential is read from or written
# to the repository.
if [[ "$MODE" == "notarize" ]]; then
  NOTARY_PROFILE="${NOTARYTOOL_KEYCHAIN_PROFILE:-}"
  if [[ -z "$NOTARY_PROFILE" ]]; then
    echo "notarization requires NOTARYTOOL_KEYCHAIN_PROFILE" >&2
    exit 3
  fi
  command -v xcrun >/dev/null 2>&1 || { echo "xcrun is required for notarization" >&2; exit 3; }
fi

WORK_DIR="$(mktemp -d /private/tmp/codex-release-artifact.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT
EXTRACT_DIR="$WORK_DIR/extracted"
mkdir -p "$EXTRACT_DIR"

if ! /usr/bin/unzip -q "$ZIP_PATH" -d "$EXTRACT_DIR"; then
  echo "release artifact is not a valid ZIP" >&2
  exit 3
fi

ENTRIES="$(/usr/bin/unzip -Z1 "$ZIP_PATH" 2>/dev/null || true)"
[[ -n "$ENTRIES" ]] || { echo "release artifact has no entries" >&2; exit 3; }

while IFS= read -r entry; do
  case "$entry" in
    CodexUsageStatus.app|CodexUsageStatus.app/|CodexUsageStatus.app/*) ;;
    *) echo "unexpected release archive entry: $entry" >&2; exit 3 ;;
  esac
done <<< "$ENTRIES"

APP_BUNDLE="$EXTRACT_DIR/CodexUsageStatus.app"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/CodexUsageStatus"
[[ -d "$APP_BUNDLE" && -f "$INFO_PLIST" && -x "$EXECUTABLE" ]] || {
  echo "release artifact does not contain the expected app bundle" >&2
  exit 3
}

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null || true)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || true)"
[[ "$BUNDLE_ID" == "com.openai.codex-usage-status" ]] || { echo "unexpected bundle identifier: $BUNDLE_ID" >&2; exit 3; }
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || { echo "invalid release version: $VERSION" >&2; exit 3; }
if [[ -n "$EXPECTED_VERSION" && "$VERSION" != "$EXPECTED_VERSION" ]]; then
  echo "release version mismatch: expected $EXPECTED_VERSION, got $VERSION" >&2
  exit 3
fi

codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null
SIGNING_DETAILS="$(codesign -dvvv "$APP_BUNDLE" 2>&1)"
if ! printf '%s\n' "$SIGNING_DETAILS" | grep -Fq 'Authority=Developer ID Application:'; then
  echo "release artifact is not signed by Developer ID Application" >&2
  exit 3
fi
TEAM_IDENTIFIER="$(printf '%s\n' "$SIGNING_DETAILS" | sed -n 's/^TeamIdentifier=//p' | head -1)"
if [[ -z "$TEAM_IDENTIFIER" || "$TEAM_IDENTIFIER" == "not set" ]]; then
  echo "release artifact has no TeamIdentifier" >&2
  exit 3
fi

if [[ "$MODE" == "notarize" ]]; then
  NOTARY_UPLOAD_ZIP="$WORK_DIR/notary-upload.zip"
  COPYFILE_DISABLE=1 ditto --norsrc -c -k --keepParent "$APP_BUNDLE" "$NOTARY_UPLOAD_ZIP"
  xcrun notarytool submit "$NOTARY_UPLOAD_ZIP" --wait --keychain-profile "$NOTARY_PROFILE"
  xcrun stapler staple "$APP_BUNDLE"
fi

# Validation mode is intentionally strict: a ZIP is publishable only after a
# stapled ticket and Gatekeeper acceptance are both present.
xcrun stapler validate "$APP_BUNDLE" >/dev/null
spctl -a -vv --type execute "$APP_BUNDLE" >/dev/null

if [[ "$MODE" == "notarize" ]]; then
  TEMP_ZIP="$WORK_DIR/CodexUsageStatus.app.zip"
  COPYFILE_DISABLE=1 ditto --norsrc -c -k --keepParent "$APP_BUNDLE" "$TEMP_ZIP"
  mv "$TEMP_ZIP" "$ZIP_PATH"
fi

echo "Validated public release artifact: $ZIP_PATH (version $VERSION, team $TEAM_IDENTIFIER)"

#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 [--public-release|--notarize] <CodexUsageStatus.app.zip> [expected-version]" >&2
  exit 2
}

PUBLIC_RELEASE=0
NOTARIZE=0
case "${1:-}" in
  --public-release)
    PUBLIC_RELEASE=1
    shift
    ;;
  --notarize)
    PUBLIC_RELEASE=1
    NOTARIZE=1
    shift
    ;;
esac

if [[ "$NOTARIZE" == 1 ]]; then
  NOTARY_PROFILE="${NOTARYTOOL_KEYCHAIN_PROFILE:-}"
  [[ -n "$NOTARY_PROFILE" ]] || {
    echo "notarization requires NOTARYTOOL_KEYCHAIN_PROFILE" >&2
    exit 3
  }
  command -v xcrun >/dev/null 2>&1 || {
    echo "xcrun is required for notarization" >&2
    exit 3
  }
fi

ZIP_PATH="${1:-}"
EXPECTED_VERSION="${2:-}"
[[ -n "$ZIP_PATH" ]] || usage
[[ -f "$ZIP_PATH" ]] || { echo "release artifact does not exist: $ZIP_PATH" >&2; exit 3; }

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
if [[ "$PUBLIC_RELEASE" == 1 ]]; then
  if printf '%s\n' "$SIGNING_DETAILS" | grep -Fq 'Signature=adhoc'; then
    echo "public release artifact must not use an ad-hoc code signature" >&2
    exit 3
  fi
  AUTHORITY="$(printf '%s\n' "$SIGNING_DETAILS" | awk '/^Authority=/{sub(/^Authority=/, ""); print; exit}')"
  if [[ "$AUTHORITY" != Developer\ ID\ Application:* ]]; then
    echo "public release artifact must use a Developer ID Application signature" >&2
    exit 3
  fi
  TEAM_IDENTIFIER="$(printf '%s\n' "$SIGNING_DETAILS" | awk '/^TeamIdentifier=/{sub(/^TeamIdentifier=/, ""); print; exit}')"
  if [[ -z "$TEAM_IDENTIFIER" || "$TEAM_IDENTIFIER" == "not set" ]]; then
    echo "public release artifact must contain a TeamIdentifier" >&2
    exit 3
  fi
  if [[ "$NOTARIZE" == 1 ]]; then
    NOTARY_UPLOAD_ZIP="$WORK_DIR/notary-upload.zip"
    COPYFILE_DISABLE=1 ditto --norsrc -c -k --keepParent "$APP_BUNDLE" "$NOTARY_UPLOAD_ZIP"
    if ! xcrun notarytool submit "$NOTARY_UPLOAD_ZIP" --wait --keychain-profile "$NOTARY_PROFILE"; then
      echo "notarization failed; refusing to publish the artifact" >&2
      exit 3
    fi
    if ! xcrun stapler staple "$APP_BUNDLE"; then
      echo "stapling failed; refusing to publish the artifact" >&2
      exit 3
    fi
    STAPLED_ZIP="$WORK_DIR/CodexUsageStatus.app.zip"
    COPYFILE_DISABLE=1 ditto --norsrc -c -k --keepParent "$APP_BUNDLE" "$STAPLED_ZIP"
    mv "$STAPLED_ZIP" "$ZIP_PATH"
  fi
  if ! xcrun stapler validate "$APP_BUNDLE" >/dev/null 2>&1; then
    echo "public release artifact must contain a valid stapled notarization ticket" >&2
    exit 3
  fi
  if ! spctl --assess --type execute --verbose=4 "$APP_BUNDLE" >/dev/null 2>&1; then
    echo "public release artifact failed Gatekeeper assessment" >&2
    exit 3
  fi
  echo "Validated public GitHub release artifact: $ZIP_PATH (version $VERSION)"
else
  if ! printf '%s\n' "$SIGNING_DETAILS" | grep -Fq 'Signature=adhoc'; then
    echo "local/candidate artifact must use an ad-hoc code signature unless --public-release is specified" >&2
    exit 3
  fi
  echo "Validated local ad-hoc artifact: $ZIP_PATH (version $VERSION)"
fi

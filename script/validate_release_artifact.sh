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
  echo "notarization is not used by the GitHub ad-hoc distribution policy" >&2
  exit 2
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
  if ! printf '%s\n' "$SIGNING_DETAILS" | grep -Fq 'Signature=adhoc'; then
    echo "public GitHub release artifact must use the repository's ad-hoc signature policy" >&2
    exit 3
  fi
  echo "Validated public GitHub ad-hoc release artifact: $ZIP_PATH (version $VERSION)"
else
  if ! printf '%s\n' "$SIGNING_DETAILS" | grep -Fq 'Signature=adhoc'; then
    echo "local/candidate artifact must use an ad-hoc code signature unless --public-release is specified" >&2
    exit 3
  fi
  echo "Validated local ad-hoc artifact: $ZIP_PATH (version $VERSION)"
fi

#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CodexUsageStatus"
BUNDLE_ID="com.openai.codex-usage-status"
MIN_SYSTEM_VERSION="14.0"
RELEASE_MODE="${CODEX_RELEASE_MODE:-0}"
SIGNING_MODE="${CODEX_SIGNING_MODE:-adhoc}"
DEVELOPER_IDENTITY="${CODEX_DEVELOPER_IDENTITY:-}"
EXPECTED_TEAM_ID="${CODEX_EXPECTED_TEAM_ID:-}"
NOTARY_PROFILE="${CODEX_NOTARY_PROFILE:-}"

case "$MODE" in
  package)
    SHOULD_STOP_PROCESS=0
    SHOULD_PACKAGE=1
    ;;
  candidate)
    SHOULD_STOP_PROCESS=0
    SHOULD_PACKAGE=0
    ;;
  run|--logs|logs|--telemetry|telemetry|--verify|verify)
    SHOULD_STOP_PROCESS=1
    SHOULD_PACKAGE=0
    ;;
  --debug|debug)
    SHOULD_STOP_PROCESS=1
    SHOULD_PACKAGE=0
    ;;
  *)
    echo "usage: $0 [package|candidate|run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

case "$RELEASE_MODE" in
  0|1) ;;
  *)
    echo "CODEX_RELEASE_MODE must be 0 or 1" >&2
    exit 2
    ;;
esac
if [[ "$RELEASE_MODE" == "1" && "$MODE" != "package" ]]; then
  echo "CODEX_RELEASE_MODE=1 is only valid with package mode" >&2
  exit 3
fi

case "$SIGNING_MODE" in
  adhoc)
    ;;
  developer-id)
    if [[ "$RELEASE_MODE" != "1" || "$MODE" != "package" ]]; then
      echo "CODEX_SIGNING_MODE=developer-id is only valid for an authorized release package" >&2
      exit 3
    fi
    if [[ "${CODEX_DEVELOPER_ID_CUTOVER:-0}" != "1" ]]; then
      echo "Developer ID public signing requires an explicit PM cutover gate: CODEX_DEVELOPER_ID_CUTOVER=1" >&2
      exit 3
    fi
    if [[ -z "$DEVELOPER_IDENTITY" ]]; then
      echo "Developer ID mode requires CODEX_DEVELOPER_IDENTITY" >&2
      exit 3
    fi
    if [[ ! "$EXPECTED_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
      echo "Developer ID mode requires a valid 10-character CODEX_EXPECTED_TEAM_ID" >&2
      exit 3
    fi
    if [[ -z "$NOTARY_PROFILE" ]]; then
      echo "Developer ID mode requires CODEX_NOTARY_PROFILE" >&2
      exit 3
    fi

    IDENTITY_LIST="$(/usr/bin/security find-identity -v -p codesigning 2>&1 || true)"
    MATCHING_IDENTITY_COUNT="$(printf '%s\n' "$IDENTITY_LIST" | /usr/bin/awk \
      -v selector="$DEVELOPER_IDENTITY" \
      -v team="$EXPECTED_TEAM_ID" \
      '/^[[:space:]]*[0-9]+\)/ {
        identity_line = $0
        sub(/^[[:space:]]*[0-9]+\)[[:space:]]*/, "", identity_line)
        identity_hash = identity_line
        sub(/[[:space:]]+".*$/, "", identity_hash)
        identity_name = identity_line
        sub(/^[^\"]*\"/, "", identity_name)
        sub(/\"$/, "", identity_name)
        team_suffix = "(" team ")"
        has_expected_team = substr(identity_name, length(identity_name) - length(team_suffix) + 1) == team_suffix
        exact_selector = selector == identity_name || toupper(selector) == toupper(identity_hash)
        if (exact_selector && index(identity_name, "Developer ID Application:") == 1 && has_expected_team) count++
      }
      END { print count + 0 }')"
    if [[ "$MATCHING_IDENTITY_COUNT" != "1" ]]; then
      echo "CODEX_DEVELOPER_IDENTITY must resolve to exactly one valid Developer ID Application identity for CODEX_EXPECTED_TEAM_ID (found $MATCHING_IDENTITY_COUNT)" >&2
      exit 3
    fi
    ;;
  *)
    echo "CODEX_SIGNING_MODE must be adhoc or developer-id" >&2
    exit 2
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE_DIR="$(mktemp -d /private/tmp/codex-usage-status-stage.XXXXXX)"
# `run` and `--verify` launch the bundle asynchronously.  Do not delete the
# temporary bundle when those modes return, or macOS may still be loading its
# executable/resources.  Candidate mode also intentionally leaves its bundle
# available for later runtime evidence. Package mode is the only path whose
# consumer is the finished ZIP, so it can safely clean its staging directory.
if [[ "$MODE" == "package" ]]; then
  PACKAGE_TEMP_DIR=""
  PACKAGE_TEMP_ZIP=""
  cleanup_package() {
    rm -rf "$STAGE_DIR"
    if [[ -n "$PACKAGE_TEMP_ZIP" ]]; then
      rm -f "$PACKAGE_TEMP_ZIP"
    fi
    if [[ -n "$PACKAGE_TEMP_DIR" ]]; then
      rmdir "$PACKAGE_TEMP_DIR" 2>/dev/null || true
    fi
  }
  trap cleanup_package EXIT
fi
APP_BUNDLE="$STAGE_DIR/$APP_NAME.app"
OUTPUT_DIR="$ROOT_DIR/outputs"
OUTPUT_ZIP="$OUTPUT_DIR/$APP_NAME.app.zip"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICONSET_DIR="$ROOT_DIR/Resources/AppIcon.iconset"
ICON_FILE="$ROOT_DIR/Resources/AppIcon.icns"

## Release bundles must not carry developer-local source/object paths in
## embedded debug information. The shipped app is not a debug artifact, so
## omit DWARF entirely rather than publishing machine-specific paths.
SWIFT_RELEASE_ARGS=( -Xswiftc -gnone )

if [[ "$SHOULD_STOP_PROCESS" == 1 ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

swift build --disable-sandbox -c release "${SWIFT_RELEASE_ARGS[@]}"
BUILD_BINARY="$(swift build --disable-sandbox --show-bin-path -c release "${SWIFT_RELEASE_ARGS[@]}")/$APP_NAME"

mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

if [[ -d "$ICONSET_DIR" ]]; then
  # Some CommandLineTools/iconutil combinations reject an otherwise valid
  # iconset (the app remains fully functional without an embedded icns).
  # Keep packaging deterministic instead of aborting the signed bundle.
  if ! TMPDIR=/private/tmp iconutil --convert icns --output "$APP_RESOURCES/AppIcon.icns" "$ICONSET_DIR"; then
    if [[ -f "$ICON_FILE" ]]; then
      echo "warning: iconutil could not convert AppIcon.iconset; using the checked-in AppIcon.icns fallback" >&2
      cp "$ICON_FILE" "$APP_RESOURCES/AppIcon.icns"
    else
      echo "warning: iconutil could not convert AppIcon.iconset; continuing without embedded icns" >&2
      rm -f "$APP_RESOURCES/AppIcon.icns"
    fi
  fi
elif [[ -f "$ICON_FILE" ]]; then
  cp "$ICON_FILE" "$APP_RESOURCES/AppIcon.icns"
fi

# Candidate and local-test bundles remain ad-hoc. Public GitHub releases also
# remain ad-hoc by default; Developer ID is a separately gated dormant path.
if [[ "$SIGNING_MODE" == "adhoc" ]]; then
  SIGNING_IDENTITY="-"
else
  SIGNING_IDENTITY="$DEVELOPER_IDENTITY"
fi

sign_deep() {
  local target="$1"
  if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$target"
  elif [[ "$RELEASE_MODE" == "1" ]]; then
    codesign --force --deep --options runtime --sign "$SIGNING_IDENTITY" "$target"
  else
    codesign --force --deep --sign "$SIGNING_IDENTITY" "$target"
  fi
}

cat > "$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>Codex Usage Status</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Codex Usage Status</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>2.4.110</string>
  <key>CFBundleVersion</key>
  <string>126</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

xattr -cr "$APP_BUNDLE"

sign_deep "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE"

if [[ "$SIGNING_MODE" == "developer-id" ]]; then
  SIGNING_DETAILS="$(codesign -dvvv "$APP_BUNDLE" 2>&1)"
  if printf '%s\n' "$SIGNING_DETAILS" | grep -Fq 'Signature=adhoc'; then
    echo "Developer ID signing unexpectedly produced an ad-hoc signature" >&2
    exit 3
  fi
  if ! printf '%s\n' "$SIGNING_DETAILS" | grep -Fq 'Authority=Developer ID Application:'; then
    echo "signed app is not chained to a Developer ID Application certificate" >&2
    exit 3
  fi
  if ! printf '%s\n' "$SIGNING_DETAILS" | grep -Fq "TeamIdentifier=$EXPECTED_TEAM_ID"; then
    echo "signed app TeamIdentifier does not match CODEX_EXPECTED_TEAM_ID" >&2
    exit 3
  fi
  if ! printf '%s\n' "$SIGNING_DETAILS" | grep -Eq '^flags=.*\(runtime\)'; then
    echo "signed app is missing the Hardened Runtime flag" >&2
    exit 3
  fi
  if ! printf '%s\n' "$SIGNING_DETAILS" | grep -Eq '^Timestamp=.+$' || \
      printf '%s\n' "$SIGNING_DETAILS" | grep -Fq 'Timestamp=none'; then
    echo "signed app is missing a secure code-signing timestamp" >&2
    exit 3
  fi

  NOTARY_SUBMISSION_ZIP="$STAGE_DIR/$APP_NAME.notarization.zip"
  NOTARY_RESULT="$STAGE_DIR/$APP_NAME.notarization-result.json"
  COPYFILE_DISABLE=1 ditto --norsrc -c -k --keepParent "$APP_BUNDLE" "$NOTARY_SUBMISSION_ZIP"
  if ! xcrun notarytool submit "$NOTARY_SUBMISSION_ZIP" \
      --keychain-profile "$NOTARY_PROFILE" \
      --wait \
      --output-format json > "$NOTARY_RESULT"; then
    cat "$NOTARY_RESULT" >&2
    echo "Developer ID notarization submission failed" >&2
    exit 3
  fi
  if ! grep -Eq '"status"[[:space:]]*:[[:space:]]*"Accepted"' "$NOTARY_RESULT"; then
    cat "$NOTARY_RESULT" >&2
    echo "Developer ID notarization was not accepted" >&2
    exit 3
  fi

  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
fi

if [[ "$SHOULD_PACKAGE" == 1 ]]; then
  mkdir -p "$OUTPUT_DIR"
  if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    PACKAGE_TEMP_DIR="$(mktemp -d "$OUTPUT_DIR/.${APP_NAME}.release.XXXXXX")"
    PACKAGE_TEMP_ZIP="$PACKAGE_TEMP_DIR/$APP_NAME.app.zip"
    COPYFILE_DISABLE=1 ditto --norsrc -c -k --keepParent "$APP_BUNDLE" "$PACKAGE_TEMP_ZIP"
    "$ROOT_DIR/script/validate_release_artifact.sh" \
      --public-release-developer-id "$PACKAGE_TEMP_ZIP" "2.4.110" "$EXPECTED_TEAM_ID"
    mv "$PACKAGE_TEMP_ZIP" "$OUTPUT_ZIP"
    rmdir "$PACKAGE_TEMP_DIR"
    PACKAGE_TEMP_ZIP=""
    PACKAGE_TEMP_DIR=""
  else
    COPYFILE_DISABLE=1 ditto --norsrc -c -k --keepParent "$APP_BUNDLE" "$OUTPUT_ZIP"
  fi
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  package)
    echo "Packaged $OUTPUT_ZIP"
    ;;
  candidate)
    echo "Candidate app: $APP_BUNDLE"
    echo "Candidate is disposable, temporary-only, and was not launched."
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE"
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
esac

#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CodexUsageStatus"
BUNDLE_ID="com.openai.codex-usage-status"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE_DIR="/private/tmp/codex-usage-status-stage"
APP_BUNDLE="$STAGE_DIR/$APP_NAME.app"
OUTPUT_DIR="$ROOT_DIR/outputs"
OUTPUT_ZIP="$OUTPUT_DIR/$APP_NAME.app.zip"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICONSET_DIR="$ROOT_DIR/Resources/AppIcon.iconset"
ICON_FILE="$ROOT_DIR/Resources/AppIcon.icns"
## Release bundles must not carry developer-local source/object paths in
## embedded debug information. The shipped app is not a debug artifact, so
## omit DWARF entirely rather than publishing machine-specific paths.
SWIFT_RELEASE_ARGS=( -Xswiftc -gnone )

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build --disable-sandbox -c release "${SWIFT_RELEASE_ARGS[@]}"
BUILD_BINARY="$(swift build --disable-sandbox --show-bin-path -c release "${SWIFT_RELEASE_ARGS[@]}")/$APP_NAME"

rm -rf "$STAGE_DIR"
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
  <string>2.4.49</string>
  <key>CFBundleVersion</key>
  <string>69</string>
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
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE"
mkdir -p "$OUTPUT_DIR"
COPYFILE_DISABLE=1 ditto --norsrc -c -k --keepParent "$APP_BUNDLE" "$OUTPUT_ZIP"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  package)
    echo "Packaged $OUTPUT_ZIP"
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
  *)
    echo "usage: $0 [package|run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

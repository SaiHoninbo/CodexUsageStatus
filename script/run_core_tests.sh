#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/core-tests"
mkdir -p "$BUILD_DIR"

swiftc -parse-as-library \
  -module-cache-path "$BUILD_DIR/module-cache" \
  "$ROOT_DIR/Sources/CodexUsageStatus/Models.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/JSONRPC.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/HistoryStore.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/TokenActivityStore.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/AccountModels.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/ProfileStore.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/CodexCLIResolver.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/AccountManagementService.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/AccountProfileDisplay.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/ThresholdPolicy.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/HUDScale.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/HUDMetrics.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/CodexPromptShortcut.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/CodexApplicationPolicy.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/ClipboardTemporaryOperationPolicy.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/HUDQuotaPresentationPolicy.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/HUDVisibilityPolicy.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/HUDPlacementPolicy.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/HUDDragPolicy.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/HUDContextMenuPolicy.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/UsagePopoverTab.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/AppVersion.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/PopoverPresentationPolicy.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/GitWorkspaceModels.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/GitWorkspaceService.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/AppUpdateService.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/HUDUpdateBadgePolicy.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/HUDColorPalette.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/FeedTrackingModels.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/FeedParser.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/ResetPredictionPolicy.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/FeedTrackingStore.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/FeedTrackingService.swift" \
  "$ROOT_DIR/Sources/CodexUsageStatus/FeedAnnouncementPolicy.swift" \
  "$ROOT_DIR/Tests/CodexUsageStatusTests/TestRunner.swift" \
  -o "$BUILD_DIR/CodexUsageStatusTests"

"$BUILD_DIR/CodexUsageStatusTests"

import Foundation
import CoreGraphics
import AppKit

enum HarnessError: Error, CustomStringConvertible {
    case assertion(String)
    case unwrap(String)

    var description: String {
        switch self {
        case .assertion(let message): return message
        case .unwrap(let message): return "Expected value: \(message)"
        }
    }
}

@main
struct CodexUsageStatusTests {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("full snapshot prefers codex bucket", testFullSnapshotPrefersCodexBucket),
            ("empty codex bucket falls back", testEmptyCodexBucketFallsBack),
            ("sparse patch preserves metadata", testSparsePatchPreservesMetadata),
            ("percentages clamp", testPercentagesClamp),
            ("JSONL request framing", testJSONLRequestFraming),
            ("JSONL partial chunks", testJSONLPartialChunks),
            ("history retention and dedupe", testHistoryRetentionAndDedupe),
            ("history round trip", testHistoryRoundTrip),
            ("corrupt history preserves memory", testCorruptHistoryPreservesMemory),
            ("threshold policy boundaries", testThresholdPolicyBoundaries),
            ("HUD warning and decrease policy", testHUDWarningAndDecreasePolicy),
            ("HUD visibility policy", testHUDVisibilityPolicy),
            ("HUD dual quota presentation policy", testHUDQuotaPresentationPolicy),
            ("HUD cross-Space unique Quartz matching", testHUDCrossSpaceUniqueQuartzMatching),
            ("HUD placement and adaptive anchors", testHUDPlacementAndAdaptiveAnchors),
            ("token activity decoding", testTokenActivityDecoding),
            ("token activity null fields", testTokenActivityNullFields),
            ("token activity store replacement and retention", testTokenActivityStoreReplacementAndRetention),
            ("corrupt token activity preserves memory", testCorruptTokenActivityPreservesMemory),
            ("reset credit decoding and sparse preservation", testResetCreditDecoding),
            ("reset credit consume request", testResetCreditConsumeRequest),
            ("account health decoding", testAccountHealthDecoding),
            ("account profile display formatting", testAccountProfileDisplayFormatting),
            ("turn activity event decoding", testTurnActivityDecoding),
            ("account profiles isolate email", testAccountProfilesIsolateEmail),
            ("account read disables refresh token", testAccountReadDisablesRefreshToken),
            ("unknown profile is marked", testUnknownProfileIsMarked),
            ("managed profile has isolated CODEX_HOME", testManagedProfileHasIsolatedCodexHome),
            ("managed profile imports auth atomically", testManagedProfileImportsAuth),
            ("update version comparison", testUpdateVersionComparison),
            ("HUD context menu policy", testHUDContextMenuPolicy),
            ("usage popover tabs and app version", testUsagePopoverTabsAndAppVersion),
            ("popover presentation appearance policy", testPopoverPresentationAppearancePolicy),
            ("HUD scale levels", testHUDScaleLevels),
            ("HUD C metrics", testHUDMetrics),
            ("HUD update badge policy", testHUDUpdateBadgePolicy),
            ("Codex application identity", testCodexApplicationIdentity),
            ("Codex prompt shortcuts", testCodexPromptShortcuts),
            ("temporary clipboard guards", testClipboardTemporaryOperationPolicy),
            ("Git status parser and safety policies", testGitWorkspacePolicies),
            ("Git selected commit isolation", testGitSelectedCommitIsolation),
            ("Git untracked commit and sensitive boundaries", testGitUntrackedCommitAndSensitiveBoundaries),
            ("Git push identity freeze", testGitPushIdentityFreeze)
        ]

        var failures = 0
        for (name, test) in tests {
            do {
                try test()
                print("PASS \(name)")
            } catch {
                failures += 1
                print("FAIL \(name): \(error)")
            }
        }
        print("\(tests.count - failures)/\(tests.count) tests passed")
        if failures > 0 { exit(1) }
    }

    private static func testFullSnapshotPrefersCodexBucket() throws {
        let result: [String: Any] = [
            "rateLimits": [
                "limitId": "legacy",
                "limitName": "Legacy",
                "planType": "pro",
                "primary": ["usedPercent": 40, "resetsAt": 100, "windowDurationMins": 60]
            ],
            "rateLimitsByLimitId": [
                "codex": [
                    "limitId": "codex",
                    "limitName": "Codex",
                    "primary": ["usedPercent": 25, "resetsAt": 200, "windowDurationMins": 15],
                    "secondary": ["usedPercent": 60, "resetsAt": 300, "windowDurationMins": 10080]
                ]
            ]
        ]
        let snapshot = try UsageDataCodec.decodeFullSnapshot(from: result)
        try expect(snapshot.limitId == "codex", "codex bucket should win")
        try expect(snapshot.limitName == "Codex", "codex limit name should win")
        try expect(snapshot.planType == "pro", "legacy plan metadata should be retained")
        try expect(snapshot.primary?.usedPercent == 25, "primary used percent")
        try expect(snapshot.primary?.remainingPercent == 75, "primary remaining percent")
        try expect(snapshot.secondary?.usedPercent == 60, "secondary used percent")
    }

    private static func testEmptyCodexBucketFallsBack() throws {
        let result: [String: Any] = [
            "rateLimits": [
                "limitId": "codex",
                "primary": ["usedPercent": 12]
            ],
            "rateLimitsByLimitId": ["codex": [:]]
        ]
        let snapshot = try UsageDataCodec.decodeFullSnapshot(from: result)
        try expect(snapshot.primary?.usedPercent == 12, "legacy primary should be used")
        try expect(snapshot.primaryRemainingPercent == 88, "fallback remaining percent")
    }

    private static func testSparsePatchPreservesMetadata() throws {
        let full: [String: Any] = [
            "rateLimits": [
                "limitId": "codex",
                "limitName": "Codex",
                "planType": "pro",
                "primary": ["usedPercent": 25, "resetsAt": 100, "windowDurationMins": 15],
                "secondary": ["usedPercent": 40, "resetsAt": 200, "windowDurationMins": 10080],
                "individualLimit": ["limit": "100", "used": "12", "remainingPercent": 88, "resetsAt": 300],
                "spendControlReached": false
            ]
        ]
        let current = try UsageDataCodec.decodeFullSnapshot(from: full)
        let patch = try UsageDataCodec.decodePatch(from: [
            "rateLimits": [
                "limitId": "codex",
                "primary": ["usedPercent": 31],
                "spendControlReached": NSNull()
            ]
        ])
        guard let merged = patch.applying(to: current) else { throw HarnessError.unwrap("merged snapshot") }
        try expect(merged.primary?.usedPercent == 31, "primary update")
        try expect(merged.primary?.resetsAt == 100, "primary reset should persist")
        try expect(merged.primary?.windowDurationMins == 15, "primary duration should persist")
        try expect(merged.secondary?.usedPercent == 40, "secondary should persist")
        try expect(merged.planType == "pro", "plan should persist")
        try expect(merged.individualLimit?.remainingPercent == 88, "spend control should persist")
        try expect(merged.spendControlReached == false, "null sparse boolean should not clear")
    }

    private static func testPercentagesClamp() throws {
        let result: [String: Any] = [
            "rateLimits": [
                "primary": ["usedPercent": 140],
                "secondary": ["usedPercent": -5],
                "individualLimit": ["limit": "10", "used": "11", "remainingPercent": -20, "resetsAt": 1]
            ]
        ]
        let snapshot = try UsageDataCodec.decodeFullSnapshot(from: result)
        try expect(snapshot.primary?.remainingPercent == 0, "primary lower clamp")
        try expect(snapshot.secondary?.remainingPercent == 100, "secondary upper clamp")
        try expect(snapshot.individualLimit?.remainingPercent == 0, "spend control lower clamp")
    }

    private static func testJSONLRequestFraming() throws {
        let request = try JSONRPCCodec.encodeRequest(id: 7, method: "account/rateLimits/read", params: nil)
        guard request.last == 0x0A else { throw HarnessError.assertion("request must end in LF") }
        let object = try JSONSerialization.jsonObject(with: request.dropLast()) as? [String: Any]
        try expect(object?["id"] as? Int == 7, "request id")
        try expect(object?["method"] as? String == "account/rateLimits/read", "request method")
        try expect(object?["jsonrpc"] == nil, "wire should omit jsonrpc")
    }

    private static func testJSONLPartialChunks() throws {
        let buffer = JSONLineBuffer()
        try expect(buffer.append(Data("{\"id\":1".utf8)).isEmpty, "partial line should wait")
        let lines = buffer.append(Data("}\n{\"id\":2}\n".utf8))
        try expect(lines.count == 2, "two complete lines")
        let first = try JSONRPCCodec.decodeLine(lines[0])
        let second = try JSONRPCCodec.decodeLine(lines[1])
        try expect(first.id == 1, "first id")
        try expect(second.id == 2, "second id")
    }

    private static func testHistoryRetentionAndDedupe() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = HistoryStore(applicationSupportURL: base)
        let snapshot = UsageSnapshot(
            limitId: "codex",
            limitName: "Codex",
            planType: "pro",
            primary: RateLimitWindow(usedPercent: 20, resetsAt: 100, windowDurationMins: 15),
            secondary: nil,
            individualLimit: nil,
            rateLimitReachedType: nil,
            spendControlReached: nil,
            receivedAt: Date()
        )
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try expect(store.record(snapshot: snapshot, connectionState: .connected, now: now), "first sample")
        try expect(!store.record(snapshot: snapshot, connectionState: .connected, now: now.addingTimeInterval(60)), "same sample should dedupe")
        try expect(store.record(snapshot: snapshot, connectionState: .connected, now: now.addingTimeInterval(301)), "five-minute sample")
        var resetChanged = snapshot
        resetChanged.primary = RateLimitWindow(usedPercent: 20, resetsAt: 101, windowDurationMins: 15)
        try expect(store.record(snapshot: resetChanged, connectionState: .connected, now: now.addingTimeInterval(302)), "reset metadata change should record")
        try expect(store.samples.count == 3, "dedupe count")

        let old = UsageSnapshot(
            limitId: "codex",
            limitName: "Codex",
            planType: "pro",
            primary: RateLimitWindow(usedPercent: 25, resetsAt: 90, windowDurationMins: 15),
            secondary: nil,
            individualLimit: nil,
            rateLimitReachedType: nil,
            spendControlReached: nil,
            receivedAt: now
        )
        let oldTime = now.addingTimeInterval(-31 * 24 * 60 * 60)
        let purgeStore = HistoryStore(applicationSupportURL: base.appendingPathComponent("purge"))
        try expect(purgeStore.record(snapshot: old, connectionState: .connected, now: oldTime), "old sample")
        try expect(purgeStore.record(snapshot: snapshot, connectionState: .connected, now: now), "current sample")
        try expect(purgeStore.samples.count == 1, "samples older than 30 days should purge")
    }

    private static func testHistoryRoundTrip() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-history-roundtrip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = HistoryStore(applicationSupportURL: base)
        let snapshot = UsageSnapshot(
            limitId: "codex",
            limitName: "Codex",
            planType: "team",
            primary: RateLimitWindow(usedPercent: 12, resetsAt: 200, windowDurationMins: 60),
            secondary: RateLimitWindow(usedPercent: 40, resetsAt: 300, windowDurationMins: 10080),
            individualLimit: nil,
            rateLimitReachedType: nil,
            spendControlReached: nil,
            receivedAt: Date()
        )
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        _ = store.record(snapshot: snapshot, connectionState: .connected, now: now)
        let reloaded = HistoryStore(applicationSupportURL: base)
        try expect(reloaded.samples.count == 1, "round-trip sample count")
        try expect(reloaded.samples[0].primaryUsedPercent == 12, "round-trip primary")
        try expect(reloaded.samples[0].secondaryResetsAt == 300, "round-trip reset")
    }

    private static func testCorruptHistoryPreservesMemory() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-history-corrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = HistoryStore(applicationSupportURL: base)
        let snapshot = UsageSnapshot(
            limitId: "codex", limitName: nil, planType: nil,
            primary: RateLimitWindow(usedPercent: 1, resetsAt: nil, windowDurationMins: nil),
            secondary: nil, individualLimit: nil, rateLimitReachedType: nil,
            spendControlReached: nil, receivedAt: Date()
        )
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        _ = store.record(snapshot: snapshot, connectionState: .connected, now: now)
        try Data("not-json".utf8).write(to: store.fileURL)
        store.load(now: now)
        try expect(store.samples.count == 1, "corrupt file must not clear in-memory data")
        try expect(store.errorMessage != nil, "corrupt file should expose an error")
    }

    private static func testThresholdPolicyBoundaries() throws {
        let first = UsageThresholdPolicy.pendingThresholds(
            remainingPercent: 20,
            thresholds: [20, 10],
            sentThresholds: []
        )
        try expect(first == [20], "exact 20% should notify")
        let crossed = UsageThresholdPolicy.pendingThresholds(
            remainingPercent: 8,
            thresholds: [20, 10],
            sentThresholds: []
        )
        try expect(crossed == [10, 20], "a large drop should report both thresholds")
        let rearmed = UsageThresholdPolicy.pendingThresholds(
            remainingPercent: 8,
            thresholds: [20, 10],
            sentThresholds: [20]
        )
        try expect(rearmed == [10], "sent threshold should dedupe")
    }

    private static func testHUDWarningAndDecreasePolicy() throws {
        try expect(
            HUDWarningPolicy.level(remainingPercent: 50, connectionState: .connected, isStale: false) == .normal,
            "50% should be normal"
        )
        try expect(
            HUDWarningPolicy.level(remainingPercent: 20, connectionState: .connected, isStale: false) == .warning,
            "20% should be warning"
        )
        try expect(
            HUDWarningPolicy.level(remainingPercent: 19, connectionState: .connected, isStale: false) == .critical,
            "19% should be critical"
        )
        let fullProfile = HUDWarningPolicy.framePulseProfile(remainingPercent: 100, connectionState: .connected, isStale: false)
        let normalProfile = HUDWarningPolicy.framePulseProfile(remainingPercent: 50, connectionState: .connected, isStale: false)
        let warningProfile = HUDWarningPolicy.framePulseProfile(remainingPercent: 49, connectionState: .connected, isStale: false)
        let criticalProfile = HUDWarningPolicy.framePulseProfile(remainingPercent: 19, connectionState: .connected, isStale: false)
        let severeProfile = HUDWarningPolicy.framePulseProfile(remainingPercent: 9, connectionState: .connected, isStale: false)
        try expect(fullProfile != nil, "100% should have a live pulse")
        try expect(normalProfile?.period == 2.3, "50% should use the light pulse")
        try expect(warningProfile?.period == 1.8, "49% should use the warning pulse")
        try expect(criticalProfile?.period == 1.45, "19% should use the critical pulse")
        try expect(severeProfile?.period == 1.1, "9% should use the strongest pulse")
        try expect(fullProfile?.minOpacity == 0.28 && fullProfile?.maxOpacity == 0.74, "100% should use the faintest frame glow")
        try expect(severeProfile?.minOpacity == 0.58 && severeProfile?.maxOpacity == 1.0, "9% should use the strongest frame glow")
        try expect((severeProfile?.period ?? 0) < (fullProfile?.period ?? 0), "lower quota should pulse faster")
        try expect(
            HUDWarningPolicy.shouldPulse(remainingPercent: 11, connectionState: .connected, isStale: false),
            "11% should pulse in the all-range design"
        )
        try expect(
            !HUDWarningPolicy.shouldPulse(remainingPercent: nil, connectionState: .connected, isStale: false),
            "missing data should not pulse"
        )
        try expect(
            !HUDWarningPolicy.shouldPulse(remainingPercent: 11, connectionState: .offline, isStale: false),
            "offline data should not pulse"
        )
        try expect(
            !HUDWarningPolicy.shouldPulse(remainingPercent: 11, connectionState: .connected, isStale: true),
            "stale data should not pulse"
        )
        try expect(
            HUDWarningPolicy.framePulseProfile(remainingPercent: 11, connectionState: .connecting, isStale: false) == nil,
            "connecting data should not pulse"
        )
        try expect(
            HUDWarningPolicy.decreaseAmount(
                previous: 12,
                current: 11,
                connectionState: .connected,
                isStale: false,
                sameProfile: true
            ) == 1,
            "12 to 11 should produce -1%"
        )
        try expect(
            HUDWarningPolicy.decreaseAmount(
                previous: 12,
                current: 9,
                connectionState: .connected,
                isStale: false,
                sameProfile: true
            ) == 3,
            "12 to 9 should produce -3%"
        )
        try expect(
            HUDWarningPolicy.decreaseAmount(
                previous: 11,
                current: 12,
                connectionState: .connected,
                isStale: false,
                sameProfile: true
            ) == nil,
            "an increase should not produce a decrease"
        )
        try expect(
            HUDWarningPolicy.decreaseAmount(
                previous: 12,
                current: 11,
                connectionState: .offline,
                isStale: false,
                sameProfile: true
            ) == nil,
            "offline data should not animate"
        )
        try expect(
            HUDWarningPolicy.decreaseAmount(
                previous: 12,
                current: 11,
                connectionState: .connected,
                isStale: true,
                sameProfile: true
            ) == nil,
            "stale data should not animate"
        )
        try expect(
            HUDWarningPolicy.decreaseAmount(
                previous: 12,
                current: 11,
                connectionState: .connected,
                isStale: false,
                sameProfile: false
            ) == nil,
            "a profile switch should reset the baseline"
        )
    }

    private static func testHUDVisibilityPolicy() throws {
        let profileA = UUID()
        let profileB = UUID()
        let fiveHour = HUDQuotaWindowPresentation(
            kind: .fiveHour,
            durationMins: 300,
            label: "5 小時",
            remainingPercent: 12,
            resetsAt: 1_240,
            resetDescription: "4小時"
        )
        let sevenDay = HUDQuotaWindowPresentation(
            kind: .sevenDay,
            durationMins: 10_080,
            label: "7 天",
            remainingPercent: 62,
            resetsAt: 2_000,
            resetDescription: "1天"
        )
        let cachedA = HUDDualQuotaPresentation(
            profileID: profileA,
            fiveHour: fiveHour,
            sevenDay: sevenDay
        )

        try expect(
            HUDVisibilityPolicy.visibilityDecision(
                enabled: false,
                focus: .codex,
                panelIsVisible: true,
                position: .positioned
            ) == .hideImmediately,
            "explicit HUD disable should hide immediately"
        )
        try expect(
            HUDVisibilityPolicy.visibilityDecision(
                enabled: true,
                focus: .codex,
                panelIsVisible: false,
                position: .positioned
            ) == .show,
            "Codex plus valid quota and position should show"
        )
        try expect(
            HUDVisibilityPolicy.visibilityDecision(
                enabled: true,
                focus: .codex,
                panelIsVisible: true,
                position: .unavailable
            ) == .hideImmediately,
            "an unavailable position must hide even when the panel is visible"
        )
        try expect(
            HUDVisibilityPolicy.positionResult(hasValidFrame: true, hasRetainableSafeFrame: false) == .positioned,
            "a valid frame should permit the first show"
        )
        try expect(
            HUDVisibilityPolicy.positionResult(hasValidFrame: false, hasRetainableSafeFrame: true) == .retainedExistingPosition,
            "an authenticated safe frame should retain position during a frame gap"
        )
        try expect(
            HUDVisibilityPolicy.positionResult(hasValidFrame: false, hasRetainableSafeFrame: false) == .unavailable,
            "a frame gap without a safe frame must remain unavailable"
        )

        try expect(
            HUDVisibilityPolicy.focusDecision(
                focus: .unknown,
                panelIsVisible: true,
                elapsedFocusLoss: 10,
                grace: 0.5
            ) == .hideImmediately,
            "unknown focus must fail closed and hide a visible panel"
        )
        try expect(
            HUDVisibilityPolicy.focusDecision(
                focus: .otherApplication,
                panelIsVisible: true,
                elapsedFocusLoss: 0.49,
                grace: 0.5
            ) == .pendingHide,
            "focus loss before the grace period should remain pending"
        )
        try expect(
            HUDVisibilityPolicy.focusDecision(
                focus: .otherApplication,
                panelIsVisible: true,
                elapsedFocusLoss: 0.5,
                grace: 0.5
            ) == .hideImmediately,
            "confirmed focus loss should hide after the grace period"
        )
        try expect(
            HUDVisibilityPolicy.focusDecision(
                focus: .codex,
                panelIsVisible: true,
                elapsedFocusLoss: 1,
                grace: 0.5
            ) == .retainPanel,
            "Codex restoration should retain the visible panel"
        )

        try expect(
            HUDVisibilityPolicy.cachedPresentation(currentProfileID: profileA, cached: cachedA) == cachedA,
            "same profile may reuse its cached presentation"
        )
        try expect(
            HUDVisibilityPolicy.cachedPresentation(currentProfileID: profileB, cached: cachedA) == nil,
            "a profile switch must not reuse another profile's quota"
        )
        try expect(
            HUDVisibilityPolicy.cachedPresentation(currentProfileID: nil, cached: cachedA) == nil,
            "an unknown profile identity must not reuse cached quota"
        )
        let sparseLive = HUDDualQuotaPresentation(
            profileID: profileA,
            fiveHour: nil,
            sevenDay: HUDQuotaWindowPresentation(
                kind: .sevenDay,
                durationMins: 10_080,
                label: "7 天",
                remainingPercent: 98,
                resetsAt: 3_000,
                resetDescription: "2天"
            )
        )
        let mergedSparse = HUDVisibilityPolicy.mergedPresentation(
            currentProfileID: profileA,
            live: sparseLive,
            cached: cachedA
        )
        try expect(
            mergedSparse?.fiveHour == cachedA.fiveHour,
            "a sparse live response must retain the cached 5-hour window"
        )
        try expect(
            mergedSparse?.sevenDay == sparseLive.sevenDay,
            "a sparse live response must replace the cached 7-day window"
        )
        try expect(
            HUDVisibilityPolicy.mergedPresentation(
                currentProfileID: profileB,
                live: sparseLive,
                cached: cachedA
            ) == nil,
            "a profile mismatch must reject both live and cached quota"
        )
        let timestamp = Date(timeIntervalSince1970: 1_000)
        try expect(
            HUDVisibilityPolicy.presentationSnapshot(
                currentProfileID: profileA,
                trackedProfileID: profileA,
                lastUpdated: timestamp,
                presentation: cachedA
            ) == cachedA,
            "a valid snapshot may be cached for the tracked profile"
        )
        try expect(
            HUDVisibilityPolicy.presentationSnapshot(
                currentProfileID: profileB,
                trackedProfileID: profileA,
                lastUpdated: timestamp,
                presentation: cachedA
            ) == nil,
            "a profile switch must reject a snapshot tracked for the previous profile"
        )
        try expect(
            HUDVisibilityPolicy.presentationSnapshot(
                currentProfileID: profileB,
                trackedProfileID: profileB,
                lastUpdated: nil,
                presentation: cachedA
            ) == nil,
            "a new profile without its own update must remain uncached"
        )
        let cachedB = HUDDualQuotaPresentation(
            profileID: profileB,
            fiveHour: fiveHour,
            sevenDay: sevenDay
        )
        try expect(
            HUDVisibilityPolicy.presentationSnapshot(
                currentProfileID: profileB,
                trackedProfileID: profileB,
                lastUpdated: timestamp,
                presentation: cachedB
            ) == cachedB,
            "the new profile may cache its own valid dual snapshot even at the same percentage"
        )
        try expect(
            HUDVisibilityPolicy.shouldApplyFocusLoss(scheduledGeneration: 4, currentGeneration: 4),
            "a current focus-loss generation may apply"
        )
        try expect(
            !HUDVisibilityPolicy.shouldApplyFocusLoss(scheduledGeneration: 4, currentGeneration: 5),
            "an invalidated focus-loss generation must not apply"
        )
    }

    private static func testHUDQuotaPresentationPolicy() throws {
        let profileID = UUID()
        let now = Date(timeIntervalSince1970: 10_000)
        let fiveReset = Int64(now.timeIntervalSince1970) + 4 * 3_600 + 45 * 60
        let sevenReset = Int64(now.timeIntervalSince1970) + 2 * 86_400 + 14 * 3_600
        let primary = RateLimitWindow(usedPercent: 4, resetsAt: fiveReset, windowDurationMins: 300)
        let secondary = RateLimitWindow(usedPercent: 38, resetsAt: sevenReset, windowDurationMins: 10_080)
        let snapshot = UsageSnapshot(
            limitId: "codex",
            limitName: "Codex",
            planType: "pro",
            primary: primary,
            secondary: secondary,
            individualLimit: nil,
            rateLimitReachedType: nil,
            spendControlReached: nil,
            receivedAt: now
        )

        guard let presentation = HUDQuotaPresentationPolicy.make(snapshot: snapshot, profileID: profileID, now: now) else {
            throw HarnessError.unwrap("dual quota presentation")
        }
        try expect(presentation.fiveHour?.remainingPercent == 96, "5-hour remaining percent")
        try expect(presentation.sevenDay?.remainingPercent == 62, "7-day remaining percent")
        try expect(presentation.fiveHour?.label == "5 小時", "5-hour label")
        try expect(presentation.sevenDay?.label == "7 天", "7-day label")
        try expect(presentation.fiveHour?.resetDescription == "4小時45分", "5-hour countdown")
        try expect(presentation.sevenDay?.resetDescription == "2天14小時", "7-day countdown")
        try expect(presentation.fiveHour?.fillFraction == 0.96, "5-hour fill fraction")
        try expect(presentation.sevenDay?.fillFraction == 0.62, "7-day fill fraction")
        try expect(presentation.rowCount == 2, "two published windows produce two HUD rows")
        try expect(
            HUDQuotaWindowPresentation(
                kind: .fiveHour,
                durationMins: 300,
                label: "5 小時",
                remainingPercent: 100,
                resetsAt: nil,
                resetDescription: "更新中"
            ).fillFraction == 1,
            "full remaining quota fills the entire compact row"
        )
        try expect(
            HUDQuotaWindowPresentation(
                kind: .fiveHour,
                durationMins: 300,
                label: "5 小時",
                remainingPercent: 0,
                resetsAt: nil,
                resetDescription: "更新中"
            ).fillFraction == 0,
            "depleted quota leaves no fill"
        )
        try expect(
            HUDQuotaWindowPresentation(
                kind: .fiveHour,
                durationMins: 300,
                label: "5 小時",
                remainingPercent: 1,
                resetsAt: nil,
                resetDescription: "更新中"
            ).fillFraction == 0.01,
            "one-percent quota uses one-percent row fill"
        )

        let reversed = UsageSnapshot(
            limitId: "codex",
            limitName: nil,
            planType: nil,
            primary: secondary,
            secondary: primary,
            individualLimit: nil,
            rateLimitReachedType: nil,
            spendControlReached: nil,
            receivedAt: now
        )
        let reversedPresentation = HUDQuotaPresentationPolicy.make(snapshot: reversed, profileID: profileID, now: now)
        try expect(reversedPresentation?.fiveHour == presentation.fiveHour, "window order must not change 5-hour row")
        try expect(reversedPresentation?.sevenDay == presentation.sevenDay, "window order must not change 7-day row")

        let onlyFive = UsageSnapshot(
            limitId: nil, limitName: nil, planType: nil,
            primary: primary, secondary: nil, individualLimit: nil,
            rateLimitReachedType: nil, spendControlReached: nil, receivedAt: now
        )
        let onlyFivePresentation = HUDQuotaPresentationPolicy.make(snapshot: onlyFive, profileID: profileID, now: now)
        try expect(onlyFivePresentation?.fiveHour != nil, "available 5-hour row remains present")
        try expect(onlyFivePresentation?.sevenDay == nil, "missing 7-day row is unavailable")
        try expect(onlyFivePresentation?.rows.count == 1, "a Free-style single window has no placeholder row")

        let onlySeven = UsageSnapshot(
            limitId: nil, limitName: nil, planType: nil,
            primary: RateLimitWindow(usedPercent: 2, resetsAt: sevenReset, windowDurationMins: 10_080),
            secondary: nil, individualLimit: nil,
            rateLimitReachedType: nil, spendControlReached: nil, receivedAt: now
        )
        let onlySevenPresentation = HUDQuotaPresentationPolicy.make(snapshot: onlySeven, profileID: profileID, now: now)
        try expect(onlySevenPresentation?.fiveHour == nil, "a 7-day window must never populate the 5-hour row")
        try expect(onlySevenPresentation?.sevenDay?.remainingPercent == 98, "available 7-day row remains present")

        let withSpendControl = UsageSnapshot(
            limitId: nil, limitName: nil, planType: "pro",
            primary: primary, secondary: secondary,
            individualLimit: SpendControlLimit(
                limit: "100", used: "20", remainingPercent: 80,
                resetsAt: Int64(now.timeIntervalSince1970) + 3 * 86_400 + 4 * 3_600
            ),
            rateLimitReachedType: nil, spendControlReached: nil, receivedAt: now
        )
        let threeRows = HUDQuotaPresentationPolicy.make(snapshot: withSpendControl, profileID: profileID, now: now)
        try expect(threeRows?.rows.count == 3, "a plan with spend control exposes three HUD rows")
        try expect(threeRows?.rows.last?.kind == .gptReserveWeekly, "spend control uses GPT reserve Weekly row")
        try expect(threeRows?.gptReserveWeekly?.remainingPercent == 80, "spend control percentage is preserved")

        let unknown = RateLimitWindow(usedPercent: 50, resetsAt: fiveReset, windowDurationMins: 60)
        let unknownSnapshot = UsageSnapshot(
            limitId: nil, limitName: nil, planType: nil,
            primary: unknown, secondary: nil, individualLimit: nil,
            rateLimitReachedType: nil, spendControlReached: nil, receivedAt: now
        )
        let unknownPresentation = HUDQuotaPresentationPolicy.make(snapshot: unknownSnapshot, profileID: profileID, now: now)
        try expect(
            unknownPresentation == nil || unknownPresentation?.hasRecognizedWindow == false,
            "unknown duration must not be rendered as a quota row"
        )

        let duplicate = UsageSnapshot(
            limitId: nil, limitName: nil, planType: nil,
            primary: primary,
            secondary: RateLimitWindow(usedPercent: 10, resetsAt: sevenReset, windowDurationMins: 300),
            individualLimit: nil, rateLimitReachedType: nil, spendControlReached: nil, receivedAt: now
        )
        try expect(
            HUDQuotaPresentationPolicy.make(snapshot: duplicate, profileID: profileID, now: now)?.fiveHour == nil,
            "duplicate 5-hour durations must fail closed"
        )

        let missingReset = RateLimitWindow(usedPercent: 100, resetsAt: nil, windowDurationMins: 300)
        let missingResetSnapshot = UsageSnapshot(
            limitId: nil, limitName: nil, planType: nil,
            primary: missingReset, secondary: nil, individualLimit: nil,
            rateLimitReachedType: nil, spendControlReached: nil, receivedAt: now
        )
        try expect(
            HUDQuotaPresentationPolicy.make(snapshot: missingResetSnapshot, profileID: profileID, now: now)?.fiveHour?.resetDescription == "更新中",
            "missing reset timestamp must render updating state"
        )
        let past = RateLimitWindow(usedPercent: 99, resetsAt: Int64(now.timeIntervalSince1970) - 1, windowDurationMins: 300)
        try expect(
            HUDQuotaPresentationPolicy.make(
                snapshot: UsageSnapshot(limitId: nil, limitName: nil, planType: nil, primary: past, secondary: nil, individualLimit: nil, rateLimitReachedType: nil, spendControlReached: nil, receivedAt: now),
                profileID: profileID,
                now: now
            )?.fiveHour?.resetDescription == "已重置",
            "past reset timestamp must render reset state"
        )
        try expect(
            HUDQuotaPresentationPolicy.make(snapshot: snapshot, profileID: nil, now: now) == nil,
            "unknown profile must not produce a presentation"
        )
    }

    private static func testHUDCrossSpaceUniqueQuartzMatching() throws {
        // Negative global coordinates represent a valid display to the left of
        // the primary display and must not be rejected as an off-Space window.
        let focused = CGRect(x: -1_600, y: 140, width: 1_200, height: 800)
        let exact = focused
        let unrelatedPrimaryDisplay = CGRect(x: 100, y: 140, width: 1_200, height: 800)
        try expect(
            HUDVisibilityPolicy.uniqueQuartzWindowMatch(
                focusedBounds: focused,
                candidates: [unrelatedPrimaryDisplay, exact]
            ) == exact,
            "a uniquely matching negative-origin candidate should be accepted"
        )

        let boundary = CGRect(x: focused.minX + 24, y: focused.minY, width: focused.width, height: focused.height)
        try expect(
            HUDVisibilityPolicy.uniqueQuartzWindowMatch(
                focusedBounds: focused,
                candidates: [boundary]
            ) == boundary,
            "the existing inclusive 24-point tolerance should be preserved"
        )
        try expect(
            HUDVisibilityPolicy.uniqueQuartzWindowMatch(
                focusedBounds: focused,
                candidates: [CGRect(x: focused.minX + 24.01, y: focused.minY, width: focused.width, height: focused.height)]
            ) == nil,
            "a candidate outside the 24-point tolerance must be rejected"
        )

        let closeCollision = CGRect(x: focused.minX + 12, y: focused.minY + 12, width: focused.width + 12, height: focused.height + 12)
        try expect(
            HUDVisibilityPolicy.uniqueQuartzWindowMatch(
                focusedBounds: focused,
                candidates: [exact, closeCollision]
            ) == nil,
            "multiple close candidates must fail closed instead of choosing one"
        )
        try expect(
            HUDVisibilityPolicy.uniqueQuartzWindowMatch(
                focusedBounds: focused,
                candidates: []
            ) == nil,
            "no candidate must remain unavailable for a hidden first show"
        )

        // Current Codex builds can expose a synthetic full-screen AX window
        // while Quartz exposes the actual single content window. The PID,
        // layer, and size filters already make this candidate unambiguous.
        let syntheticAXFrame = CGRect(x: 0, y: 0, width: 2_048, height: 1_280)
        let actualSingleWindow = CGRect(x: 218, y: 30, width: 1_612, height: 1_250)
        try expect(
            HUDVisibilityPolicy.uniqueQuartzWindowMatch(
                focusedBounds: syntheticAXFrame,
                candidates: [actualSingleWindow]
            ) == actualSingleWindow,
            "a single filtered Quartz window should bridge synthetic full-screen AX geometry"
        )
        try expect(
            HUDVisibilityPolicy.uniqueQuartzWindowMatch(
                focusedBounds: syntheticAXFrame,
                candidates: [actualSingleWindow, CGRect(x: 500, y: 100, width: 900, height: 700)]
            ) == nil,
            "synthetic AX geometry must not choose among multiple Quartz windows"
        )
        try expect(
            HUDVisibilityPolicy.uniqueQuartzWindowMatch(
                focusedBounds: nil,
                candidates: [actualSingleWindow]
            ) == actualSingleWindow,
            "a single filtered Quartz window should remain usable when Accessibility is unavailable"
        )
        try expect(
            HUDVisibilityPolicy.uniqueQuartzWindowMatch(
                focusedBounds: nil,
                candidates: [actualSingleWindow, CGRect(x: 500, y: 100, width: 900, height: 700)]
            ) == nil,
            "Accessibility fallback must remain unavailable when multiple Quartz windows exist"
        )
    }

    private static func testHUDPlacementAndAdaptiveAnchors() throws {
        let target = CGRect(x: 100, y: 100, width: 800, height: 600)
        let bottomHUD = CGRect(x: 580, y: 140, width: 300, height: 52)
        let topHUD = CGRect(x: 580, y: 620, width: 300, height: 52)

        try expect(
            HUDPlacementPolicy.placement(targetFrame: target, hudFrame: bottomHUD, previous: nil) == .bottomRight,
            "HUD below the center line should use the bottom placement"
        )
        try expect(
            HUDPlacementPolicy.placement(targetFrame: target, hudFrame: topHUD, previous: nil) == .topRight,
            "HUD above the center line should use the top placement"
        )

        let farHUD = CGRect(x: 400, y: 140, width: 300, height: 52)
        try expect(
            HUDPlacementPolicy.placement(targetFrame: target, hudFrame: farHUD, previous: .topRight) == .bottomRight,
            "HUD more than 80 points from the right edge should use the conservative placement"
        )

        let centerBandHUD = CGRect(x: 580, y: 382, width: 300, height: 52)
        try expect(
            HUDPlacementPolicy.placement(targetFrame: target, hudFrame: centerBandHUD, previous: .topRight) == .topRight,
            "the center hysteresis band should retain the top placement"
        )
        try expect(
            HUDPlacementPolicy.placement(targetFrame: target, hudFrame: centerBandHUD, previous: .bottomRight) == .bottomRight,
            "the center hysteresis band should retain the bottom placement"
        )

        let bottomNewOrigin = HUDPlacementPolicy.resizedOrigin(
            origin: bottomHUD.origin,
            targetFrame: target,
            oldPanelSize: bottomHUD.size,
            newPanelSize: CGSize(width: 300, height: 46),
            placement: .bottomRight
        )
        try expect(bottomNewOrigin.x == bottomHUD.origin.x, "bottom resize should preserve the right inset")
        try expect(bottomNewOrigin.y == bottomHUD.origin.y, "bottom resize should preserve the bottom inset")

        let topNewOrigin = HUDPlacementPolicy.resizedOrigin(
            origin: topHUD.origin,
            targetFrame: target,
            oldPanelSize: topHUD.size,
            newPanelSize: CGSize(width: 300, height: 46),
            placement: .topRight
        )
        try expect(topNewOrigin.x == topHUD.origin.x, "top resize should preserve the right inset")
        try expect(topNewOrigin.y == 626, "top resize should preserve the top inset")

        let topAnchor = HUDPlacementPolicy.anchor(
            origin: topHUD.origin,
            targetFrame: target,
            panelSize: topHUD.size,
            placement: .topRight
        )
        let restoredTopOrigin = HUDPlacementPolicy.origin(
            for: topAnchor,
            targetFrame: target,
            panelSize: CGSize(width: 300, height: 46)
        )
        try expect(restoredTopOrigin == topNewOrigin, "top anchor should round trip through a resize")
    }

    private static func testTokenActivityDecoding() throws {
        let result: [String: Any] = [
            "summary": [
                "lifetimeTokens": 123_456,
                "peakDailyTokens": 12_345,
                "longestRunningTurnSec": 93,
                "currentStreakDays": 4,
                "longestStreakDays": 9
            ],
            "dailyUsageBuckets": [
                ["startDate": "2026-08-15", "tokens": 100],
                ["startDate": "2026-08-16", "tokens": 200]
            ]
        ]
        let snapshot = try TokenActivityCodec.decode(from: result)
        try expect(snapshot.lifetimeTokens == 123_456, "lifetime token summary")
        try expect(snapshot.dailyUsageBuckets?.count == 2, "daily bucket count")
    }

    private static func testTokenActivityNullFields() throws {
        let snapshot = try TokenActivityCodec.decode(from: [
            "summary": NSNull(),
            "dailyUsageBuckets": NSNull(),
            "unknownField": "ignored"
        ])
        try expect(snapshot.lifetimeTokens == nil, "null summary should remain unknown")
        try expect(snapshot.dailyUsageBuckets == nil, "null buckets should remain unknown")
    }

    private static func testTokenActivityStoreReplacementAndRetention() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("codex-token-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = TokenActivityStore(applicationSupportURL: base)
        let formatter = ISO8601DateFormatter()
        let now = formatter.date(from: "2026-08-16T12:00:00Z")!
        _ = store.update(incoming: TokenActivitySnapshot(
            fetchedAt: now,
            lifetimeTokens: 100,
            peakDailyTokens: 50,
            longestRunningTurnSec: nil,
            currentStreakDays: 1,
            longestStreakDays: 2,
            dailyUsageBuckets: [
                DailyTokenUsage(startDate: "2026-07-10", tokens: 1),
                DailyTokenUsage(startDate: "2026-08-15", tokens: 10),
                DailyTokenUsage(startDate: "2026-08-15", tokens: 20)
            ]
        ), now: now)
        _ = store.update(incoming: TokenActivitySnapshot(
            fetchedAt: now.addingTimeInterval(60),
            lifetimeTokens: nil,
            peakDailyTokens: nil,
            longestRunningTurnSec: 30,
            currentStreakDays: nil,
            longestStreakDays: nil,
            dailyUsageBuckets: [DailyTokenUsage(startDate: "2026-08-15", tokens: 99)]
        ), now: now)
        try expect(store.snapshot?.lifetimeTokens == 100, "null summary preserves previous value")
        try expect(store.snapshot?.dailyUsageBuckets?.count == 1, "same date bucket replaces")
        try expect(store.snapshot?.dailyUsageBuckets?.first?.tokens == 99, "latest bucket wins")
    }

    private static func testCorruptTokenActivityPreservesMemory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("codex-token-corrupt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = TokenActivityStore(applicationSupportURL: base)
        let now = Date()
        _ = store.update(incoming: TokenActivitySnapshot(
            fetchedAt: now, lifetimeTokens: 5, peakDailyTokens: nil,
            longestRunningTurnSec: nil, currentStreakDays: nil, longestStreakDays: nil,
            dailyUsageBuckets: nil
        ), now: now)
        try Data("not-json".utf8).write(to: store.fileURL)
        store.load(now: now)
        try expect(store.snapshot?.lifetimeTokens == 5, "corrupt token file preserves memory")
        try expect(store.errorMessage != nil, "corrupt token file reports error")
    }

    private static func testResetCreditDecoding() throws {
        let snapshot = try UsageDataCodec.decodeFullSnapshot(from: [
            "rateLimits": ["limitId": "codex", "primary": ["usedPercent": 10]],
            "rateLimitResetCredits": [
                "availableCount": 2,
                "credits": [[
                    "id": "credit-1", "resetType": "primary", "status": "available",
                    "grantedAt": 100, "expiresAt": 200, "title": "Earned", "description": "Test"
                ]]
            ]
        ])
        try expect(snapshot.rateLimitResetCredits?.availableCount == 2, "available count is authoritative")
        try expect(snapshot.rateLimitResetCredits?.availableCredits.first?.id == "credit-1", "credit id decoded")
        let patch = try UsageDataCodec.decodePatch(from: ["rateLimits": ["primary": ["usedPercent": 20]]])
        let merged = patch.applying(to: snapshot)
        try expect(merged?.rateLimitResetCredits == snapshot.rateLimitResetCredits, "sparse patch preserves credits")
        let countOnly = try UsageDataCodec.decodeFullSnapshot(from: [
            "rateLimits": [:], "rateLimitResetCredits": ["availableCount": 1, "credits": NSNull()]
        ])
        try expect(countOnly.rateLimitResetCredits?.credits == nil, "null credits remains unknown")
    }

    private static func testResetCreditConsumeRequest() throws {
        let key = UUID().uuidString
        let request = try JSONRPCCodec.encodeRequest(
            id: 42,
            method: "account/rateLimitResetCredit/consume",
            params: ["idempotencyKey": key, "creditId": "credit-1"]
        )
        let object = try JSONSerialization.jsonObject(with: request.dropLast()) as? [String: Any]
        let params = object?["params"] as? [String: Any]
        try expect(object?["method"] as? String == "account/rateLimitResetCredit/consume", "consume method")
        try expect((params?["idempotencyKey"] as? String)?.isEmpty == false, "idempotency key")
        try expect(params?["creditId"] as? String == "credit-1", "selected credit id")
    }

    private static func testAccountHealthDecoding() throws {
        let health = try AccountDataCodec.decode(from: [
            "requiresOpenaiAuth": true,
            "account": ["type": "chatgpt", "email": "person@example.com", "planType": "team"]
        ])
        try expect(health.identity.accountType == "chatgpt", "account type")
        try expect(health.identity.email == "person@example.com", "account email")
        try expect(health.identity.requiresOpenAIAuth, "auth requirement")
        try expect(AccountDataCodec.merge(health, params: ["authMode": "chatgptManaged"])?.identity.authMode == "chatgptManaged", "sparse auth mode merge")
    }

    private static func testTurnActivityDecoding() throws {
        let event = TurnActivityCodec.decodeEvent(method: "turn/started", params: [
            "threadId": "thread-1",
            "turn": [
                "id": "turn-1",
                "status": "inProgress",
                "startedAt": 1_700_000_000,
                "items": [["type": "userMessage", "id": "item-1", "content": [["text": "hello"]]]]
            ]
        ])
        try expect(event?.state == .active, "turn started state")
        try expect(event?.content == "hello", "turn content")
        let usage = TurnActivityCodec.decodeTokenUsage(params: [
            "threadId": "thread-1", "turnId": "turn-1",
            "tokenUsage": ["total": ["totalTokens": 1234]]
        ])
        try expect(usage?.tokenTotal == 1234, "turn token usage")
    }

    private static func testAccountProfilesIsolateEmail() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("codex-profiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = AccountProfileStore(applicationSupportURL: base)
        let a = store.select(identity: AccountIdentity(accountType: "chatgpt", authMode: "managed", planType: "pro", email: "a@example.com", requiresOpenAIAuth: true))
        let aAgain = store.select(identity: AccountIdentity(accountType: "chatgpt", authMode: "managed", planType: "team", email: "a@example.com", requiresOpenAIAuth: true))
        let b = store.select(identity: AccountIdentity(accountType: "chatgpt", authMode: "managed", planType: "pro", email: "b@example.com", requiresOpenAIAuth: true))
        try expect(a.profile.id == aAgain.profile.id, "same email returns same profile")
        try expect(a.profile.id != b.profile.id, "different email gets different profile")
        let data = try Data(contentsOf: store.indexURL)
        let text = String(data: data, encoding: .utf8) ?? ""
        try expect(!text.contains("a@example.com") && !text.contains("b@example.com"), "raw email is not persisted")
    }

    private static func testAccountReadDisablesRefreshToken() throws {
        let request = try JSONRPCCodec.encodeRequest(
            id: 9,
            method: "account/read",
            params: ["refreshToken": false]
        )
        let object = try JSONSerialization.jsonObject(with: request.dropLast()) as? [String: Any]
        let params = object?["params"] as? [String: Any]
        try expect(object?["method"] as? String == "account/read", "account read method")
        try expect(params?["refreshToken"] as? Bool == false, "account read must not refresh credentials")
    }

    private static func testUnknownProfileIsMarked() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("codex-unknown-profile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = AccountProfileStore(applicationSupportURL: base)
        let selection = store.select(identity: AccountIdentity(accountType: "apiKey", authMode: "apiKey", planType: nil, email: nil, requiresOpenAIAuth: false))
        try expect(selection.profile.isUnidentified, "missing email must be marked unidentified")
        try expect(selection.profile.displayName == "未識別帳號", "missing email display name")
        let switched = store.select(identity: AccountIdentity(accountType: "apiKey", authMode: "apiKey", planType: nil, email: nil, requiresOpenAIAuth: false), forceNewUnidentified: true)
        try expect(switched.profile.id != selection.profile.id, "explicit account boundary gets a new unidentified profile")
        let periodic = store.select(identity: AccountIdentity(accountType: "apiKey", authMode: "apiKey", planType: nil, email: nil, requiresOpenAIAuth: false))
        try expect(periodic.profile.id == switched.profile.id, "periodic refresh stays on the manually selected unidentified profile")
        let reloaded = AccountProfileStore(applicationSupportURL: base)
        let afterRelaunch = reloaded.select(identity: AccountIdentity(accountType: "apiKey", authMode: "apiKey", planType: nil, email: nil, requiresOpenAIAuth: false))
        try expect(afterRelaunch.profile.id == switched.profile.id, "relaunch prefers the most recently used unidentified profile")
    }

    private static func testManagedProfileHasIsolatedCodexHome() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("codex-profile-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = AccountProfileStore(applicationSupportURL: base)
        let first = store.createManagedProfile(displayName: "A")
        let second = store.createManagedProfile(displayName: "B")
        try expect(store.codexHomeURL(for: first) != store.codexHomeURL(for: second), "managed profiles need independent CODEX_HOME")
        try expect(first.isManaged && second.isManaged, "manual managed profiles should be marked managed")
    }

    private static func testManagedProfileImportsAuth() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("codex-profile-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let auth = source.appendingPathComponent("auth.json")
        try Data("{\"auth_mode\":\"chatgpt\",\"refresh_token\":\"redacted-fixture\"}".utf8).write(to: auth)
        let store = AccountProfileStore(applicationSupportURL: base.appendingPathComponent("store"))
        let profile = store.createManagedProfile(displayName: "Imported")
        try store.importCodexHome(from: source, into: profile)
        try expect(store.hasCredentials(for: profile), "import should install auth.json")
        let persisted = try String(contentsOf: store.credentialsURL(for: profile), encoding: .utf8)
        try expect(persisted.contains("redacted-fixture"), "fixture auth should be copied to isolated home")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.credentialsURL(for: profile).path)
        try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "auth.json should be owner-only")
    }

    private static func testAccountProfileDisplayFormatting() throws {
        try expect(AccountProfileDisplay.maskEmail(" person@example.com ") == "p*****@example.com", "email should be masked")
        try expect(AccountProfileDisplay.maskEmail("ab@example.com") == "a*@example.com", "short email should remain distinguishable")
        try expect(AccountProfileDisplay.maskEmail("not-an-email") == nil, "invalid email should be rejected")
        try expect(AccountProfileDisplay.fullEmail(" person@example.com ") == "person@example.com", "full email should be trimmed without masking")
        try expect(AccountProfileDisplay.fullEmail("not-an-email") == nil, "invalid full email should be rejected")

        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let first = AccountProfile(id: firstID, fingerprint: "unknown-a", displayName: "ChatGPT 帳號", accountType: "chatgpt", authMode: "chatgpt", lastSeen: Date(), isUnidentified: true)
        let second = AccountProfile(id: secondID, fingerprint: "unknown-b", displayName: "ChatGPT 帳號", accountType: "chatgpt", authMode: "chatgpt", lastSeen: Date(), isUnidentified: true)
        let profiles = [second, first]
        let firstDisplay = AccountProfileDisplay.make(profile: first, among: profiles, health: nil)
        let secondDisplay = AccountProfileDisplay.make(profile: second, among: profiles, health: nil)
        try expect(firstDisplay.title == "未識別帳號 1", "unidentified ordinal should use UUID order")
        try expect(secondDisplay.title == "未識別帳號 2", "unidentified ordinal should be stable")
        try expect(firstDisplay.subtitle == "ChatGPT · 未提供方案", "fallback subtitle should include auth and plan")

        let custom = AccountProfile(id: UUID(), fingerprint: "custom", displayName: "公司帳號", accountType: "chatgpt", authMode: "chatgpt", lastSeen: Date(), isDisplayNameCustom: true, isUnidentified: true)
        let customDisplay = AccountProfileDisplay.make(profile: custom, among: [custom], health: nil)
        try expect(customDisplay.title == "公司帳號", "custom name should be preserved")

        let health = AccountHealthSnapshot(
            identity: AccountIdentity(accountType: "chatgpt", authMode: "chatgpt", planType: "Plus", email: "person@example.com", requiresOpenAIAuth: true),
            receivedAt: Date(),
            connectionState: .connected
        )
        let known = AccountProfile(id: UUID(), fingerprint: "known", displayName: "ChatGPT 帳號", accountType: "chatgpt", authMode: "chatgpt", lastSeen: Date())
        let knownDisplay = AccountProfileDisplay.make(profile: known, among: [known], health: health)
        try expect(knownDisplay.title == "person@example.com", "known account should use full email as title")
        try expect(knownDisplay.subtitle == "Plus · ChatGPT", "known account should show plan and auth below full email")

        let managedHealth = AccountHealthSnapshot(
            identity: AccountIdentity(accountType: "chatgpt", authMode: "managed", planType: "Plus", email: "person@example.com", requiresOpenAIAuth: true),
            receivedAt: Date(),
            connectionState: .connected
        )
        let managedDisplay = AccountProfileDisplay.make(profile: known, among: [known], health: managedHealth)
        try expect(managedDisplay.title == "person@example.com", "managed account should keep full email title")
        try expect(managedDisplay.subtitle == "Plus · ChatGPT", "managed ChatGPT auth should use friendly label")

        let apiProfile = AccountProfile(id: UUID(), fingerprint: "api", displayName: "未識別帳號", accountType: "apiKey", authMode: "apiKey", lastSeen: Date(), isUnidentified: true)
        let apiHealth = AccountHealthSnapshot(
            identity: AccountIdentity(accountType: "apiKey", authMode: "apiKey", planType: nil, email: nil, requiresOpenAIAuth: false),
            receivedAt: Date(),
            connectionState: .connected
        )
        let apiDisplay = AccountProfileDisplay.make(profile: apiProfile, among: [apiProfile], health: apiHealth)
        try expect(apiDisplay.subtitle == "API Key · 未提供方案", "no-email account should show safe fallback")
    }

    private static func testUpdateVersionComparison() throws {
        try expect(AppVersionComparator.isNewer("v2.4.12", than: "2.4.11"), "v tag should compare newer")
        try expect(AppVersionComparator.isNewer("2.5", than: "2.4.99"), "minor version should compare newer")
        try expect(!AppVersionComparator.isNewer("2.4.11", than: "2.4.11"), "same version is not newer")
        try expect(!AppVersionComparator.isNewer("2.4.10", than: "2.4.11"), "older version is not newer")
    }

    private static func testGitWorkspacePolicies() throws {
        let payload = "# branch.oid abcdef123\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +2 -1\01 .M N... 100644 100644 100644 abc def file.swift\0? .env\0"
        let parsed = GitStatusPorcelainParser.parse(Data(payload.utf8))
        try expect(parsed.branch == "main", "branch parses")
        try expect(parsed.ahead == 2 && parsed.behind == 1, "ahead/behind parses")
        try expect(parsed.changes.contains { $0.path == "file.swift" && $0.isUnstaged }, "modified path parses")
        try expect(parsed.changes.contains { $0.path == ".env" && $0.isSensitive }, "sensitive path parses")

        let commit = GitCommitPolicy.arguments(message: "safe change", paths: ["file.swift"])
        try expect(commit?.contains("--only") == true, "commit isolates selected paths")
        try expect(commit?.suffix(1).first == "file.swift", "commit uses explicit pathspec")
        try expect(GitCommitPolicy.arguments(message: " ", paths: ["file.swift"]) == nil, "empty message rejected")
        try expect(GitCommitPolicy.arguments(message: "safe", paths: ["../secret"]) == nil, "unsafe path rejected")

        let identity = GitWorkspaceIdentity(repositoryRoot: "/repo", gitDirectory: "/repo/.git", branch: "main", head: "abc", remote: "origin", upstream: "origin/main", remoteFingerprint: "test-remote")
        try expect(GitPushPolicy.arguments(identity: identity) == ["push", "origin", "HEAD:refs/heads/main"], "push uses explicit refspec")
        try expect(GitWorkspaceSensitivity.isSensitive(path: "credentials/token.pem"), "credential extension is sensitive")
        try expect(!GitWorkspaceSensitivity.isSensitive(path: "Sources/App.swift"), "normal source is not sensitive")
    }

    /// Exercises the exact commit contract against a disposable repository:
    /// an already-staged path must remain staged when a different modified
    /// path is committed with `--only`.
    private static func testGitSelectedCommitIsolation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-git-commit-isolation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try runGit(["init", "-q"], at: root)
        _ = try runGit(["config", "user.name", "Codex Test"], at: root)
        _ = try runGit(["config", "user.email", "codex-test@example.invalid"], at: root)
        try Data("a0\n".utf8).write(to: root.appendingPathComponent("A.swift"))
        try Data("b0\n".utf8).write(to: root.appendingPathComponent("B.swift"))
        _ = try runGit(["add", "--", "A.swift", "B.swift"], at: root)
        _ = try runGit(["commit", "-q", "-m", "baseline"], at: root)

        try Data("a1\n".utf8).write(to: root.appendingPathComponent("A.swift"))
        try Data("b1\n".utf8).write(to: root.appendingPathComponent("B.swift"))
        _ = try runGit(["add", "--", "A.swift"], at: root)
        guard let arguments = GitCommitPolicy.arguments(message: "selected B", paths: ["B.swift"]) else {
            throw HarnessError.unwrap("selected commit arguments")
        }
        _ = try runGit(arguments, at: root)

        let committed = try runGit(["show", "--format=", "--name-only", "HEAD"], at: root)
        try expect(committed.contains("B.swift"), "selected modified path must be committed")
        try expect(!committed.contains("A.swift"), "pre-existing staged path must not be committed")
        let status = try runGit(["status", "--short"], at: root)
        try expect(status.split(separator: "\n").contains { $0.hasSuffix("A.swift") }, "pre-existing staged path remains staged")
    }

    /// Verifies the selected-untracked intent-to-add flow and the sensitive
    /// diff boundary used by the service before any raw preview is rendered.
    private static func testGitUntrackedCommitAndSensitiveBoundaries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-git-untracked-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try runGit(["init", "-q"], at: root)
        _ = try runGit(["config", "user.name", "Codex Test"], at: root)
        _ = try runGit(["config", "user.email", "codex-test@example.invalid"], at: root)
        try Data("tracked\n".utf8).write(to: root.appendingPathComponent("Tracked.swift"))
        _ = try runGit(["add", "--", "Tracked.swift"], at: root)
        _ = try runGit(["commit", "-q", "-m", "baseline"], at: root)
        try Data("staged\n".utf8).write(to: root.appendingPathComponent("Tracked.swift"))
        _ = try runGit(["add", "--", "Tracked.swift"], at: root)
        try Data("new\n".utf8).write(to: root.appendingPathComponent("New.swift"))
        _ = try runGit(["add", "--intent-to-add", "--", "New.swift"], at: root)
        guard let arguments = GitCommitPolicy.arguments(message: "selected new", paths: ["New.swift"]) else {
            throw HarnessError.unwrap("untracked commit arguments")
        }
        _ = try runGit(arguments, at: root)
        let committed = try runGit(["show", "--format=", "--name-only", "HEAD"], at: root)
        try expect(committed.contains("New.swift"), "selected untracked path must be committed")
        try expect(!committed.contains("Tracked.swift"), "unrelated staged path must remain outside commit")
        let status = try runGit(["status", "--short"], at: root)
        try expect(status.split(separator: "\n").contains { $0.hasSuffix("Tracked.swift") }, "unrelated staged path remains staged")

        for sensitive in [".env", "auth.json", "accounts/profile.json", "keys/private.pem", "token-activity.json"] {
            try expect(GitWorkspaceSensitivity.isSensitive(path: sensitive), "sensitive path must be suppressed: \(sensitive)")
        }
        try expect(!GitWorkspaceSensitivity.isSensitive(path: "Sources/Feature.swift"), "normal path remains previewable")
    }

    private static func testGitPushIdentityFreeze() throws {
        let base = GitWorkspaceIdentity(repositoryRoot: "/repo", gitDirectory: "/repo/.git", branch: "main", head: "abc", remote: "origin", upstream: "origin/main", remoteFingerprint: "fingerprint")
        try expect(GitPushPolicy.arguments(identity: base) == ["push", "origin", "HEAD:refs/heads/main"], "push uses frozen explicit refspec")
        let changedHead = GitWorkspaceIdentity(repositoryRoot: base.repositoryRoot, gitDirectory: base.gitDirectory, branch: base.branch, head: "def", remote: base.remote, upstream: base.upstream, remoteFingerprint: base.remoteFingerprint)
        try expect(changedHead != base, "HEAD drift must invalidate frozen identity")
        let changedRemote = GitWorkspaceIdentity(repositoryRoot: base.repositoryRoot, gitDirectory: base.gitDirectory, branch: base.branch, head: base.head, remote: base.remote, upstream: base.upstream, remoteFingerprint: "other")
        try expect(changedRemote != base, "remote drift must invalidate frozen identity")
        let missingFingerprint = GitWorkspaceIdentity(repositoryRoot: base.repositoryRoot, gitDirectory: base.gitDirectory, branch: base.branch, head: base.head, remote: base.remote, upstream: base.upstream, remoteFingerprint: nil)
        try expect(GitPushPolicy.arguments(identity: missingFingerprint) == nil, "missing remote identity must fail closed")
    }

    private static func runGit(_ arguments: [String], at root: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "GIT_TERMINAL_PROMPT": "0"]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HarnessError.assertion("git fixture command failed: \(arguments.joined(separator: " "))")
        }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private static func testHUDContextMenuPolicy() throws {
        let actions = HUDContextMenuPolicy.sections.flatMap { $0 }
        try expect(actions.contains(.refresh) && actions.contains(.showDetails), "status actions are present")
        try expect(actions.contains(.openCodex) && actions.contains(.resetPosition), "Codex actions are present")
        try expect(actions.contains(.hudScale), "HUD scale action is present")
        try expect(actions.contains(.paste) && actions.contains(.pasteAndSubmit), "clipboard actions are distinct")
        try expect(actions.contains(.openGitWorkspace) && actions.contains(.refreshGitWorkspace), "git actions are present")
        try expect(actions.contains(.currentAccount) && actions.contains(.allAccounts) && actions.contains(.manageAccounts), "account actions are present")
        try expect(actions.contains(.checkForUpdates) && actions.contains(.quit), "update and quit actions are present")
        try expect(HUDContextMenuPolicy.pasteActionsEnabled(isCodexFocused: true), "focused paste is enabled")
        try expect(!HUDContextMenuPolicy.pasteActionsEnabled(isCodexFocused: false), "unfocused paste is disabled")
        try expect(HUDContextMenuPolicy.sections.last == [.quit], "quit is isolated at the bottom")
    }

    private static func testUsagePopoverTabsAndAppVersion() throws {
        try expect(
            UsagePopoverTab.allCases.map(\.rawValue) == ["overview", "usage", "history", "accountGit", "settings"],
            "usage popover exposes stable content tabs"
        )
        try expect(UsagePopoverTab.settings.title == "設定", "settings has a dedicated tab")
        try expect(UsagePopoverTab.accountGit.title == "帳號與 Git", "account and Git have a dedicated tab")
        try expect(AppVersion.label == "v\(AppVersion.current)", "app version label is derived from bundle version")
    }

    private static func testPopoverPresentationAppearancePolicy() throws {
        let appearance = PopoverPresentationPolicy.makeAppearance()
        try expect(
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua,
            "popover opens with the stable light appearance"
        )
        try expect(
            PopoverPresentationPolicy.reappliesAfterPopoverDidShow,
            "popover reapplies appearance after its window is created"
        )
        let popover = NSPopover()
        PopoverPresentationPolicy.apply(to: popover)
        try expect(
            popover.appearance?.name == .aqua,
            "popover appearance is pinned directly on the popover"
        )
        try expect(
            PopoverPresentationPolicy.shouldActivateApplication(isActive: false),
            "an inactive accessory app is activated before the first popover presentation"
        )
        try expect(
            !PopoverPresentationPolicy.shouldActivateApplication(isActive: true),
            "an already-active app is not redundantly activated"
        )
        let effectView = NSVisualEffectView()
        PopoverPresentationPolicy.applyActiveMaterial(to: effectView)
        try expect(
            effectView.state == .active,
            "popover material is active on the first presentation"
        )
        try expect(
            effectView.material == .popover,
            "popover uses the semantic popover material"
        )
    }

    private static func testHUDScaleLevels() throws {
        try expect(HUDScaleLevel.allCases.count == 7, "seven scale levels are available")
        try expect(
            HUDScaleLevel.allCases == [.smaller4, .smaller3, .smaller2, .smaller1, .standard, .larger1, .larger2],
            "scale levels use compact-to-large UI order"
        )
        try expect(HUDScaleLevel.smaller4.scaleFactor == 0.64, "level 1 factor")
        try expect(HUDScaleLevel.smaller3.scaleFactor == 0.72, "level 2 factor")
        try expect(HUDScaleLevel.smaller2.scaleFactor == 0.8, "level 1 factor")
        try expect(HUDScaleLevel.smaller1.scaleFactor == 0.9, "level 2 factor")
        try expect(HUDScaleLevel.standard.scaleFactor == 1.0, "level 3 is standard")
        try expect(HUDScaleLevel.larger1.scaleFactor == 1.15, "level 4 factor")
        try expect(HUDScaleLevel.larger2.scaleFactor == 1.3, "level 5 factor")
        try expect(HUDScaleLevel.standard.displayName == "標準", "level 3 label")
        try expect(HUDScaleLevel.smaller4.displayName == "小 4 級", "level 1 label")
        try expect(HUDScaleLevel.smaller3.displayName == "小 3 級", "level 2 label")
        try expect(HUDScaleLevel.smaller2.displayName == "小 2 級", "level 1 label")
        try expect(HUDScaleLevel.larger2.displayName == "大 2 級", "level 5 label")
        let suiteName = "CodexUsageStatusTests.scale.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        HUDScaleLevel.larger2.persist(to: defaults)
        try expect(HUDScaleLevel.load(from: defaults) == .larger2, "scale persists and reloads")
        defaults.set(99, forKey: HUDScaleLevel.userDefaultsKey)
        try expect(HUDScaleLevel.load(from: defaults) == .standard, "invalid scale falls back to standard")
        defaults.set(3, forKey: HUDScaleLevel.userDefaultsKey)
        defaults.removeObject(forKey: HUDScaleLevel.schemaVersionKey)
        try expect(HUDScaleLevel.load(from: defaults) == .standard, "legacy standard remains level 3")
        defaults.set(1, forKey: HUDScaleLevel.userDefaultsKey)
        defaults.set(2, forKey: HUDScaleLevel.schemaVersionKey)
        try expect(HUDScaleLevel.load(from: defaults) == .standard, "interim standard migrates to level 3")
        defaults.set(3, forKey: HUDScaleLevel.userDefaultsKey)
        defaults.set(2, forKey: HUDScaleLevel.schemaVersionKey)
        try expect(HUDScaleLevel.load(from: defaults) == .larger2, "interim level 3 preserves 130 percent")
        defaults.set(5, forKey: HUDScaleLevel.userDefaultsKey)
        defaults.set(2, forKey: HUDScaleLevel.schemaVersionKey)
        try expect(HUDScaleLevel.load(from: defaults) == .standard, "unknown interim level falls back")

        defaults.set(1, forKey: HUDScaleLevel.userDefaultsKey)
        defaults.set(3, forKey: HUDScaleLevel.schemaVersionKey)
        try expect(HUDScaleLevel.load(from: defaults) == .standard, "old smallest becomes new standard")
        defaults.set(2, forKey: HUDScaleLevel.userDefaultsKey)
        defaults.set(3, forKey: HUDScaleLevel.schemaVersionKey)
        try expect(HUDScaleLevel.load(from: defaults) == .larger1, "old level 2 maps to nearest larger level")
        defaults.set(3, forKey: HUDScaleLevel.userDefaultsKey)
        defaults.set(3, forKey: HUDScaleLevel.schemaVersionKey)
        try expect(HUDScaleLevel.load(from: defaults) == .larger2, "old standard maps to nearest larger level")
        defaults.set(1, forKey: HUDScaleLevel.userDefaultsKey)
        defaults.set(4, forKey: HUDScaleLevel.schemaVersionKey)
        try expect(HUDScaleLevel.load(from: defaults) == .standard, "schema 4 smallest becomes new standard")
        defaults.set(3, forKey: HUDScaleLevel.userDefaultsKey)
        defaults.set(4, forKey: HUDScaleLevel.schemaVersionKey)
        try expect(HUDScaleLevel.load(from: defaults) == .larger2, "schema 4 old standard maps upward")

        let schemaFiveExpectations: [(Int, HUDScaleLevel)] = [
            (1, .smaller2),
            (2, .smaller1),
            (3, .standard),
            (4, .larger1),
            (5, .larger2)
        ]
        for (rawValue, expectedLevel) in schemaFiveExpectations {
            defaults.set(rawValue, forKey: HUDScaleLevel.userDefaultsKey)
            defaults.set(5, forKey: HUDScaleLevel.schemaVersionKey)
            try expect(
                HUDScaleLevel.load(from: defaults) == expectedLevel,
                "schema 5 raw \(rawValue) preserves its physical level"
            )
            try expect(
                defaults.integer(forKey: HUDScaleLevel.schemaVersionKey) == HUDScaleLevel.currentSchemaVersion,
                "schema 5 raw \(rawValue) migrates the schema marker"
            )
        }
    }

    private static func testHUDMetrics() throws {
        let standard = HUDMetrics(scaleLevel: .standard)
        try expect(standard.panelSize == CGSize(width: 416, height: 240), "level 3 panel size")
        try expectApproximately(standard.contentWidth, 387.2, "content width follows outer padding")
        try expectApproximately(standard.quotaColumnHeight, 86.4, "quota rows close to 86.4pt")
        try expectApproximately(standard.headerHeight, 24, "header height")
        try expectApproximately(standard.headerGap, 8, "header gap")
        try expectApproximately(standard.verticalContentHeight, 211.2, "vertical content closes with header")
        try expectApproximately(standard.verticalContentHeight + standard.outerPadding * 2, 240, "canonical height closes")
        try expectSizeApproximately(standard.panelSize(quotaRowCount: 1), CGSize(width: 416, height: 193.6), "one quota row removes empty vertical space")
        try expectSizeApproximately(standard.panelSize(quotaRowCount: 2), CGSize(width: 416, height: 240), "two quota rows retain canonical geometry")
        try expectSizeApproximately(standard.panelSize(quotaRowCount: 3), CGSize(width: 416, height: 286.4), "three quota rows grow only by quota height")
        try expectSizeApproximately(HUDMetrics(scaleLevel: .smaller2).panelSize, CGSize(width: 332.8, height: 192), "level 1 scales one layout")
        try expectSizeApproximately(HUDMetrics(scaleLevel: .smaller4).panelSize, CGSize(width: 266.24, height: 153.6), "level 1 scales one layout")
        try expectSizeApproximately(HUDMetrics(scaleLevel: .smaller3).panelSize, CGSize(width: 299.52, height: 172.8), "level 2 scales one layout")
        try expectSizeApproximately(HUDMetrics(scaleLevel: .smaller1).panelSize, CGSize(width: 374.4, height: 216), "level 2 scales one layout")
        try expectSizeApproximately(HUDMetrics(scaleLevel: .larger1).panelSize, CGSize(width: 478.4, height: 276), "level 4 scales one layout")
        try expectSizeApproximately(HUDMetrics(scaleLevel: .larger2).panelSize, CGSize(width: 540.8, height: 312), "level 5 scales one layout")
        try expect(standard.footerButtonWidth > 118, "footer buttons retain readable widths")
        try expect(standard.footerControlsWidth <= standard.contentWidth, "footer buttons fit content width")
        try expect(
            3 * standard.actionCardWidth + (standard.actionSpacing * 2) <= standard.contentWidth + 0.01,
            "standard action cards fit three columns"
        )
        for level in HUDScaleLevel.allCases {
            let metrics = HUDMetrics(scaleLevel: level)
            try expectApproximately(
                metrics.verticalContentHeight + metrics.outerPadding * 2,
                metrics.panelSize.height,
                "vertical layout closes at \(level.displayName)"
            )
            let occupiedFooterWidth = metrics.footerControlsWidth
                + metrics.footerHorizontalPadding
            try expectApproximately(occupiedFooterWidth, metrics.contentWidth,
                                    "footer fills its content width at every scale level")
            try expect(
                3 * metrics.actionCardWidth + (metrics.actionSpacing * 2) <= metrics.contentWidth + 0.01,
                "action cards fit three columns at every scale level"
            )
            for rowCount in 1...3 {
                let dynamicHeight = metrics.verticalContentHeight(for: rowCount) + metrics.outerPadding * 2
                try expectApproximately(
                    dynamicHeight,
                    metrics.panelSize(quotaRowCount: rowCount).height,
                    "dynamic quota layout closes at \(level.displayName), \(rowCount) rows"
                )
            }
        }
    }

    private static func testHUDUpdateBadgePolicy() throws {
        let release = AppUpdateRelease(
            version: "2.5.0",
            tagName: "v2.5.0",
            name: "Codex Usage Status 2.5.0",
            releaseURL: URL(string: "https://example.com/release")!,
            downloadURL: nil,
            expectedSHA256: nil,
            notes: "",
            publishedAt: nil
        )
        try expect(
            HUDUpdateBadgePolicy.state(updateState: .idle, currentVersion: "2.4.51") == .version("2.4.51"),
            "idle shows current version"
        )
        try expect(
            HUDUpdateBadgePolicy.state(updateState: .upToDate, currentVersion: "2.4.51") == .version("2.4.51"),
            "up-to-date shows current version"
        )
        try expect(
            HUDUpdateBadgePolicy.state(updateState: .available(release), currentVersion: "2.4.51") == .available("2.5.0"),
            "available shows update badge"
        )
        try expect(
            HUDUpdateBadgePolicy.state(updateState: .downloaded(release, URL(fileURLWithPath: "/tmp/CodexUsageStatus.app")), currentVersion: "2.4.51") == .available("2.5.0"),
            "downloaded remains actionable"
        )
        try expect(
            HUDUpdateBadgePolicy.state(updateState: .downloading(release), currentVersion: "2.4.51") == .downloading,
            "downloading shows progress"
        )
        try expect(
            HUDUpdateBadgePolicy.state(updateState: .checking, currentVersion: "2.4.51") == .checking,
            "checking shows progress"
        )
        try expect(
            HUDUpdateBadgePolicy.state(updateState: .error("network"), currentVersion: "2.4.51") == .error("2.4.51"),
            "error keeps current version"
        )
        try expect(HUDUpdateBadgeState.available("2.5.0").isActionable, "available badge opens details")
        try expect(HUDUpdateBadgeState.error("2.4.51").isActionable, "error badge retries check")
        try expect(!HUDUpdateBadgeState.version("2.4.51").isActionable, "version badge is informational")
        try expect(!HUDUpdateBadgeState.checking.isActionable, "checking badge is disabled")
    }

    private static func testCodexPromptShortcuts() throws {
        try expect(CodexPromptShortcut.commit.text == "Commit", "commit shortcut text")
        try expect(CodexPromptShortcut.push.text == "Push", "push shortcut text")
        try expect(CodexPromptShortcut.commitPush.text == "Commit Push", "combined shortcut text")
        try expect(!CodexPromptShortcut.commit.submitAfterPaste, "commit does not submit")
        try expect(!CodexPromptShortcut.push.submitAfterPaste, "push does not submit")
        try expect(CodexPromptShortcut.commitPush.submitAfterPaste, "combined shortcut submits")
        try expect(CodexPromptShortcut.execute.text == "執行", "execute shortcut text")
        try expect(CodexPromptShortcut.execute.submitAfterPaste, "execute shortcut submits")
    }

    private static func testCodexApplicationIdentity() throws {
        try expect(
            CodexApplicationPolicy.isCodexApplication(bundleIdentifier: "com.openai.codex"),
            "native Codex bundle should be accepted"
        )
        try expect(
            CodexApplicationPolicy.isCodexApplication(bundleIdentifier: " COM.OPENAI.CODEX "),
            "native Codex bundle matching should be case and whitespace tolerant"
        )
        try expect(
            !CodexApplicationPolicy.isCodexApplication(bundleIdentifier: "com.openai.chatgpt"),
            "ChatGPT must not be treated as Codex"
        )
        try expect(
            !CodexApplicationPolicy.isCodexApplication(
                bundleIdentifier: nil,
                localizedName: "ChatGPT",
                bundlePath: "/Applications/ChatGPT.app"
            ),
            "name and path alone must not identify Codex"
        )
        try expect(
            !CodexApplicationPolicy.isCodexApplication(bundleIdentifier: "com.openai.codex-usage-status"),
            "usage status app must not host its own HUD"
        )
        try expect(
            !CodexApplicationPolicy.isCodexApplication(bundleIdentifier: nil),
            "missing bundle identity must fail closed"
        )
    }

    private static func testClipboardTemporaryOperationPolicy() throws {
        try expect(ClipboardTemporaryOperationPolicy.canStart(isOperationInFlight: false), "idle operation can start")
        try expect(!ClipboardTemporaryOperationPolicy.canStart(isOperationInFlight: true), "single-flight rejects overlap")
        try expect(ClipboardTemporaryOperationPolicy.preparedTextWriteIsValid(
            expectedText: "Commit", observedText: "Commit", beforeChangeCount: 326, afterChangeCount: 326
        ), "setString may leave changeCount unchanged")
        try expect(!ClipboardTemporaryOperationPolicy.preparedTextWriteIsValid(
            expectedText: "Commit", observedText: "Push", beforeChangeCount: 326, afterChangeCount: 326
        ), "wrong text fails closed")
        try expect(!ClipboardTemporaryOperationPolicy.preparedTextWriteIsValid(
            expectedText: "Commit", observedText: "Commit", beforeChangeCount: 326, afterChangeCount: 325
        ), "counter regression fails closed")
        try expect(ClipboardTemporaryOperationPolicy.canRestore(
            expectedText: "Push", observedText: "Push", preparedChangeCount: 327, currentChangeCount: 327
        ), "unchanged owned clipboard may restore")
        try expect(!ClipboardTemporaryOperationPolicy.canRestore(
            expectedText: "Push", observedText: "New user text", preparedChangeCount: 327, currentChangeCount: 328
        ), "new user clipboard is never overwritten")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw HarnessError.assertion(message) }
    }

    private static func expectApproximately(
        _ actual: CGFloat,
        _ expected: CGFloat,
        _ message: String,
        tolerance: CGFloat = 0.001
    ) throws {
        try expect(abs(actual - expected) <= tolerance, message)
    }

    private static func expectSizeApproximately(
        _ actual: CGSize,
        _ expected: CGSize,
        _ message: String,
        tolerance: CGFloat = 0.001
    ) throws {
        try expect(
            abs(actual.width - expected.width) <= tolerance
                && abs(actual.height - expected.height) <= tolerance,
            message
        )
    }
}

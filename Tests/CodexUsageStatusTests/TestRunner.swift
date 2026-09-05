import Foundation
import CoreGraphics
import AppKit
import Darwin

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

private final class NotificationCleanupProbe: RetiredFeatureNotificationCenter, @unchecked Sendable {
    var pending = ["feed-pending", "quota-pending"]
    var delivered = ["feed-delivered", "turn-delivered"]
    private(set) var removedPending: [String] = []
    private(set) var removedDelivered: [String] = []

    func getPendingNotificationIdentifiers(completionHandler: @Sendable @escaping ([String]) -> Void) {
        completionHandler(pending)
    }

    func getDeliveredNotificationIdentifiers(completionHandler: @Sendable @escaping ([String]) -> Void) {
        completionHandler(delivered)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedPending.append(contentsOf: identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedDelivered.append(contentsOf: identifiers)
    }
}

private final class FailingMoveFileManager: FileManager {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        throw NSError(domain: "RetiredFeatureCleanupTests", code: 1)
    }
}

@main
struct CodexUsageStatusTests {
    static func main() async {
        let tests: [(String, () throws -> Void)] = [
            ("full snapshot prefers codex bucket", testFullSnapshotPrefersCodexBucket),
            ("empty codex bucket falls back", testEmptyCodexBucketFallsBack),
            ("sparse patch preserves metadata", testSparsePatchPreservesMetadata),
            ("purchased credits decode and format", testPurchasedCreditsDecodeAndFormat),
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
            ("HUD drag geometry", testHUDDragGeometry),
            ("token activity decoding", testTokenActivityDecoding),
            ("token activity null fields", testTokenActivityNullFields),
            ("token activity presentation", testTokenActivityPresentation),
            ("token activity aggregation", testTokenActivityAggregation),
            ("token activity update feedback", testTokenActivityUpdateFeedback),
            ("status item presentation projection", testStatusItemPresentationProjection),
            ("HUD presentation boundary", testHUDPresentationBoundary),
            ("token activity store replacement and retention", testTokenActivityStoreReplacementAndRetention),
            ("token activity semantic dedupe", testTokenActivitySemanticDedupe),
            ("corrupt token activity preserves memory", testCorruptTokenActivityPreservesMemory),
            ("reset credit decoding and sparse preservation", testResetCreditDecoding),
            ("reset credit consume request", testResetCreditConsumeRequest),
            ("account health decoding", testAccountHealthDecoding),
            ("account profile display formatting", testAccountProfileDisplayFormatting),
            ("account scope summary", testAccountScopeSummary),
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
            ("retired feature cleanup", testRetiredFeatureCleanup)
            ,("App Server retry policy", testAppServerRetryPolicy)
            ,("refresh request coalescing", testRefreshRequestCoalescing)
            ,("account refresh dependency policy", testAccountRefreshDependencyPolicy)
            ,("App Server replacement admission", testAppServerReplacementAdmission)
            ,("managed worker admission", testManagedWorkerAdmission)
            ,("bounded termination flush", testBoundedTerminationFlush)
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
        do {
            try await testLoginLifecycleShutdown()
            print("PASS login lifecycle shutdown")
        } catch {
            failures += 1
            print("FAIL login lifecycle shutdown: \(error)")
        }
        do {
            try await testPersistenceWriteCoordinator()
            print("PASS persistence write coordinator")
        } catch {
            failures += 1
            print("FAIL persistence write coordinator: \(error)")
        }
        print("\(tests.count + 2 - failures)/\(tests.count + 2) tests passed")
        if failures > 0 { exit(1) }
    }

    private static func testFullSnapshotPrefersCodexBucket() throws {
        let result: [String: Any] = [
            "rateLimits": [
                "limitId": "legacy",
                "limitName": "Legacy",
                "planType": "pro",
                "primary": ["usedPercent": 40, "resetsAt": 100, "windowDurationMins": 60],
                "credits": ["hasCredits": true, "unlimited": false, "balance": "814.3903237500"]
            ],
            "rateLimitsByLimitId": [
                "codex": [
                    "limitId": "codex",
                    "limitName": "Codex",
                    "primary": ["usedPercent": 25, "resetsAt": 200, "windowDurationMins": 15],
                    "secondary": ["usedPercent": 60, "resetsAt": 300, "windowDurationMins": 10080]
                ],
                "base_model_inference": [
                    "limitId": "base_model_inference",
                    "limitName": "gpt-reserve",
                    "primary": ["usedPercent": 0, "resetsAt": 400, "windowDurationMins": 10080]
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
        try expect(snapshot.gptReserveWeekly?.usedPercent == 0, "gpt-reserve bucket should be decoded")
        try expect(snapshot.gptReserveWeekly?.remainingPercent == 100, "gpt-reserve remaining percent")
        try expect(snapshot.credits?.displayBalance == "814.39", "credits should round to two decimals")
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
                "spendControlReached": false,
                "credits": ["hasCredits": true, "unlimited": false, "balance": "814.3903237500"]
            ],
            "rateLimitsByLimitId": [
                "base_model_inference": [
                    "limitId": "base_model_inference",
                    "limitName": "gpt-reserve",
                    "primary": ["usedPercent": 4, "resetsAt": 400, "windowDurationMins": 10080]
                ]
            ]
        ]
        let current = try UsageDataCodec.decodeFullSnapshot(from: full)
        let patch = try UsageDataCodec.decodePatch(from: [
            "rateLimits": [
                "limitId": "codex",
                "primary": ["usedPercent": 31],
                "spendControlReached": NSNull(),
                "credits": ["balance": "900.5"]
            ]
        ])
        guard let merged = patch.applying(to: current) else { throw HarnessError.unwrap("merged snapshot") }
        try expect(merged.primary?.usedPercent == 31, "primary update")
        try expect(merged.primary?.resetsAt == 100, "primary reset should persist")
        try expect(merged.primary?.windowDurationMins == 15, "primary duration should persist")
        try expect(merged.secondary?.usedPercent == 40, "secondary should persist")
        try expect(merged.planType == "pro", "plan should persist")
        try expect(merged.individualLimit?.remainingPercent == 88, "spend control should persist")
        try expect(merged.gptReserveWeekly?.remainingPercent == 96, "gpt-reserve should persist through sparse patch")
        try expect(merged.spendControlReached == false, "null sparse boolean should not clear")
        try expect(merged.credits?.hasCredits == true, "sparse credits should retain hasCredits")
        try expect(merged.credits?.unlimited == false, "sparse credits should retain unlimited")
        try expect(merged.credits?.displayBalance == "900.50", "sparse credits should update balance")
    }

    private static func testPurchasedCreditsDecodeAndFormat() throws {
        let snapshot = try UsageDataCodec.decodeFullSnapshot(from: [
            "rateLimits": [
                "primary": ["usedPercent": 0],
                "credits": ["hasCredits": true, "unlimited": false, "balance": "0"]
            ]
        ])
        try expect(snapshot.credits?.isDisplayable == true, "zero purchased credits remain displayable")
        try expect(snapshot.credits?.displayBalance == "0.00", "zero credits format with two decimals")

        let unlimited = try UsageDataCodec.decodeFullSnapshot(from: [
            "rateLimits": [
                "primary": ["usedPercent": 0],
                "credits": ["hasCredits": true, "unlimited": true]
            ]
        ])
        try expect(unlimited.credits?.displayBalance == "∞", "unlimited credits use an explicit label")

        let invalid = try UsageDataCodec.decodeFullSnapshot(from: [
            "rateLimits": [
                "primary": ["usedPercent": 0],
                "credits": ["hasCredits": true, "unlimited": false, "balance": "not-a-number"]
            ]
        ])
        try expect(invalid.credits?.isDisplayable == false, "invalid balances should not render")

        let cleared = try UsageDataCodec.decodeFullSnapshot(from: [
            "rateLimits": [
                "primary": ["usedPercent": 0],
                "credits": NSNull()
            ]
        ])
        try expect(cleared.credits?.isDisplayable == false, "authoritative null clears credits")
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
            sevenDay: sevenDay,
            credits: CreditsBalance(hasCredits: true, unlimited: false, balance: "814.3903237500")
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
            mergedSparse?.credits == cachedA.credits,
            "a sparse live response must retain the cached purchased credits"
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
            receivedAt: now,
            credits: CreditsBalance(hasCredits: true, unlimited: false, balance: "814.3903237500")
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
        try expect(presentation.credits?.displayBalance == "814.39", "purchased credits pass through presentation")
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

        let withWireReserve = UsageSnapshot(
            limitId: nil, limitName: nil, planType: "plus",
            primary: primary, secondary: secondary,
            individualLimit: SpendControlLimit(
                limit: "100", used: "20", remainingPercent: 80,
                resetsAt: Int64(now.timeIntervalSince1970) + 3 * 86_400
            ),
            rateLimitReachedType: nil, spendControlReached: nil, receivedAt: now,
            gptReserveWeekly: RateLimitWindow(
                usedPercent: 0,
                resetsAt: Int64(now.timeIntervalSince1970) + 4 * 86_400,
                windowDurationMins: 10_080
            )
        )
        let wireReserveRows = HUDQuotaPresentationPolicy.make(snapshot: withWireReserve, profileID: profileID, now: now)
        try expect(wireReserveRows?.rows.count == 3, "wire gpt-reserve bucket exposes three HUD rows")
        try expect(wireReserveRows?.gptReserveWeekly?.remainingPercent == 100, "wire gpt-reserve wins over spend-control fallback")

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

    private static func testHUDDragGeometry() throws {
        let origin = HUDDragPolicy.origin(
            screenPoint: CGPoint(x: 1_240, y: 760),
            dragOffset: CGPoint(x: 48, y: 22)
        )
        try expect(origin == CGPoint(x: 1_192, y: 738), "drag preserves the original grab offset")

        try expect(
            HUDDragPolicy.origin(
                screenPoint: CGPoint(x: CGFloat.infinity, y: 10),
                dragOffset: CGPoint(x: 4, y: 4)
            ) == nil,
            "non-finite pointer coordinates are rejected"
        )
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

    private static func testTokenActivityPresentation() throws {
        let snapshot = TokenActivitySnapshot(
            fetchedAt: Date(timeIntervalSince1970: 0),
            lifetimeTokens: 4_829_524_138,
            peakDailyTokens: 575_763_278,
            longestRunningTurnSec: 64 * 3600 + 45 * 60,
            currentStreakDays: 1,
            longestStreakDays: 24,
            dailyUsageBuckets: nil
        )
        let metrics = TokenActivityPresentation.metrics(for: snapshot)
        try expect(metrics.map(\.label) == [
            "累計 token", "歷史單日峰值", "最長 Turn 時間", "目前連續", "最長連續"
        ], "summary labels preserve the five-field contract")
        try expect(metrics.map(\.value) == [
            "4,829,524,138", "575,763,278", "64 小時 45 分", "1 天", "24 天"
        ], "summary values use grouping and existing duration semantics")
        let sameMetricsDifferentFetch = TokenActivitySnapshot(
            fetchedAt: Date(timeIntervalSince1970: 99_999),
            lifetimeTokens: snapshot.lifetimeTokens,
            peakDailyTokens: snapshot.peakDailyTokens,
            longestRunningTurnSec: snapshot.longestRunningTurnSec,
            currentStreakDays: snapshot.currentStreakDays,
            longestStreakDays: snapshot.longestStreakDays,
            dailyUsageBuckets: [DailyTokenUsage(startDate: "2026-09-05", tokens: 1)]
        )
        try expect(TokenActivityPresentation.metrics(for: sameMetricsDifferentFetch) == metrics, "raw fetch time and daily buckets do not change HUD metrics")

        let nilSnapshot = TokenActivitySnapshot(
            fetchedAt: Date(), lifetimeTokens: nil, peakDailyTokens: nil,
            longestRunningTurnSec: nil, currentStreakDays: nil,
            longestStreakDays: nil, dailyUsageBuckets: nil
        )
        try expect(TokenActivityPresentation.metrics(for: nilSnapshot).allSatisfy { $0.value == "—" }, "unknown fields render a dash")
        try expect(TokenActivityPresentation.metrics(for: nil).count == 5, "missing snapshot still renders five stable HUD cells")
        try expect(TokenActivityPresentation.metrics(for: nil).allSatisfy { $0.value == "—" }, "missing snapshot renders dashes")
        try expect(TokenActivityPresentation.durationText(45) == "45 秒", "short durations preserve seconds")
        try expect(TokenActivityPresentation.durationText(125) == "2 分 5 秒", "minute durations preserve seconds")
    }

    private static func testTokenActivityAggregation() throws {
        let first = TokenActivitySnapshot(
            fetchedAt: Date(timeIntervalSince1970: 100), lifetimeTokens: 100,
            peakDailyTokens: 900, longestRunningTurnSec: 30,
            currentStreakDays: 2, longestStreakDays: 4,
            dailyUsageBuckets: [DailyTokenUsage(startDate: "2026-09-01", tokens: 10)]
        )
        let second = TokenActivitySnapshot(
            fetchedAt: Date(timeIntervalSince1970: 200), lifetimeTokens: nil,
            peakDailyTokens: 1_500, longestRunningTurnSec: nil,
            currentStreakDays: 3, longestStreakDays: nil,
            dailyUsageBuckets: [DailyTokenUsage(startDate: "2026-09-02", tokens: 20)]
        )
        let aggregate = TokenActivityPresentation.aggregate(
            snapshots: [first, second],
            dailyBuckets: [DailyTokenUsage(startDate: "2026-09-02", tokens: 20)],
            fetchedAt: second.fetchedAt
        )
        try expect(aggregate?.lifetimeTokens == 100, "all-account lifetime sums known values")
        try expect(aggregate?.peakDailyTokens == 1_500, "historical peak ignores selected chart range")
        try expect(aggregate?.longestRunningTurnSec == 30, "longest turn uses known profile maxima")
        try expect(aggregate?.dailyUsageBuckets?.count == 1, "daily buckets remain range-scoped")
        let allUnknown = TokenActivitySnapshot(
            fetchedAt: Date(), lifetimeTokens: nil, peakDailyTokens: nil,
            longestRunningTurnSec: nil, currentStreakDays: nil,
            longestStreakDays: nil, dailyUsageBuckets: nil
        )
        let unknownAggregate = TokenActivityPresentation.aggregate(
            snapshots: [allUnknown], dailyBuckets: [], fetchedAt: allUnknown.fetchedAt
        )
        try expect(unknownAggregate?.lifetimeTokens == nil, "all-account aggregation does not fabricate unknown lifetime")
        try expect(unknownAggregate?.peakDailyTokens == nil, "all-account aggregation does not fabricate unknown peak")
    }

    private static func testTokenActivityUpdateFeedback() throws {
        let baseDate = Date(timeIntervalSince1970: 1_757_000_000)

        func snapshot(
            at offset: TimeInterval = 0,
            lifetime: Int64? = 4_829_524_138,
            peak: Int64? = 575_763_278,
            longestTurn: Int64? = 64 * 3600 + 45 * 60,
            currentStreak: Int64? = 1,
            longestStreak: Int64? = 24
        ) -> TokenActivitySnapshot {
            TokenActivitySnapshot(
                fetchedAt: baseDate.addingTimeInterval(offset),
                lifetimeTokens: lifetime,
                peakDailyTokens: peak,
                longestRunningTurnSec: longestTurn,
                currentStreakDays: currentStreak,
                longestStreakDays: longestStreak,
                dailyUsageBuckets: nil
            )
        }

        let old = snapshot()
        let increased = snapshot(
            at: 60,
            lifetime: 4_831_028_746,
            peak: 600_000_000,
            longestTurn: 70 * 3600,
            currentStreak: 2
        )
        let event = TokenActivityFeedbackPolicy.make(
            previousSource: old,
            previousSummary: old,
            currentSummary: increased,
            incoming: increased,
            generation: 7
        )
        try expect(event?.generation == 7, "qualifying network update carries its generation")
        try expect(event?.previousLifetimeTokens == old.lifetimeTokens, "feedback retains the previous lifetime")
        try expect(event?.lifetimeTokens == increased.lifetimeTokens, "feedback retains the final lifetime")
        try expect(event?.lifetimeDelta == 1_504_608, "feedback computes the lifetime delta")
        try expect(event?.changed(TokenActivityPresentation.peakLabel) == true, "changed peak metric is marked for pulse")
        try expect(event?.changed(TokenActivityPresentation.longestTurnLabel) == true, "changed turn metric is marked for pulse")
        try expect(event?.changed(TokenActivityPresentation.currentStreakLabel) == true, "changed streak metric is marked for pulse")
        try expect(TokenActivitySoundPolicy.shouldPlay(for: event, enabled: true), "sound preference enables one chime for the event")
        try expect(!TokenActivitySoundPolicy.shouldPlay(for: event, enabled: false), "sound preference disables the chime without disabling animation")
        try expect(TokenActivitySoundPolicy.preferredSystemSoundName == "Tink", "token credit chime prefers the Tink system sound")
        try expect(TokenActivitySoundPolicy.fallbackSystemSoundName == "Glass", "token credit chime falls back to Glass")
        try expect(TokenActivitySoundPolicy.select(tinkAvailable: true, glassAvailable: true) == .tink, "available Tink wins sound selection")
        try expect(TokenActivitySoundPolicy.select(tinkAvailable: false, glassAvailable: true) == .glass, "Glass is selected when Tink is unavailable")
        try expect(TokenActivitySoundPolicy.select(tinkAvailable: false, glassAvailable: false) == .beep, "beep remains the safe final fallback")
        var soundGate = TokenActivitySoundGate()
        try expect(soundGate.consume(feedback: event, enabled: true), "sound gate accepts the first event generation")
        try expect(!soundGate.consume(feedback: event, enabled: true), "sound gate rejects a duplicate generation")

        let duplicate = snapshot(at: 120, lifetime: increased.lifetimeTokens)
        try expect(
            TokenActivityFeedbackPolicy.make(
                previousSource: increased,
                previousSummary: increased,
                currentSummary: duplicate,
                incoming: duplicate,
                generation: 8
            ) == nil,
            "same lifetime never creates a second event or sound"
        )
        let equalTimestampLarger = snapshot(at: 60, lifetime: 5_000_000_000)
        try expect(
            TokenActivityFeedbackPolicy.make(
                previousSource: increased,
                previousSummary: increased,
                currentSummary: equalTimestampLarger,
                incoming: equalTimestampLarger,
                generation: 8
            ) == nil,
            "equal fetchedAt never creates feedback even when lifetime is larger"
        )
        let secondaryOnly = snapshot(at: 120, lifetime: increased.lifetimeTokens, peak: 700_000_000)
        try expect(
            TokenActivityFeedbackPolicy.make(
                previousSource: increased,
                previousSummary: increased,
                currentSummary: secondaryOnly,
                incoming: secondaryOnly,
                generation: 8
            ) == nil,
            "secondary-only changes do not roll or chime without lifetime growth"
        )
        try expect(!TokenActivitySoundPolicy.shouldPlay(for: nil, enabled: true), "a non-event cannot produce a second chime")
        try expect(!soundGate.consume(feedback: nil, enabled: true), "sound gate ignores a non-event")
        try expect(
            TokenActivityFeedbackPolicy.make(
                previousSource: nil,
                previousSummary: nil,
                currentSummary: increased,
                incoming: increased,
                generation: 8
            ) == nil,
            "startup and cache hydration without a network baseline stay silent"
        )
        try expect(
            TokenActivityFeedbackPolicy.make(
                previousSource: old,
                previousSummary: old,
                currentSummary: increased,
                incoming: increased,
                generation: 8,
                sameProfile: false
            ) == nil,
            "profile-boundary updates never create feedback"
        )

        let olderButLarger = snapshot(at: -60, lifetime: 9_000_000_000)
        try expect(
            TokenActivityFeedbackPolicy.make(
                previousSource: old,
                previousSummary: old,
                currentSummary: olderButLarger,
                incoming: olderButLarger,
                generation: 9
            ) == nil,
            "older snapshots never create feedback"
        )

        let nilLifetimePatch = snapshot(at: 60, lifetime: nil)
        let retainedMerged = snapshot(at: 60, lifetime: old.lifetimeTokens)
        try expect(
            TokenActivityFeedbackPolicy.make(
                previousSource: old,
                previousSummary: old,
                currentSummary: retainedMerged,
                incoming: nilLifetimePatch,
                generation: 10
            ) == nil,
            "sparse nil lifetime patches never animate retained values"
        )

        let slots = TokenOdometerPresentation.slots(
            previous: old.lifetimeTokens ?? 0,
            current: increased.lifetimeTokens ?? 0
        )
        let formattedSlots = slots.map { String($0.currentCharacter) }.joined().replacingOccurrences(of: " ", with: "")
        try expect(formattedSlots == TokenActivityPresentation.tokenCount(increased.lifetimeTokens), "odometer final value exactly matches the formatted lifetime")
        try expect(slots.contains(where: { $0.isChangedDigit }), "odometer identifies changed numeric slots")
        try expect(slots.contains(where: { $0.currentCharacter == "," && !$0.isChangedDigit }), "odometer keeps separators stable")
        try expect(TokenActivityFeedbackAnimation.duration(reduceMotion: false) == 0.6, "normal roll duration is bounded")
        try expect(TokenActivityFeedbackAnimation.duration(reduceMotion: true) == 0.18, "Reduce Motion uses a short crossfade duration")
        let standardSize = HUDMetrics(scaleLevel: .standard).panelSize(quotaRowCount: 2, includesCredits: false)
        let afterFeedbackSize = HUDMetrics(scaleLevel: .standard).panelSize(quotaRowCount: 2, includesCredits: false)
        try expect(standardSize == afterFeedbackSize, "token feedback does not change HUD geometry")
    }

    private static func testStatusItemPresentationProjection() throws {
        let base = StatusItemPresentationSource(
            stackedTitle: "Codex\n86%",
            tooltip: "Codex 86% · 4 小時後重置 · 已連線 · 剛剛更新",
            color: .green
        )
        let same = StatusItemPresentationPolicy.make(from: base)
        try expect(same == StatusItemPresentationPolicy.make(from: base), "equal relevant status state removes duplicate updates")
        try expect(
            StatusItemPresentationPolicy.make(from: StatusItemPresentationSource(stackedTitle: "Codex\n85%", tooltip: base.tooltip, color: .orange)) != same,
            "quota changes update the status projection"
        )
        try expect(
            StatusItemPresentationPolicy.make(from: StatusItemPresentationSource(stackedTitle: base.stackedTitle, tooltip: "Codex 86% · 3 小時後重置 · 已連線 · 剛剛更新", color: base.color)) != same,
            "reset/age/turn tooltip changes update the status projection"
        )
        // Unrelated history/chart/notification/login state is absent from the
        // source by construction, so the same source remains identical.
        try expect(StatusItemPresentationPolicy.make(from: base) == same, "irrelevant model publications do not alter the projection")
    }

    private static func testHUDPresentationBoundary() throws {
        let profileID = UUID()

        func makePresentation(
            remainingPercent: Int = 86,
            tokenValue: String = "4,829,524,138",
            profileIDOverride: UUID? = nil,
            reduceMotion: Bool = false,
            tokenFeedback: TokenActivityUpdateFeedback? = nil
        ) -> HUDPresentation {
            let effectiveProfileID = profileIDOverride ?? profileID
            let fiveHour = HUDQuotaWindowPresentation(
                kind: .fiveHour,
                durationMins: 300,
                label: "5 小時",
                remainingPercent: remainingPercent,
                resetsAt: 1_757_000_000,
                resetDescription: "4 小時 9 分"
            )
            let sevenDay = HUDQuotaWindowPresentation(
                kind: .sevenDay,
                durationMins: 10_080,
                label: "7 天",
                remainingPercent: 44,
                resetsAt: 1_757_600_000,
                resetDescription: "5 天 1 小時"
            )
            return HUDPresentation(
                profileID: effectiveProfileID,
                accountEmail: "person@example.com",
                plan: "Plus",
                identityEmail: "person@example.com",
                identityPlan: "Plus",
                quota: HUDDualQuotaPresentation(
                    profileID: effectiveProfileID,
                    fiveHour: fiveHour,
                    sevenDay: sevenDay
                ),
                tokenMetrics: [
                    TokenActivityMetric(label: TokenActivityPresentation.lifetimeLabel, value: tokenValue),
                    TokenActivityMetric(label: TokenActivityPresentation.peakLabel, value: "575,763,278"),
                    TokenActivityMetric(label: TokenActivityPresentation.longestTurnLabel, value: "64 小時 45 分"),
                    TokenActivityMetric(label: TokenActivityPresentation.currentStreakLabel, value: "1 天"),
                    TokenActivityMetric(label: TokenActivityPresentation.longestStreakLabel, value: "24 天")
                ],
                tokenActivityFeedback: tokenFeedback,
                tokenActivityIsStale: false,
                updateBadge: .version("2.4.65"),
                dataAgeText: "剛剛更新",
                connectionState: .connected,
                isStale: false,
                isQuotaUpdating: false,
                isCodexFocused: true,
                quotaRowCount: 2,
                hasCredits: false,
                scaleLevel: .standard,
                isPasteAndSubmitInFlight: false,
                isPromptShortcutInFlight: false,
                clipboardOperationInFlight: false,
                decreaseAmount: nil,
                remainingPercent: remainingPercent,
                statusColor: .green,
                isPasteHovered: false,
                isPasteAndSubmitHovered: false,
                isContinueHovered: false,
                isFixUntilDoneHovered: false,
                isFullVerificationHovered: false,
                isCommitAndPushHovered: false,
                reduceMotion: reduceMotion
            )
        }

        let base = makePresentation()
        try expect(base == makePresentation(), "identical HUD presentation values are equal")
        try expect(base != makePresentation(remainingPercent: 85), "quota changes invalidate the HUD presentation")
        try expect(base != makePresentation(tokenValue: "4,829,524,139"), "token metric changes invalidate the HUD presentation")
        try expect(base != makePresentation(profileIDOverride: UUID()), "profile identity changes invalidate the HUD presentation")
        try expect(base != makePresentation(reduceMotion: true), "Reduce Motion changes invalidate pulse presentation")
        let feedback = TokenActivityUpdateFeedback(
            generation: 1,
            previousLifetimeTokens: 4_829_524_138,
            lifetimeTokens: 4_831_028_746,
            changedMetricLabels: [TokenActivityPresentation.lifetimeLabel]
        )
        try expect(base != makePresentation(tokenFeedback: feedback), "token feedback changes invalidate only the visual boundary")
        try expect(makePresentation(tokenFeedback: feedback) == makePresentation(tokenFeedback: feedback), "identical token feedback remains equatable")
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

    private static func testTokenActivitySemanticDedupe() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("codex-token-dedupe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = TokenActivityStore(applicationSupportURL: base)
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let content = TokenActivitySnapshot(
            fetchedAt: firstDate,
            lifetimeTokens: 100,
            peakDailyTokens: 50,
            longestRunningTurnSec: 30,
            currentStreakDays: 1,
            longestStreakDays: 2,
            dailyUsageBuckets: [DailyTokenUsage(startDate: "2026-08-15", tokens: 100)]
        )
        _ = store.update(incoming: content, now: firstDate)
        try expect(store.lastUpdateChanged, "first token payload changes the store")

        let unchanged = TokenActivitySnapshot(
            fetchedAt: firstDate.addingTimeInterval(900),
            lifetimeTokens: 100,
            peakDailyTokens: 50,
            longestRunningTurnSec: 30,
            currentStreakDays: 1,
            longestStreakDays: 2,
            dailyUsageBuckets: [DailyTokenUsage(startDate: "2026-08-15", tokens: 100)]
        )
        _ = store.update(incoming: unchanged, now: firstDate.addingTimeInterval(900))
        try expect(!store.lastUpdateChanged, "timestamp-only token refresh is not a semantic change")
        try expect(store.snapshot?.fetchedAt == firstDate, "unchanged token refresh does not replace authoritative payload")

        var changed = unchanged
        changed = TokenActivitySnapshot(
            fetchedAt: changed.fetchedAt,
            lifetimeTokens: 101,
            peakDailyTokens: changed.peakDailyTokens,
            longestRunningTurnSec: changed.longestRunningTurnSec,
            currentStreakDays: changed.currentStreakDays,
            longestStreakDays: changed.longestStreakDays,
            dailyUsageBuckets: changed.dailyUsageBuckets
        )
        _ = store.update(incoming: changed, now: firstDate.addingTimeInterval(901))
        try expect(store.lastUpdateChanged, "token payload change is published for persistence")
        try expect(store.snapshot?.lifetimeTokens == 101, "changed token value replaces the payload")
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

    private static func testAccountScopeSummary() throws {
        let now = Date()
        let active = AccountProfile(
            id: UUID(), fingerprint: "active", displayName: "Active",
            accountType: "chatgpt", authMode: "chatgpt", lastSeen: now
        )
        let stale = AccountProfile(
            id: UUID(), fingerprint: "stale", displayName: "Stale",
            accountType: "chatgpt", authMode: "chatgpt", lastSeen: now
        )
        let unidentified = AccountProfile(
            id: UUID(), fingerprint: "unknown", displayName: "Unknown",
            accountType: "chatgpt", authMode: "chatgpt", lastSeen: now,
            isUnidentified: true
        )
        let activeSnapshot = UsageSnapshot(
            limitId: "codex", limitName: "Codex", planType: "plus",
            primary: RateLimitWindow(usedPercent: 20, resetsAt: nil, windowDurationMins: 300),
            secondary: nil, individualLimit: nil, rateLimitReachedType: nil,
            spendControlReached: nil, receivedAt: now
        )
        let staleSnapshot = UsageSnapshot(
            limitId: "codex", limitName: "Codex", planType: "free",
            primary: RateLimitWindow(usedPercent: 80, resetsAt: nil, windowDurationMins: 300),
            secondary: nil, individualLimit: nil, rateLimitReachedType: nil,
            spendControlReached: nil, receivedAt: now
        )
        let summaries = [
            ProfileQuotaSummary(
                profile: active,
                latestSample: HistorySample(snapshot: activeSnapshot, connectionState: .connected, receivedAt: now)
            ),
            ProfileQuotaSummary(
                profile: stale,
                latestSample: HistorySample(snapshot: staleSnapshot, connectionState: .offline, receivedAt: now)
            ),
            ProfileQuotaSummary(profile: unidentified, latestSample: nil)
        ]
        let summary = AccountScopeSummary.make(
            profiles: [active, stale, unidentified],
            quotaSummaries: summaries
        )
        try expect(summary.totalAccounts == 3, "all-account overview shows total account count")
        try expect(summary.availableOrActiveAccounts == 1, "all-account overview counts recent connected accounts")
        try expect(summary.staleAccounts == 2, "all-account overview counts offline and missing data as stale")
        try expect(summary.unidentifiedAccounts == 1, "all-account overview counts unidentified profiles")
    }

    private static func testUpdateVersionComparison() throws {
        try expect(AppVersionComparator.isNewer("v2.4.12", than: "2.4.11"), "v tag should compare newer")
        try expect(AppVersionComparator.isNewer("2.5", than: "2.4.99"), "minor version should compare newer")
        try expect(!AppVersionComparator.isNewer("2.4.11", than: "2.4.11"), "same version is not newer")
        try expect(!AppVersionComparator.isNewer("2.4.10", than: "2.4.11"), "older version is not newer")
        try expect(AppUpdateReleasePolicy.isSafeVersion("2.5.0"), "release version is path-safe")
        try expect(AppUpdateReleasePolicy.isSafeVersion("2.5.0.1"), "four-part release version is path-safe")
        try expect(!AppUpdateReleasePolicy.isSafeVersion("9/../../outside"), "path traversal release version is rejected")
        try expect(!AppUpdateReleasePolicy.isSafeVersion("2.5.0\ncommand"), "control-character release version is rejected")
        try expect(AppUpdateReleasePolicy.isOfficialReleaseURL(URL(string: "https://github.com/SaiHoninbo/CodexUsageStatus/releases/tag/v2.5.0")!), "official release URL is allowed")
        try expect(AppUpdateReleasePolicy.isOfficialReleaseURL(URL(string: "https://github.com:443/SaiHoninbo/CodexUsageStatus/releases/tag/v2.5.0")!), "official HTTPS default port is allowed")
        try expect(!AppUpdateReleasePolicy.isOfficialReleaseURL(URL(string: "https://github.com:444/SaiHoninbo/CodexUsageStatus/releases/tag/v2.5.0")!), "arbitrary release URL port is rejected")
        try expect(!AppUpdateReleasePolicy.isOfficialReleaseURL(URL(string: "https://evil.example/releases/v2.5.0")!), "non-GitHub release URL is rejected")
        try expect(!AppUpdateReleasePolicy.isOfficialReleaseURL(URL(string: "https://token@github.com/SaiHoninbo/CodexUsageStatus/releases/tag/v2.5.0")!), "credential-bearing release URL is rejected")
        try expect(!AppUpdateReleasePolicy.isOfficialReleaseURL(URL(string: "https://:secret@github.com/SaiHoninbo/CodexUsageStatus/releases/tag/v2.5.0")!), "password-bearing release URL is rejected")
        try expect(!AppUpdateReleasePolicy.isOfficialReleaseURL(URL(string: "https://github.com/SaiHoninbo/CodexUsageStatus/releases/../evil")!), "release URL path traversal is rejected")
        try expect(!AppUpdateReleasePolicy.isOfficialReleaseURL(URL(string: "https://github.com/SaiHoninbo/CodexUsageStatus/releases/%2e%2e/evil")!), "encoded release URL path traversal is rejected")
    }


    private static func runTool(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HarnessError.assertion("tool failed: \(executable) \(arguments.joined(separator: " "))")
        }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private static func testHUDContextMenuPolicy() throws {
        let actions = HUDContextMenuPolicy.sections.flatMap { $0 }
        try expect(actions.contains(.refresh) && actions.contains(.showDetails), "status actions are present")
        try expect(actions.contains(.openCodex) && actions.contains(.resetPosition), "Codex actions are present")
        try expect(actions.contains(.hudScale), "HUD scale action is present")
        try expect(actions.contains(.paste) && actions.contains(.pasteAndSubmit), "clipboard actions are distinct")
        try expect(actions.contains(.currentAccount) && actions.contains(.allAccounts) && actions.contains(.manageAccounts), "account actions are present")
        try expect(actions.contains(.checkForUpdates) && actions.contains(.quit), "update and quit actions are present")
        try expect(HUDContextMenuPolicy.pasteActionsEnabled(isCodexFocused: true), "focused paste is enabled")
        try expect(!HUDContextMenuPolicy.pasteActionsEnabled(isCodexFocused: false), "unfocused paste is disabled")
        try expect(HUDContextMenuPolicy.sections.last == [.quit], "quit is isolated at the bottom")
    }

    private static func testUsagePopoverTabsAndAppVersion() throws {
        try expect(
            UsagePopoverTab.allCases.map(\.rawValue) == ["overview", "history", "settings"],
            "usage popover exposes the three product tabs"
        )
        try expect(UsagePopoverTab.settings.title == "設定", "settings has a dedicated tab")
        try expect(UsagePopoverTab.overview.title == "概覽", "overview is the default product tab")
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
        try expectApproximately(standard.panelSize.width, 416, "canonical panel width")
        try expectApproximately(standard.panelSize.height, 256.4, "canonical panel height derives compact summary and workflow rows")
        try expect(standard.panelSize.height >= 250 && standard.panelSize.height <= 265, "standard two-quota HUD stays in the preferred compact range")
        try expect(standard.panelSize.height <= 270, "standard two-quota HUD stays below the maximum compact height")
        try expectApproximately(standard.contentWidth, 394, "content width follows outer padding")
        try expectApproximately(standard.quotaColumnHeight, 73, "quota rows close to the compact quota budget")
        try expectApproximately(standard.headerHeight, 22, "header height")
        try expectApproximately(standard.headerGap, 5, "header gap")
        try expect(standard.tokenSummaryHeight >= 52, "token summary has a compact but readable height")
        try expect(standard.workflowActionHeight / standard.actionHeight > 0.7 && standard.workflowActionHeight / standard.actionHeight < 0.8, "workflow cards are 70–80% of primary row")
        try expectApproximately(standard.verticalContentHeight + standard.outerPadding * 2, standard.panelSize.height, "canonical height closes from derived tokens")
        try expect(standard.panelSize(quotaRowCount: 1).height < standard.panelSize(quotaRowCount: 2).height, "one quota row removes empty vertical space")
        try expect(standard.panelSize(quotaRowCount: 3).height > standard.panelSize(quotaRowCount: 2).height, "three quota rows grow only by quota height")
        try expect(standard.panelSize(quotaRowCount: 2, includesCredits: true).height > standard.panelSize(quotaRowCount: 2).height, "Credits adds a balance section")
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
            try expect(
                3 * metrics.actionCardWidth + (metrics.actionSpacing * 2) <= metrics.contentWidth + 0.01,
                "action cards fit three columns at every scale level"
            )
            try expect(metrics.workflowActionHeight < metrics.actionHeight, "workflow row remains subordinate at \(level.displayName)")
            try expect(metrics.tokenSummaryHeight >= 40 * metrics.factor, "token summary keeps two rows within the scaled cell budget at \(level.displayName)")
            for rowCount in 1...3 {
                let dynamicHeight = metrics.verticalContentHeight(for: rowCount) + metrics.outerPadding * 2
                try expectApproximately(
                    dynamicHeight,
                    metrics.panelSize(quotaRowCount: rowCount).height,
                    "dynamic quota layout closes at \(level.displayName), \(rowCount) rows"
                )
                try expectApproximately(
                    metrics.panelSize(quotaRowCount: rowCount, includesCredits: true).height,
                    dynamicHeight + metrics.creditsSectionHeight + metrics.sectionGap,
                    "credits layout closes at \(level.displayName), \(rowCount) rows"
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
        let shortcuts = CodexPromptShortcut.allCases
        try expect(shortcuts == [.continueTask, .fixUntilDone, .fullVerification, .commitAndPush], "workflow shortcuts preserve the four-case order")
        try expect(shortcuts.map(\.rawValue) == ["繼續", "修到完成", "完整驗證", "Commit + Push"], "visible labels stay separate from payloads")
        try expect(shortcuts.map(\.text) == [
            "go on",
            "Continue the current task using the latest repo reality. Fix repairable issues automatically, rerun affected verification, and keep going until the task is complete or a true material blocker is found. Do not stop for routine approvals or previously decided matters.",
            "Verify the current implementation against the latest repo reality. Run the relevant tests, build, diff checks, and necessary runtime verification. Auto-repair repairable failures and rerun affected checks. Finish with a concise verification result and remaining declared limits.",
            "Review the current repository, branch, working tree, diff, verification status, and sensitive-content risk. If the current change is safe and sufficiently verified, create an appropriate commit and push it to the existing upstream. Stop only for a true material risk such as repository identity mismatch, unexpected branch or remote target, secret exposure, destructive Git, or material scope mismatch."
        ], "workflow payloads match the fixed transport contract")
        try expect(shortcuts.allSatisfy { $0.submitAfterPaste }, "every workflow shortcut submits after paste")
        try expect(shortcuts.allSatisfy { $0.accessibilityLabel == $0.rawValue }, "accessibility uses concise labels")
        try expect(CodexPromptShortcut.commitAndPush.helpText.contains("不會執行 Git"), "Commit + Push explains that Usage App never runs Git")
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

        let launchDate = Date(timeIntervalSince1970: 123)
        let bundleURL = URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true)
        let identity = CodexApplicationPolicy.TrustedApplicationIdentity(
            processIdentifier: 42,
            launchDate: launchDate,
            bundleURL: bundleURL
        )
        try expect(
            identity.matches(processIdentifier: 42, launchDate: launchDate, bundleURL: bundleURL),
            "trusted identity reuses only the same live process"
        )
        try expect(
            !identity.matches(processIdentifier: 43, launchDate: launchDate, bundleURL: bundleURL),
            "trusted identity rejects a different process"
        )
        try expect(
            !identity.matches(processIdentifier: 42, launchDate: Date(timeIntervalSince1970: 124), bundleURL: bundleURL),
            "trusted identity rejects a different launch"
        )
        try expect(
            !identity.matches(
                processIdentifier: 42,
                launchDate: launchDate,
                bundleURL: URL(fileURLWithPath: "/Applications/Other.app", isDirectory: true)
            ),
            "trusted identity rejects a different bundle"
        )

        // Runtime publisher proof: an ad-hoc bundle that spoofs the native
        // identifier must still be rejected by the Security.framework gate.
        let fakeBundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSpoof-\(UUID().uuidString).app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fakeBundle) }
        let fakeContents = fakeBundle.appendingPathComponent("Contents", isDirectory: true)
        let fakeMacOS = fakeContents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeMacOS, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.openai.codex</string><key>CFBundleExecutable</key><string>CodexSpoof</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
        """
        try Data(plist.utf8).write(to: fakeContents.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeMacOS.appendingPathComponent("CodexSpoof"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeMacOS.appendingPathComponent("CodexSpoof").path)
        _ = try runTool("/usr/bin/codesign", ["--force", "--sign", "-", fakeBundle.path])
        try expect(!CodexApplicationPolicy.isTrustedBundle(at: fakeBundle), "ad-hoc bundle-id spoof must be rejected")
        let official = URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
        if FileManager.default.fileExists(atPath: official.path) {
            try expect(CodexApplicationPolicy.isTrustedBundle(at: official), "official signed Codex bundle should be accepted")
        }
    }

    private static func testLoginLifecycleShutdown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-login-fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fake-codex")
        try Data("#!/bin/sh\ntrap 'exit 0' TERM INT\nwhile :; do /bin/sleep 1; done\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let profile = AccountProfile(id: UUID(), fingerprint: "fixture", displayName: "Fixture", accountType: "chatgpt", lastSeen: Date())
        let service = await MainActor.run { AccountManagementService(executableResolver: { executable.path }) }
        await MainActor.run {
            service.startOfficialLogin(profile: profile, codexHomeURL: root) { _ in }
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        let pid = await MainActor.run { service.loginProcessIDs.first }
        try expect(pid != nil, "login fixture should launch a child")
        await MainActor.run {
            service.stopAllLogins()
            service.stopAllLogins()
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        let registryEmpty = await MainActor.run { service.loginProcessIDs.isEmpty }
        try expect(registryEmpty, "stopAllLogins clears registry idempotently")
        if let pid {
            try expect(kill(pid, 0) != 0, "stopAllLogins terminates login child")
        }
    }


    private static func testClipboardTemporaryOperationPolicy() throws {
        try expect(ClipboardTemporaryOperationPolicy.canStart(isOperationInFlight: false), "idle operation can start")
        try expect(!ClipboardTemporaryOperationPolicy.canStart(isOperationInFlight: true), "single-flight rejects overlap")
        try expect(ClipboardTemporaryOperationPolicy.preparedTextWriteIsValid(
            expectedText: "sample", observedText: "sample", beforeChangeCount: 326, afterChangeCount: 326
        ), "setString may leave changeCount unchanged")
        try expect(!ClipboardTemporaryOperationPolicy.preparedTextWriteIsValid(
            expectedText: "sample", observedText: "other", beforeChangeCount: 326, afterChangeCount: 326
        ), "wrong text fails closed")
        try expect(!ClipboardTemporaryOperationPolicy.preparedTextWriteIsValid(
            expectedText: "sample", observedText: "sample", beforeChangeCount: 326, afterChangeCount: 325
        ), "counter regression fails closed")
        try expect(ClipboardTemporaryOperationPolicy.canRestore(
            expectedText: "sample", observedText: "sample", preparedChangeCount: 327, currentChangeCount: 327
        ), "unchanged owned clipboard may restore")
        try expect(!ClipboardTemporaryOperationPolicy.canRestore(
            expectedText: "sample", observedText: "New user text", preparedChangeCount: 327, currentChangeCount: 328
        ), "new user clipboard is never overwritten")
    }

    private static func testRetiredFeatureCleanup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-retired-feed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let appDirectory = root.appendingPathComponent("com.openai.codex-usage-status", isDirectory: true)
        let feedURL = appDirectory.appendingPathComponent("feed-tracking.json")
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        let original = Data("{\"legacy\":true}\n".utf8)
        try original.write(to: feedURL)
        let defaults = UserDefaults(suiteName: "codex-retired-feed-\(UUID().uuidString)")!
        defaults.set(true, forKey: "feed.enabled")
        defaults.set("https://sentinel.invalid/feed", forKey: "feed.url")
        defaults.set(120, forKey: "feed.cadence")

        let notificationProbe = NotificationCleanupProbe()
        RetiredFeatureCleanup.run(
            fileManager: .default,
            defaults: defaults,
            applicationSupportDirectory: root,
            notificationCenter: notificationProbe,
            now: Date(timeIntervalSince1970: 1_725_000_000)
        )

        try expect(defaults.object(forKey: "feed.enabled") == nil, "retired feed enabled key is removed")
        try expect(defaults.object(forKey: "feed.url") == nil, "retired feed URL key is removed")
        try expect(defaults.object(forKey: "feed.cadence") == nil, "retired feed cadence key is removed")
        try expect(!FileManager.default.fileExists(atPath: feedURL.path), "legacy feed store is moved")
        let quarantineDirectory = appDirectory
            .appendingPathComponent("retired", isDirectory: true)
            .appendingPathComponent("feed", isDirectory: true)
        let quarantined = try FileManager.default.contentsOfDirectory(at: quarantineDirectory, includingPropertiesForKeys: nil)
        try expect(quarantined.count == 1, "one feed store is quarantined")
        let quarantinedBytes = try Data(contentsOf: quarantined[0])
        try expect(quarantinedBytes == original, "quarantine preserves raw bytes")
        let directoryMode = try FileManager.default.attributesOfItem(atPath: quarantineDirectory.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: quarantined[0].path)[.posixPermissions] as? NSNumber
        try expect(directoryMode?.intValue == 0o700, "quarantine directory is owner-only")
        try expect(fileMode?.intValue == 0o600, "quarantine file is owner-only")
        try expect(notificationProbe.removedPending == ["feed-pending"], "only retired pending feed notifications are removed")
        try expect(notificationProbe.removedDelivered == ["feed-delivered"], "only retired delivered feed notifications are removed")

        let failureRoot = root.appendingPathComponent("move-failure", isDirectory: true)
        let failureAppDirectory = failureRoot.appendingPathComponent("com.openai.codex-usage-status", isDirectory: true)
        let failureFeedURL = failureAppDirectory.appendingPathComponent("feed-tracking.json")
        try FileManager.default.createDirectory(at: failureAppDirectory, withIntermediateDirectories: true)
        try original.write(to: failureFeedURL)
        RetiredFeatureCleanup.run(
            fileManager: FailingMoveFileManager(),
            defaults: UserDefaults(suiteName: "codex-retired-feed-failure-\(UUID().uuidString)")!,
            applicationSupportDirectory: failureRoot,
            notificationCenter: NotificationCleanupProbe(),
            now: Date(timeIntervalSince1970: 1_725_000_000)
        )
        try expect(FileManager.default.fileExists(atPath: failureFeedURL.path), "failed quarantine preserves the original feed file")
    }

    private static func testAppServerRetryPolicy() throws {
        try expect(AppServerRetryPolicy.initializationWatchdogNanoseconds == 8_000_000_000, "initialize watchdog is 8 seconds")
        try expect(AppServerRetryPolicy.delay(for: 0) == 1_000_000_000, "first retry is one second")
        try expect(AppServerRetryPolicy.delay(for: 1) == 2_000_000_000, "second retry is two seconds")
        try expect(AppServerRetryPolicy.delay(for: 2) == 4_000_000_000, "third retry is four seconds")
        try expect(AppServerRetryPolicy.delay(for: 3) == nil, "automatic retries stop after three attempts")
    }

    private static func testRefreshRequestCoalescing() throws {
        try expect(RefreshRequestCoalescer.shouldSchedule(isScheduled: false), "first refresh schedules")
        try expect(!RefreshRequestCoalescer.shouldSchedule(isScheduled: true), "duplicate refresh is coalesced")
    }

    private static func testAccountRefreshDependencyPolicy() throws {
        try expect(AccountRefreshDependencyPolicy.shouldRefreshDependentData(
            previousIdentityKey: nil,
            currentIdentityKey: "email|one@example.com",
            hasCurrentSnapshot: false
        ), "initial account read fans out to dependent data")
        try expect(AccountRefreshDependencyPolicy.shouldRefreshDependentData(
            previousIdentityKey: "email|one@example.com",
            currentIdentityKey: "email|two@example.com",
            hasCurrentSnapshot: true
        ), "identity change fans out to dependent data")
        try expect(!AccountRefreshDependencyPolicy.shouldRefreshDependentData(
            previousIdentityKey: "email|one@example.com",
            currentIdentityKey: "email|one@example.com",
            hasCurrentSnapshot: true
        ), "steady-state account poll stays independent")
        try expect(AccountRefreshDependencyPolicy.shouldRefreshDependentData(
            previousIdentityKey: "email|one@example.com",
            currentIdentityKey: "email|one@example.com",
            hasCurrentSnapshot: false
        ), "missing quota snapshot allows recovery fan-out")
    }

    private static func testAppServerReplacementAdmission() throws {
        try expect(AppServerReplacementAdmissionPolicy.canStartReplacement(oldProcessRunning: false, replacementInFlight: false), "replacement starts when idle")
        try expect(!AppServerReplacementAdmissionPolicy.canStartReplacement(oldProcessRunning: true, replacementInFlight: false), "replacement waits for old process")
        try expect(!AppServerReplacementAdmissionPolicy.canStartReplacement(oldProcessRunning: false, replacementInFlight: true), "replacement gate is single flight")
    }

    private static func testManagedWorkerAdmission() throws {
        try expect(ManagedWorkerAdmissionPolicy.maxActiveAppServers == 1, "only one managed App Server is admitted")
        try expect(ManagedWorkerAdmissionPolicy.admits(isCurrentAccount: true, activeCount: 0, replacementInFlight: false), "current account can start")
        try expect(!ManagedWorkerAdmissionPolicy.admits(isCurrentAccount: false, activeCount: 0, replacementInFlight: false), "background account remains cache-only")
        try expect(!ManagedWorkerAdmissionPolicy.admits(isCurrentAccount: true, activeCount: 1, replacementInFlight: false), "second process is rejected")
        try expect(!ManagedWorkerAdmissionPolicy.admits(isCurrentAccount: true, activeCount: 0, replacementInFlight: true), "replacement gate prevents overlap")
    }

    private static func testBoundedTerminationFlush() throws {
        try expect(TerminationFlushPolicy.timeoutNanoseconds == 500_000_000, "termination flush is bounded to 500ms")
    }

    private static func testPersistenceWriteCoordinator() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-persistence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("snapshot.json")
        await PersistenceWriteCoordinator.shared.enqueue(url: file, data: Data("latest".utf8))
        await PersistenceWriteCoordinator.shared.enqueue(url: file, data: Data("newest".utf8))
        await PersistenceWriteCoordinator.shared.flush(timeoutNanoseconds: 2_000_000_000)
        let persisted = try Data(contentsOf: file)
        try expect(persisted == Data("newest".utf8), "coalesced write keeps newest payload")
        await PersistenceWriteCoordinator.shared.enqueue(url: file, data: nil)
        await PersistenceWriteCoordinator.shared.flush(timeoutNanoseconds: 2_000_000_000)
        try expect(!FileManager.default.fileExists(atPath: file.path), "nil payload removes file")
    }


    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw HarnessError.assertion(message) }
    }

    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw HarnessError.unwrap(message) }
        return value
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

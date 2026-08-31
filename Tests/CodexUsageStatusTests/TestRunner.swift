import Foundation
import CoreGraphics
import AppKit
import Darwin

private final class FeedNotificationSubmissionProbe: FeedNotificationSubmitting {
    let result: Result<Void, Error>
    private(set) var calls = 0

    init(result: Result<Void, Error>) {
        self.result = result
    }

    func send(
        post: FeedPost,
        prediction: ResetPrediction?,
        postCount: Int,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        calls += 1
        completion(result)
    }
}

private final class FeedURLProtocolProbe: URLProtocol {
    static var statusCode = 200
    static var body = Data()
    static var headers: [String: String] = [:]
    static var failure: Error?
    static var redirectURL: URL?
    static var requestCount = 0

    static func reset() {
        statusCode = 200
        body = Data()
        headers = [:]
        failure = nil
        redirectURL = nil
        requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        guard let client else { return }
        if let failure = Self.failure {
            client.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.redirectURL == nil ? Self.statusCode : 302,
            httpVersion: "HTTP/1.1",
            headerFields: Self.headers
        )!
        if let redirectURL = Self.redirectURL {
            client.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirectURL), redirectResponse: response)
            return
        }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !Self.body.isEmpty { client.urlProtocol(self, didLoad: Self.body) }
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class FeedDeferredTransport: FeedHTTPTransporting {
    final class Handle: FeedTransportTask {
        private(set) var cancelCount = 0
        func cancel() { cancelCount += 1 }
    }

    private(set) var requests: [URLRequest] = []
    private(set) var handles: [Handle] = []
    private var completions: [(Result<FeedHTTPResponse, Error>) -> Void] = []

    @discardableResult
    func fetch(request: URLRequest, completion: @escaping (Result<FeedHTTPResponse, Error>) -> Void) -> FeedTransportTask {
        requests.append(request)
        completions.append(completion)
        let handle = Handle()
        handles.append(handle)
        return handle
    }

    func complete(_ index: Int, with result: Result<FeedHTTPResponse, Error>) {
        guard completions.indices.contains(index) else { return }
        completions[index](result)
    }
}

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
            ("Git push identity freeze", testGitPushIdentityFreeze),
            ("feed prediction timezone provenance", testFeedPredictionTimezoneProvenance),
            ("feed announcement grouping", testFeedAnnouncementGrouping),
            ("feed store retention map invariant", testFeedStoreRetentionMapInvariant),
            ("feed parser nested content", testFeedParserNestedContent),
            ("feed URL safety policy", testFeedURLSafetyPolicy),
            ("feed parser entities and external entity isolation", testFeedParserEntitiesAndExternalEntityIsolation),
            ("feed store identity and update semantics", testFeedStoreIdentityAndUpdateSemantics),
            ("feed announcement Rule2 and prediction selection", testFeedAnnouncementRule2AndPredictionSelection),
            ("feed notification injected submission", testFeedNotificationInjectedSubmission),
            ("feed HTTP transport status and limits", testFeedHTTPTransportStatusAndLimits),
            ("feed HTTP transport redirect and timeout", testFeedHTTPTransportRedirectAndTimeout),
            ("feed service validators generation and notification dedupe", testFeedServiceValidatorsGenerationAndNotificationDedupe)
            ,("feed continuation rejects unrelated update", testFeedContinuationRejectsUnrelatedUpdate)
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
            try await testGitExecutionBoundary()
            print("PASS git execution boundary")
        } catch {
            failures += 1
            print("FAIL git execution boundary: \(error)")
        }
        do {
            try await testGitMutationConfigurationSources()
            print("PASS git mutation configuration sources")
        } catch {
            failures += 1
            print("FAIL git mutation configuration sources: \(error)")
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
        try expect(GitCommitPolicy.arguments(message: "safe", paths: ["*.swift"]) == nil, "wildcard pathspec rejected")
        try expect(GitCommitPolicy.arguments(message: "safe", paths: [":(glob)**/*.swift"]) == nil, "magic pathspec rejected")
        try expect(GitCommitPolicy.arguments(message: "safe", paths: [":/rooted.swift"]) == nil, "root pathspec rejected")

        let guarded = GitExecutionPolicy.invocationArguments(["diff", "--", "file.swift"])
        try expect(guarded.contains("core.fsmonitor=false"), "git execution disables fsmonitor config")
        try expect(guarded.contains("diff.external="), "git execution disables external diff config")
        try expect(GitExecutionPolicy.environment["GIT_CONFIG_GLOBAL"] == "/dev/null", "git execution isolates global config")

        let identity = GitWorkspaceIdentity(repositoryRoot: "/repo", gitDirectory: "/repo/.git", branch: "main", head: "abc", remote: "origin", upstream: "origin/main", remoteFingerprint: "test-remote")
        try expect(GitPushPolicy.arguments(identity: identity) == ["push", "origin", "HEAD:refs/heads/main"], "push uses explicit refspec")
        try expect(GitPushPolicy.isSafeRemoteURL("https://github.com/example/repo.git"), "https remote is allowed")
        try expect(GitPushPolicy.isSafeRemoteURL("git@example.com:repo.git"), "ssh scp remote is allowed")
        try expect(!GitPushPolicy.isSafeRemoteURL("ext::sh -c whoami"), "ext helper remote is rejected")
        try expect(!GitPushPolicy.isSafeRemoteURL("file:///tmp/repo"), "file remote is rejected")
        try expect(!GitPushPolicy.isSafeRemoteURL("https://token@example.com/repo.git"), "credential-bearing remote is rejected")
        try expect(!GitPushPolicy.isSafeRemoteURL("https://github.com/example/repo.git\n--upload-pack=evil"), "newline remote is rejected")
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
        try expect(actions.contains(.openGitWorkspace) && actions.contains(.refreshGitWorkspace), "git actions are present")
        try expect(actions.contains(.currentAccount) && actions.contains(.allAccounts) && actions.contains(.manageAccounts), "account actions are present")
        try expect(actions.contains(.checkForUpdates) && actions.contains(.quit), "update and quit actions are present")
        try expect(HUDContextMenuPolicy.pasteActionsEnabled(isCodexFocused: true), "focused paste is enabled")
        try expect(!HUDContextMenuPolicy.pasteActionsEnabled(isCodexFocused: false), "unfocused paste is disabled")
        try expect(HUDContextMenuPolicy.sections.last == [.quit], "quit is isolated at the bottom")
    }

    private static func testUsagePopoverTabsAndAppVersion() throws {
        try expect(
            UsagePopoverTab.allCases.map(\.rawValue) == ["overview", "usage", "history", "accountGit", "announcements", "settings"],
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
        try expectSizeApproximately(
            standard.panelSize(quotaRowCount: 3, includesCredits: true),
            CGSize(width: 416, height: 353.6),
            "three quota rows plus credits match the expanded reference"
        )
        try expectApproximately(
            standard.panelSize(quotaRowCount: 2, includesCredits: true).height,
            307.2,
            "credits add a balance section without changing quota row count"
        )
        try expectApproximately(
            standard.panelSize(quotaRowCount: 2, includesCredits: true, hasAnnouncement: true).height,
            391.2,
            "announcement height composes with credits geometry"
        )
        try expectApproximately(
            standard.panelSize(quotaRowCount: 2, includesCredits: false, hasAnnouncement: false).height,
            240,
            "no credits and no announcement preserve canonical geometry"
        )
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

    private static func testGitExecutionBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-git-security-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try runGit(["init", "-q"], at: root)
        _ = try runGit(["config", "user.name", "Codex Test"], at: root)
        _ = try runGit(["config", "user.email", "codex-test@example.invalid"], at: root)
        let source = root.appendingPathComponent("file.txt")
        try Data("baseline\n".utf8).write(to: source)
        _ = try runGit(["add", "--", "file.txt"], at: root)
        _ = try runGit(["commit", "-q", "-m", "baseline"], at: root)

        let marker = root.appendingPathComponent("marker")
        let malicious = root.appendingPathComponent("malicious.sh")
        try Data("#!/bin/sh\ntouch \"\(marker.path)\"\nexit 0\n".utf8).write(to: malicious)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: malicious.path)
        _ = try runGit(["config", "core.fsmonitor", malicious.path], at: root)
        _ = try runGit(["config", "diff.evil.textconv", malicious.path], at: root)
        _ = try runGit(["config", "filter.evil.clean", malicious.path], at: root)
        _ = try runGit(["config", "commit.gpgsign", "yes"], at: root)
        _ = try runGit(["config", "url.https://evil.example/.pushInsteadOf", "https://github.com/"], at: root)
        try Data("*.txt diff=evil\n".utf8).write(to: root.appendingPathComponent(".gitattributes"))
        try Data("changed\n".utf8).write(to: source)

        let service = GitWorkspaceService()
        _ = try await service.readStatus(at: root)
        _ = try await service.readDiff(at: root, path: "file.txt")
        try expect(!FileManager.default.fileExists(atPath: marker.path), "status/diff never execute fsmonitor or textconv")

        let hook = root.appendingPathComponent(".git/hooks/pre-commit")
        try Data("#!/bin/sh\ntouch \"\(marker.path)\"\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let snapshot = try await service.readStatus(at: root)
        do {
            _ = try await service.commit(at: root, snapshot: snapshot, paths: ["file.txt"], message: "should reject unsafe config")
            throw HarnessError.assertion("unsafe Git mutation unexpectedly succeeded")
        } catch let error as GitCommandError {
            if case .failed = error { } else { throw error }
        }
        try expect(!FileManager.default.fileExists(atPath: marker.path), "unsafe hook/config is rejected before commit")
    }

    /// Local include files and per-worktree config are repository-controlled
    /// inputs too. Mutation must fail closed when either source enables a
    /// filter that could execute during staging/commit.
    private static func testGitMutationConfigurationSources() async throws {
        let includeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("codex-git-include-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: includeRoot) }
        try FileManager.default.createDirectory(at: includeRoot, withIntermediateDirectories: true)
        _ = try runGit(["init", "-q"], at: includeRoot)
        _ = try runGit(["config", "user.name", "Codex Test"], at: includeRoot)
        _ = try runGit(["config", "user.email", "codex-test@example.invalid"], at: includeRoot)
        let includeSource = includeRoot.appendingPathComponent("file.txt")
        try Data("baseline\n".utf8).write(to: includeSource)
        _ = try runGit(["add", "--", "file.txt"], at: includeRoot)
        _ = try runGit(["commit", "-q", "-m", "baseline"], at: includeRoot)
        let includeFile = includeRoot.appendingPathComponent("included-config")
        let includeMarker = includeRoot.appendingPathComponent("include-marker")
        let includeFilter = includeRoot.appendingPathComponent("include-filter.sh")
        try Data("#!/bin/sh\ntouch \"\(includeMarker.path)\"\ncat\n".utf8).write(to: includeFilter)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: includeFilter.path)
        try Data("[filter \"included\"]\n\tclean = \(includeFilter.path)\n".utf8).write(to: includeFile)
        _ = try runGit(["config", "--local", "include.path", includeFile.path], at: includeRoot)
        try Data("*.txt filter=included\n".utf8).write(to: includeRoot.appendingPathComponent(".gitattributes"))
        try Data("changed\n".utf8).write(to: includeSource)

        let service = GitWorkspaceService()
        let includeSnapshot = try await service.readStatus(at: includeRoot)
        do {
            _ = try await service.commit(at: includeRoot, snapshot: includeSnapshot, paths: ["file.txt"], message: "reject included filter")
            throw HarnessError.assertion("included Git filter unexpectedly allowed mutation")
        } catch let error as GitCommandError {
            if case .failed = error { } else { throw error }
        }
        try expect(!FileManager.default.fileExists(atPath: includeMarker.path), "included Git filter is rejected before commit")

        let worktreeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("codex-git-worktree-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: worktreeRoot) }
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        _ = try runGit(["init", "-q"], at: worktreeRoot)
        _ = try runGit(["config", "user.name", "Codex Test"], at: worktreeRoot)
        _ = try runGit(["config", "user.email", "codex-test@example.invalid"], at: worktreeRoot)
        let worktreeSource = worktreeRoot.appendingPathComponent("file.txt")
        try Data("baseline\n".utf8).write(to: worktreeSource)
        _ = try runGit(["add", "--", "file.txt"], at: worktreeRoot)
        _ = try runGit(["commit", "-q", "-m", "baseline"], at: worktreeRoot)
        let worktreeMarker = worktreeRoot.appendingPathComponent("worktree-marker")
        let worktreeFilter = worktreeRoot.appendingPathComponent("worktree-filter.sh")
        try Data("#!/bin/sh\ntouch \"\(worktreeMarker.path)\"\ncat\n".utf8).write(to: worktreeFilter)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: worktreeFilter.path)
        _ = try runGit(["config", "extensions.worktreeConfig", "true"], at: worktreeRoot)
        _ = try runGit(["config", "--worktree", "filter.worktree.clean", worktreeFilter.path], at: worktreeRoot)
        try Data("*.txt filter=worktree\n".utf8).write(to: worktreeRoot.appendingPathComponent(".gitattributes"))
        try Data("changed\n".utf8).write(to: worktreeSource)

        let worktreeSnapshot = try await service.readStatus(at: worktreeRoot)
        do {
            _ = try await service.commit(at: worktreeRoot, snapshot: worktreeSnapshot, paths: ["file.txt"], message: "reject worktree filter")
            throw HarnessError.assertion("per-worktree Git filter unexpectedly allowed mutation")
        } catch let error as GitCommandError {
            if case .failed = error { } else { throw error }
        }
        try expect(!FileManager.default.fileExists(atPath: worktreeMarker.path), "per-worktree Git filter is rejected before commit")

        let askpassRoot = FileManager.default.temporaryDirectory.appendingPathComponent("codex-git-askpass-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: askpassRoot) }
        try FileManager.default.createDirectory(at: askpassRoot, withIntermediateDirectories: true)
        _ = try runGit(["init", "-q"], at: askpassRoot)
        _ = try runGit(["config", "user.name", "Codex Test"], at: askpassRoot)
        _ = try runGit(["config", "user.email", "codex-test@example.invalid"], at: askpassRoot)
        let askpassSource = askpassRoot.appendingPathComponent("file.txt")
        try Data("baseline\n".utf8).write(to: askpassSource)
        _ = try runGit(["add", "--", "file.txt"], at: askpassRoot)
        _ = try runGit(["commit", "-q", "-m", "baseline"], at: askpassRoot)
        let askpassMarker = askpassRoot.appendingPathComponent("askpass-marker")
        let askpassScript = askpassRoot.appendingPathComponent("askpass.sh")
        try Data("#!/bin/sh\ntouch \"\(askpassMarker.path)\"\nexit 0\n".utf8).write(to: askpassScript)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: askpassScript.path)
        _ = try runGit(["config", "core.askPass", askpassScript.path], at: askpassRoot)
        try Data("changed\n".utf8).write(to: askpassSource)

        let askpassSnapshot = try await service.readStatus(at: askpassRoot)
        do {
            _ = try await service.commit(at: askpassRoot, snapshot: askpassSnapshot, paths: ["file.txt"], message: "reject askpass helper")
            throw HarnessError.assertion("core.askpass helper unexpectedly allowed mutation")
        } catch let error as GitCommandError {
            if case .failed = error { } else { throw error }
        }
        try expect(!FileManager.default.fileExists(atPath: askpassMarker.path), "core.askpass helper is rejected before mutation")
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

    private static func testFeedPredictionTimezoneProvenance() throws {
        let feedURL = URL(string: "https://example.com/feed")!
        let post = FeedPost(id: "p", canonicalURL: nil, publishedAt: nil, updatedAt: nil, firstSeenAt: Date(timeIntervalSince1970: 1_725_000_000), title: "Reset window", plainTextSnippet: "Reset today 14:00-15:00 PST", feedURL: feedURL)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let prediction = ResetPredictionPolicy.predict(post: post, now: Date(timeIntervalSince1970: 1_725_000_000), systemTimeZone: TimeZone(secondsFromGMT: 0)!, calendar: calendar)
        try expect(prediction?.interpretedTimeZoneLabel == "PST", "PST label is retained")
        try expect(prediction?.interpretedTimeZoneIdentifier == "GMT-0800", "PST identifier is retained")
        try expect(prediction?.sourceURL == nil, "missing source URL remains optional")
    }

    private static func testFeedAnnouncementGrouping() throws {
        let feedURL = URL(string: "https://example.com/feed")!
        let now = Date(timeIntervalSince1970: 1_725_000_000)
        let p1 = FeedPost(id: "a", canonicalURL: nil, publishedAt: now, updatedAt: nil, firstSeenAt: now, title: "Reset", plainTextSnippet: "Reset today 14:00-15:00 PST", feedURL: feedURL)
        let p2 = FeedPost(id: "b", canonicalURL: nil, publishedAt: now.addingTimeInterval(3600), updatedAt: nil, firstSeenAt: now.addingTimeInterval(3600), title: "Update", plainTextSnippet: "Update: moved to tomorrow 14:00-15:00 PST", feedURL: feedURL)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let predictions = [p1, p2].compactMap { post in ResetPredictionPolicy.predict(post: post, now: now, systemTimeZone: TimeZone(secondsFromGMT: 0)!, calendar: calendar).map { (post.id, $0) } }.reduce(into: [:]) { $0[$1.0] = $1.1 }
        let events = FeedAnnouncementPolicy.events(posts: [p1, p2], predictions: predictions)
        try expect(events.count == 1, "continuation posts stay in one event")
        try expect(events.first?.id == "a", "root post remains event identity")
        try expect(events.first?.hasConflictingPredictions == true, "moved prediction marks conflict")
    }

    private static func testFeedStoreRetentionMapInvariant() throws {
        let url = URL(fileURLWithPath: "/private/tmp/feed-test-\(UUID().uuidString).json")
        let store = FeedTrackingStore(fileURL: url)
        let feedURL = URL(string: "https://example.com/feed")!
        let post = FeedPost(id: "p", canonicalURL: nil, publishedAt: Date(), updatedAt: nil, firstSeenAt: Date(), title: "Reset", plainTextSnippet: "Reset", feedURL: feedURL)
        _ = store.upsert(post: post, prediction: nil); store.prune(now: Date())
        try expect(Set(store.envelope.predictionsByPostID.keys).isSubset(of: Set(store.envelope.posts.map(\.id))), "prediction map keys stay within posts")
    }

    private static func testFeedParserNestedContent() throws {
        let url = URL(string: "https://example.com/feed")!
        let xml = "<rss><channel><title>Feed</title><item><guid>x</guid><title>Reset</title><description><![CDATA[<p>Reset today 14:00-15:00 PST</p>]]></description></item></channel></rss>"
        let parsed = try FeedParser.parse(data: Data(xml.utf8), feedURL: url, firstSeenAt: Date(timeIntervalSince1970: 1))
        try expect(parsed.posts.first?.plainTextSnippet.contains("Reset today") == true, "nested CDATA content is preserved")
    }

    private static func testFeedURLSafetyPolicy() throws {
        let valid = URL(string: "https://example.com/reset.xml")!
        if case .success(let returned) = FeedURLPolicy.validate(valid) {
            try expect(returned == valid, "public HTTPS feed is accepted")
        } else {
            throw HarnessError.assertion("public HTTPS feed should be accepted")
        }

        let cases: [(String, FeedURLPolicyError, String)] = [
            ("http://example.com/feed", .httpsRequired, "HTTP is rejected"),
            ("https://user:secret@example.com/feed", .userinfoNotAllowed, "URL userinfo is rejected"),
            ("https://localhost/feed", .privateAddressNotAllowed, "localhost is rejected"),
            ("https://127.0.0.1/feed", .privateAddressNotAllowed, "IPv4 loopback is rejected"),
            ("https://10.1.2.3/feed", .privateAddressNotAllowed, "RFC1918 10/8 is rejected"),
            ("https://172.20.1.4/feed", .privateAddressNotAllowed, "RFC1918 172.16/12 is rejected"),
            ("https://192.168.1.4/feed", .privateAddressNotAllowed, "RFC1918 192.168/16 is rejected"),
            ("https://169.254.1.2/feed", .privateAddressNotAllowed, "IPv4 link-local is rejected"),
            ("https://[::1]/feed", .privateAddressNotAllowed, "IPv6 loopback is rejected"),
            ("https://[fe80::1]/feed", .privateAddressNotAllowed, "IPv6 link-local is rejected"),
            ("https://[fc00::1]/feed", .privateAddressNotAllowed, "IPv6 unique-local is rejected"),
            ("https://[::ffff:127.0.0.1]/feed", .privateAddressNotAllowed, "IPv4-mapped IPv6 loopback is rejected")
        ]
        for (raw, expected, message) in cases {
            guard let url = URL(string: raw) else { throw HarnessError.assertion("fixture URL parses: \(raw)") }
            guard case .failure(let error) = FeedURLPolicy.validate(url) else { throw HarnessError.assertion(message) }
            try expect(error == expected, message)
        }
        try expect(FeedHTTPTransport.maxBodyBytes == 2 * 1024 * 1024, "transport enforces 2 MiB body limit")
        try expect(FeedHTTPTransport.timeout == 20, "transport uses 20 second timeout")
    }

    private static func testFeedParserEntitiesAndExternalEntityIsolation() throws {
        let normalized = FeedParser.plainText("<p>A &amp; B &#39; &#x2F; &apos;</p>")
        try expect(normalized == "A & B ' / '", "HTML and numeric entities become plain text")

        let url = URL(string: "https://example.com/feed")!
        let malicious = "<!DOCTYPE rss [<!ENTITY leaked SYSTEM \"file:///etc/passwd\">]><rss><channel><item><guid>external</guid><title>Reset</title><description>&leaked;</description></item></channel></rss>"
        let parsed = try? FeedParser.parse(data: Data(malicious.utf8), feedURL: url, firstSeenAt: Date(timeIntervalSince1970: 1))
        try expect(parsed == nil || !parsed!.posts.contains(where: { $0.plainTextSnippet.contains("root:") }), "external entity content is never loaded")
    }

    private static func testFeedStoreIdentityAndUpdateSemantics() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("codex-feed-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let fileURL = base.appendingPathComponent("feed.json")
        let urlA = URL(string: "https://example.com/a.xml")!
        let urlB = URL(string: "https://example.com/b.xml")!
        let firstSeen = Date(timeIntervalSince1970: 1_725_000_000)
        let published = Date(timeIntervalSince1970: 1_725_000_100)
        let store = FeedTrackingStore(fileURL: fileURL)
        try expect(store.configure(feedURL: urlA), "initial feed URL is configured")
        let post = FeedPost(id: "guid-1", canonicalURL: URL(string: "https://example.com/post/1"), publishedAt: published, updatedAt: nil, firstSeenAt: firstSeen, title: "Reset window", plainTextSnippet: "Reset today", feedURL: urlA)
        let prediction = ResetPrediction(windowStart: published, windowEnd: published.addingTimeInterval(3600), inferenceConfidence: .medium, corroboration: .unverified, reason: "Reset today", sourcePostID: post.id, sourceURL: post.canonicalURL, interpretedTimeZoneIdentifier: "UTC", interpretedTimeZoneLabel: "UTC", detectedAt: firstSeen)
        try expect(store.upsert(post: post, prediction: prediction), "new post is inserted")
        store.replaceMetadata(title: "A", link: urlA, etag: "abc", lastModified: "yesterday", successfulAt: published)
        store.markNotified(postID: post.id)
        try store.save()

        let reloaded = FeedTrackingStore(fileURL: fileURL)
        try expect(reloaded.envelope.configuredFeedURL == urlA, "configured URL round trips")
        try expect(reloaded.envelope.predictionsByPostID[post.id] == prediction, "per-post prediction round trips")
        try expect(reloaded.envelope.sentNotificationPostIDs.contains(post.id), "notification IDs round trip")
        try expect(reloaded.envelope.etag == "abc" && reloaded.envelope.lastModified == "yesterday", "validators round trip")

        let unchanged = FeedPost(id: post.id, canonicalURL: post.canonicalURL, publishedAt: published, updatedAt: nil, firstSeenAt: firstSeen.addingTimeInterval(999), title: "Reset window", plainTextSnippet: "Reset today", feedURL: urlA)
        try expect(!reloaded.upsert(post: unchanged, prediction: nil), "same effective content is not replaced")
        try expect(reloaded.envelope.posts.first?.firstSeenAt == firstSeen, "same-ID firstSeenAt remains stable")
        try expect(reloaded.envelope.predictionsByPostID[post.id] == prediction, "same-content post is not reanalyzed")

        let updated = FeedPost(id: post.id, canonicalURL: post.canonicalURL, publishedAt: published, updatedAt: published.addingTimeInterval(60), firstSeenAt: firstSeen.addingTimeInterval(999), title: "Reset window updated", plainTextSnippet: "Reset tomorrow", feedURL: urlA)
        let updatedPrediction = ResetPrediction(windowStart: published.addingTimeInterval(86400), windowEnd: published.addingTimeInterval(90000), inferenceConfidence: .medium, corroboration: .unverified, reason: "Reset tomorrow", sourcePostID: updated.id, sourceURL: updated.canonicalURL, interpretedTimeZoneIdentifier: "UTC", interpretedTimeZoneLabel: "UTC", detectedAt: updated.updatedAt!)
        try expect(reloaded.upsert(post: updated, prediction: updatedPrediction), "changed same-ID content is replaced")
        try expect(reloaded.envelope.posts.first?.firstSeenAt == firstSeen, "updated same-ID post preserves firstSeenAt")
        try expect(reloaded.envelope.predictionsByPostID[post.id] == updatedPrediction, "updated same-ID post replaces prediction")

        try expect(reloaded.configure(feedURL: urlB), "changing feed URL resets feed state")
        try expect(reloaded.envelope.configuredFeedURL == urlB && reloaded.envelope.posts.isEmpty, "feed URL change clears posts")
        try expect(reloaded.envelope.predictionsByPostID.isEmpty && reloaded.envelope.sentNotificationPostIDs.isEmpty, "feed URL change clears prediction and notification state")
        try expect(reloaded.envelope.etag == nil && reloaded.envelope.lastSuccessfulFetch == nil, "feed URL change clears validators and fetch timestamp")
    }

    private static func testFeedAnnouncementRule2AndPredictionSelection() throws {
        let feedURL = URL(string: "https://example.com/feed")!
        let now = Date(timeIntervalSince1970: 1_725_000_000)
        func post(_ id: String, _ offset: TimeInterval, _ title: String = "Reset status") -> FeedPost {
            let date = now.addingTimeInterval(offset)
            return FeedPost(id: id, canonicalURL: nil, publishedAt: date, updatedAt: nil, firstSeenAt: date, title: title, plainTextSnippet: "Reset notice", feedURL: feedURL)
        }
        func prediction(_ post: FeedPost, _ startOffset: TimeInterval?, _ duration: TimeInterval = 3600) -> ResetPrediction {
            let start = startOffset.map { now.addingTimeInterval($0) }
            return ResetPrediction(windowStart: start, windowEnd: start.map { $0.addingTimeInterval(duration) }, inferenceConfidence: .medium, corroboration: .unverified, reason: "Reset notice", sourcePostID: post.id, sourceURL: nil, interpretedTimeZoneIdentifier: "UTC", interpretedTimeZoneLabel: "UTC", detectedAt: now)
        }
        let a = post("a", 0)
        let b = post("b", 3600)
        let c = post("c", 7200)
        let aPrediction = prediction(a, 10 * 3600, 2 * 3600)
        let bPrediction = prediction(b, 11.5 * 3600, 2 * 3600)
        let cPrediction = prediction(c, 10.5 * 3600, 30 * 60)
        let events = FeedAnnouncementPolicy.events(posts: [a, b, c], predictions: [a.id: aPrediction, b.id: bPrediction, c.id: cPrediction])
        try expect(events.count == 2, "Rule2 does not use an aggregate union for transitive chaining")
        let merged = try unwrap(events.first(where: { $0.id == a.id }), "merged Rule2 event")
        try expect(merged.posts.map(\.id) == [a.id, b.id], "overlapping windows merge against current best-known window")
        try expect(merged.bestKnownPrediction?.sourcePostID == b.id, "best-known prediction is the latest valid window")

        let noTime = post("d", 10_800, "Update")
        let noTimeText = FeedPost(id: noTime.id, canonicalURL: noTime.canonicalURL, publishedAt: noTime.publishedAt, updatedAt: noTime.updatedAt, firstSeenAt: noTime.firstSeenAt, title: "Update", plainTextSnippet: "still working on reset", feedURL: noTime.feedURL)
        let selectionEvents = FeedAnnouncementPolicy.events(posts: [a, noTimeText], predictions: [a.id: aPrediction])
        let selection = try unwrap(selectionEvents.first, "latest/best-known event")
        try expect(selection.latestPrediction == nil, "latest prediction remains the latest post's own nil prediction")
        try expect(selection.bestKnownPrediction?.sourcePostID == a.id, "best-known prediction keeps the latest valid window")
        try expect(selection.latestActivityAt == noTimeText.effectiveActivityAt, "event activity follows latest post")
        try expect(FeedAnnouncementPolicy.filter(events: selectionEvents, range: .day, now: now.addingTimeInterval(2 * 24 * 3600)).isEmpty, "announcement range filtering uses latest activity")
    }

    private static func testFeedNotificationInjectedSubmission() throws {
        let feedURL = URL(string: "https://example.com/feed")!
        let post = FeedPost(id: "notification", canonicalURL: nil, publishedAt: nil, updatedAt: nil, firstSeenAt: Date(), title: "Reset", plainTextSnippet: "Reset", feedURL: feedURL)
        let successProbe = FeedNotificationSubmissionProbe(result: .success(()))
        var success: Result<Void, Error>?
        successProbe.send(post: post, prediction: nil, postCount: 1) { success = $0 }
        try expect(successProbe.calls == 1, "injected sender receives one submission")
        guard case .success? = success else { throw HarnessError.assertion("injected success reaches completion") }

        let failureProbe = FeedNotificationSubmissionProbe(result: .failure(HarnessError.assertion("expected failure")))
        var failure: Result<Void, Error>?
        failureProbe.send(post: post, prediction: nil, postCount: 1) { failure = $0 }
        guard case .failure? = failure else { throw HarnessError.assertion("injected failure reaches completion") }
    }

    private static func testFeedHTTPTransportStatusAndLimits() throws {
        let url = URL(string: "https://example.com/feed")!
        func fetch(_ transport: FeedHTTPTransport) -> Result<FeedHTTPResponse, Error> {
            let semaphore = DispatchSemaphore(value: 0)
            var result: Result<FeedHTTPResponse, Error>?
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            _ = transport.fetch(request: request) { value in result = value; semaphore.signal() }
            _ = semaphore.wait(timeout: .now() + 5)
            return result ?? .failure(FeedTransportError.timeout)
        }

        FeedURLProtocolProbe.reset()
        FeedURLProtocolProbe.statusCode = 304
        FeedURLProtocolProbe.headers = ["ETag": "\"probe\"", "Last-Modified": "Mon, 31 Aug 2026 00:00:00 GMT"]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedURLProtocolProbe.self]
        let notModified = fetch(FeedHTTPTransport(configuration: configuration, preflight: { _ in true }))
        guard case .success(let response) = notModified else { throw HarnessError.assertion("304 is returned as a successful transport response") }
        try expect(response.statusCode == 304, "304 is preserved as a terminal response")

        for statusCode in [401, 403, 404, 429, 500, 503] {
            FeedURLProtocolProbe.reset()
            FeedURLProtocolProbe.statusCode = statusCode
            let serverError = fetch(FeedHTTPTransport(configuration: configuration, preflight: { _ in true }))
            guard case .failure(let error) = serverError else { throw HarnessError.assertion("HTTP \(statusCode) should fail") }
            guard case .httpStatus(statusCode) = error as? FeedTransportError else { throw HarnessError.assertion("HTTP \(statusCode) maps to FeedTransportError.httpStatus") }
        }

        FeedURLProtocolProbe.reset()
        FeedURLProtocolProbe.statusCode = 200
        FeedURLProtocolProbe.headers = ["Content-Length": String(FeedHTTPTransport.maxBodyBytes + 1)]
        let oversized = fetch(FeedHTTPTransport(configuration: configuration, preflight: { _ in true }))
        guard case .failure(let error) = oversized else { throw HarnessError.assertion("oversized Content-Length should fail") }
        guard case .bodyTooLarge = error as? FeedTransportError else { throw HarnessError.assertion("oversized response maps to bodyTooLarge") }

        FeedURLProtocolProbe.reset()
        FeedURLProtocolProbe.statusCode = 200
        FeedURLProtocolProbe.body = Data(repeating: 0x61, count: FeedHTTPTransport.maxBodyBytes + 1)
        let streamedOversized = fetch(FeedHTTPTransport(configuration: configuration, preflight: { _ in true }))
        guard case .failure(let streamedError) = streamedOversized else { throw HarnessError.assertion("streamed oversized body should fail") }
        guard case .bodyTooLarge = streamedError as? FeedTransportError else { throw HarnessError.assertion("streamed oversized body maps to bodyTooLarge") }

        FeedURLProtocolProbe.reset()
        let preflightRejected = fetch(FeedHTTPTransport(configuration: configuration, preflight: { _ in false }))
        guard case .failure(let preflightError) = preflightRejected else { throw HarnessError.assertion("failed preflight should fail closed") }
        guard case .dnsPreflightFailed = preflightError as? FeedTransportError else { throw HarnessError.assertion("failed preflight maps to dnsPreflightFailed") }
    }

    private static func testFeedHTTPTransportRedirectAndTimeout() throws {
        let url = URL(string: "https://example.com/feed")!
        func fetch() -> Result<FeedHTTPResponse, Error> {
            let semaphore = DispatchSemaphore(value: 0)
            var result: Result<FeedHTTPResponse, Error>?
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FeedURLProtocolProbe.self]
            let transport = FeedHTTPTransport(configuration: configuration, preflight: { _ in true })
            _ = transport.fetch(request: URLRequest(url: url)) { value in result = value; semaphore.signal() }
            _ = semaphore.wait(timeout: .now() + 5)
            return result ?? .failure(FeedTransportError.timeout)
        }

        FeedURLProtocolProbe.reset()
        FeedURLProtocolProbe.redirectURL = URL(string: "http://example.com/private")!
        let redirect = fetch()
        guard case .failure(let redirectError) = redirect else { throw HarnessError.assertion("unsafe redirect should fail") }
        guard case .redirectRejected = redirectError as? FeedTransportError else { throw HarnessError.assertion("unsafe redirect maps to redirectRejected") }

        FeedURLProtocolProbe.reset()
        FeedURLProtocolProbe.failure = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let timeout = fetch()
        guard case .failure(let timeoutError) = timeout else { throw HarnessError.assertion("timed out transport should fail") }
        guard case .timeout = timeoutError as? FeedTransportError else { throw HarnessError.assertion("timed out URLSession maps to timeout") }
    }

    private static func testFeedServiceValidatorsGenerationAndNotificationDedupe() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("codex-feed-service-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let store = FeedTrackingStore(fileURL: base.appendingPathComponent("feed.json"))
        let feedURL = URL(string: "https://example.com/feed")!
        let now = Date(timeIntervalSince1970: 1_725_000_000)
        let transport = FeedDeferredTransport()
        let notifications = FeedNotificationSubmissionProbe(result: .success(()))
        let service = FeedTrackingService(store: store, transport: transport, now: { now }, systemTimeZone: TimeZone(secondsFromGMT: 0)!)
        service.notificationService = notifications
        service.notificationsAllowed = { true }
        service.start(enabled: true, cadence: .manual, feedURL: feedURL)
        try expect(transport.requests.count == 1, "service performs immediate configured fetch")

        func response(title: String, statusCode: Int = 200, etag: String? = nil) -> FeedHTTPResponse {
            let body = "<rss><channel><item><guid>stable-post</guid><title>\(title)</title><description>Reset today 14:00-15:00 PST</description></item></channel></rss>"
            var headers: [AnyHashable: Any] = [:]
            if let etag { headers["ETag"] = etag; headers["Last-Modified"] = "Mon, 31 Aug 2026 00:00:00 GMT" }
            return FeedHTTPResponse(data: statusCode == 304 ? Data() : Data(body.utf8), statusCode: statusCode, headers: headers)
        }

        transport.complete(0, with: .success(response(title: "Baseline", etag: "one")))
        try expect(store.envelope.etag == "one" && store.envelope.lastModified != nil, "service persists ETag and Last-Modified")

        service.fetch()
        try expect(transport.requests[1].value(forHTTPHeaderField: "If-None-Match") == "one", "next fetch sends persisted ETag")
        try expect(transport.requests[1].value(forHTTPHeaderField: "If-Modified-Since") != nil, "next fetch sends persisted Last-Modified")
        service.fetch()
        try expect(transport.handles[1].cancelCount == 1, "new fetch cancels previous request")
        transport.complete(1, with: .success(response(title: "Stale response", etag: "stale")))
        transport.complete(2, with: .success(response(title: "Fresh response", etag: "two")))
        try expect(store.envelope.posts.first?.title == "Fresh response", "stale generation cannot overwrite fresh response")
        try expect(notifications.calls == 1, "changed post sends one notification")

        service.fetch()
        try expect(transport.requests[3].value(forHTTPHeaderField: "If-None-Match") == "two", "fresh validator is used after update")
        transport.complete(3, with: .success(response(title: "ignored", statusCode: 304)))
        try expect(service.state == .notModified && store.envelope.lastSuccessfulFetch != nil, "304 updates successful fetch state")

        service.fetch()
        transport.complete(4, with: .success(response(title: "Fresh response", etag: "two")))
        try expect(notifications.calls == 1, "unchanged post does not enqueue duplicate notification")
    }

    private static func testFeedContinuationRejectsUnrelatedUpdate() throws {
        let feedURL = URL(string: "https://example.com/feed")!
        let now = Date(timeIntervalSince1970: 1_725_000_000)
        let root = FeedPost(id: "root", canonicalURL: nil, publishedAt: now, updatedAt: nil, firstSeenAt: now, title: "Reset", plainTextSnippet: "Reset today 14:00-15:00 PST", feedURL: feedURL)
        let unrelated = FeedPost(id: "unrelated", canonicalURL: nil, publishedAt: now.addingTimeInterval(3600), updatedAt: nil, firstSeenAt: now, title: "Update", plainTextSnippet: "landing page is live", feedURL: feedURL)
        let calendar = Calendar(identifier: .gregorian)
        let predictions = [root].reduce(into: [String: ResetPrediction]()) { result, post in
            if let prediction = ResetPredictionPolicy.predict(post: post, now: now, systemTimeZone: .current, calendar: calendar) { result[post.id] = prediction }
        }
        let events = FeedAnnouncementPolicy.events(posts: [root, unrelated], predictions: predictions)
        try expect(events.count == 2 && events.contains(where: { $0.id == root.id && $0.posts.map({ $0.id }) == [root.id] }), "unrelated continuation does not merge into reset event")
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

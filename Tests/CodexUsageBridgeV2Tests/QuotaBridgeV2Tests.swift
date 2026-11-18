import Foundation
import XCTest
@testable import CodexUsageStatusCore

final class QuotaBridgeV2Tests: XCTestCase {
    private let initial = Date(timeIntervalSince1970: 1_800_000_000)

    private func fullSnapshot(credits: Any = ["availableCount": 3]) throws -> UsageSnapshot {
        try UsageDataCodec.decodeFullSnapshot(from: [
            "rateLimits": [
                "primary": ["usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1_800_001_000],
                "secondary": ["usedPercent": 90, "windowDurationMins": 10_080, "resetsAt": 1_800_100_000],
            ],
            "rateLimitResetCredits": credits,
        ], receivedAt: initial)
    }

    private var health: AccountHealthSnapshot {
        .init(identity: .init(accountType: "chatgpt", authMode: nil, planType: "Plus",
                              email: "source@example.test", requiresOpenAIAuth: true),
              receivedAt: initial.addingTimeInterval(1), connectionState: .connected)
    }

    func testTwoWindowsAndCreditsUseIndependentObservationTimes() throws {
        let base = try fullSnapshot()
        let patch = try UsageDataCodec.decodePatch(from: ["rateLimits": [
            "primary": ["usedPercent": 26, "windowDurationMins": 300, "resetsAt": 1_800_001_000],
        ]])
        let update = try XCTUnwrap(patch.applying(to: base, receivedAt: initial.addingTimeInterval(20)))
        let result = CodexUsageQuotaV2Projection.make(profileID: UUID(), health: health, snapshot: update, ready: true)
        XCTAssertEqual(result.account?.observedAt, health.receivedAt)
        XCTAssertEqual(result.fiveHour?.remainingPercent, 74)
        XCTAssertEqual(result.fiveHour?.observedAt, initial.addingTimeInterval(20))
        XCTAssertEqual(result.sevenDay?.remainingPercent, 10)
        XCTAssertEqual(result.sevenDay?.observedAt, initial)
        XCTAssertEqual(result.resetCredits?.count, 3)
        XCTAssertEqual(result.resetCredits?.observedAt, initial)
    }

    func testSparseWindowUpdateDoesNotRefreshItsCoherentObservation() throws {
        let base = try fullSnapshot()
        let patch = try UsageDataCodec.decodePatch(from: ["rateLimits": ["primary": ["usedPercent": 26]]])
        let update = try XCTUnwrap(patch.applying(to: base, receivedAt: initial.addingTimeInterval(10)))
        let result = CodexUsageQuotaV2Projection.make(profileID: UUID(), health: health, snapshot: update, ready: true)
        XCTAssertNil(result.fiveHour)
        XCTAssertEqual(result.sevenDay?.observedAt, initial)
        XCTAssertEqual(result.resetCredits?.observedAt, initial)
    }

    func testMissingOrMalformedCreditCountIsNotAnObservedZero() throws {
        for raw: Any in [[:], ["availableCount": true], ["availableCount": -1], ["availableCount": 1.5]] {
            let snapshot = try fullSnapshot(credits: raw)
            let result = CodexUsageQuotaV2Projection.make(profileID: UUID(), health: health, snapshot: snapshot, ready: true)
            XCTAssertNil(result.resetCredits)
        }
        let zero = try fullSnapshot(credits: ["availableCount": 0])
        XCTAssertEqual(CodexUsageQuotaV2Projection.make(profileID: UUID(), health: health, snapshot: zero, ready: true).resetCredits?.count, 0)
    }

    func testOfflineMissingAccountAndDuplicateDurationFailClosed() throws {
        var snapshot = try fullSnapshot()
        let profileID = UUID()
        XCTAssertEqual(CodexUsageQuotaV2Projection.make(profileID: profileID, health: health, snapshot: snapshot, ready: false), .notProven)
        XCTAssertEqual(CodexUsageQuotaV2Projection.make(profileID: profileID, health: nil, snapshot: snapshot, ready: true), .notProven)
        XCTAssertEqual(CodexUsageQuotaV2Projection.make(profileID: nil, health: health, snapshot: snapshot, ready: true), .notProven)
        snapshot.secondary = snapshot.primary
        let ambiguous = CodexUsageQuotaV2Projection.make(profileID: profileID, health: health, snapshot: snapshot, ready: true)
        XCTAssertNil(ambiguous.fiveHour)
        XCTAssertNil(ambiguous.sevenDay)
    }

    func testAccountBoundaryNeverReusesThePreviousAccountQuota() throws {
        var gate = CodexUsageQuotaIdentityGate()
        let first = try fullSnapshot()
        gate.observeSnapshot(first)
        XCTAssertNil(gate.snapshot) // A quota arriving before account identity is not attributable.
        gate.observeHealth(health)
        gate.observeSnapshot(first)
        XCTAssertEqual(gate.snapshot?.primary?.usedPercent, 25)
        gate.observeHealth(health) // A normal refresh of the same identity preserves data.
        XCTAssertNotNil(gate.snapshot)

        let different = AccountHealthSnapshot(
            identity: .init(accountType: "chatgpt", authMode: nil, planType: "Plus",
                            email: "other@example.test", requiresOpenAIAuth: true),
            receivedAt: initial.addingTimeInterval(2), connectionState: .connected)
        gate.observeHealth(different)
        XCTAssertNil(gate.snapshot)
        gate.observeSnapshot(first)
        XCTAssertNotNil(gate.snapshot)
        gate.clear() // e.g. connection loss, account notification or worker replacement
        XCTAssertNil(gate.snapshot)
        gate.observeSnapshot(first)
        XCTAssertNil(gate.snapshot)
    }

    func testV2RejectsUnknownCredentialFieldsAndUnsafeValues() throws {
        let snapshot = CodexUsageQuotaV2Projection.make(profileID: UUID(), health: health, snapshot: try fullSnapshot(), ready: true)
        let encoded = try CodexUsageAccountQuotaBridgeV2Codec.encodeSnapshotResponse(snapshot)
        XCTAssertEqual(try CodexUsageAccountQuotaBridgeV2Codec.decodeSnapshotResponse(encoded), snapshot)
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var inner = try XCTUnwrap(body["snapshot"] as? [String: Any])
        inner["accessToken"] = "must-not-cross"
        body["snapshot"] = inner
        XCTAssertThrowsError(try CodexUsageAccountQuotaBridgeV2Codec.decodeSnapshotResponse(JSONSerialization.data(withJSONObject: body)))
        XCTAssertFalse(CodexUsageAccountQuotaBridgeV2Codec.isSnapshotRequest(Data("{\"operation\":\"snapshot\",\"protocolVersion\":true}".utf8)))
    }

    @MainActor
    func testSameProtectedSocketSupportsBothVersionedReadOnlyRequests() async throws {
        let parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("plq-v2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = FixtureSource(v2: CodexUsageQuotaV2Projection.make(profileID: UUID(), health: health,
                                                                          snapshot: try fullSnapshot(), ready: true))
        let socket = parent.appendingPathComponent("quota.sock")
        let server = CodexUsageAccountQuotaBridgeServer(socketURL: socket, source: source)
        try server.start()
        defer { server.stop() }
        let responses = try await Task.detached {
            try [CodexUsageAccountQuotaBridgeCodec.snapshotRequest(), CodexUsageAccountQuotaBridgeV2Codec.snapshotRequest()].map {
                try SecureUnixRequestResponseTransport.roundTrip(request: $0, to: socket,
                    maximumFrameSize: CodexUsageAccountQuotaBridgeCodec.maximumFrameSize)
            }
        }.value
        XCTAssertEqual(try CodexUsageAccountQuotaBridgeCodec.decodeSnapshotResponse(responses[0]), .notProven)
        XCTAssertEqual(try CodexUsageAccountQuotaBridgeV2Codec.decodeSnapshotResponse(responses[1]), source.accountQuotaSnapshotV2)
    }
}

@MainActor
private final class FixtureSource: CodexUsageAccountQuotaProjectionSourceV2 {
    let accountQuotaSnapshot: CodexUsageAccountQuotaSnapshot = .notProven
    let accountQuotaSnapshotV2: CodexUsageAccountQuotaSnapshotV2
    init(v2: CodexUsageAccountQuotaSnapshotV2) { accountQuotaSnapshotV2 = v2 }
}

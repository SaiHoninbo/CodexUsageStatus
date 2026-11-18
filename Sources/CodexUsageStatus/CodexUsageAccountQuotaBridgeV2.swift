import CoreFoundation
import Foundation

/// V2 contains no credentials. The source profile is a local selection, not
/// proof that another app is using the same Codex account.
public struct CodexUsageAccountQuotaSnapshotV2: Codable, Equatable, Sendable {
    public struct Account: Codable, Equatable, Sendable {
        public let displayIdentity: String
        public let observedAt: Date
        public let plan: String?
        public init(displayIdentity: String, observedAt: Date, plan: String? = nil) {
            self.displayIdentity = displayIdentity
            self.observedAt = observedAt
            self.plan = plan
        }
    }
    public struct Window: Codable, Equatable, Sendable {
        public let remainingPercent: Int
        public let observedAt: Date
        public let resetsAt: Date
        public init(remainingPercent: Int, observedAt: Date, resetsAt: Date) {
            self.remainingPercent = remainingPercent
            self.observedAt = observedAt
            self.resetsAt = resetsAt
        }
    }
    public struct ResetCredits: Codable, Equatable, Sendable {
        public let count: Int
        public let observedAt: Date
        public let earliestExpiry: Date?
        public init(count: Int, observedAt: Date, earliestExpiry: Date? = nil) {
            self.count = count
            self.observedAt = observedAt
            self.earliestExpiry = earliestExpiry
        }
    }

    public let availability: CodexUsageAccountQuotaAvailability
    public let sourceProfileID: UUID?
    public let account: Account?
    public let fiveHour: Window?
    public let sevenDay: Window?
    public let resetCredits: ResetCredits?

    public init(availability: CodexUsageAccountQuotaAvailability, sourceProfileID: UUID?, account: Account?,
                fiveHour: Window?, sevenDay: Window?, resetCredits: ResetCredits?) {
        self.availability = availability
        self.sourceProfileID = sourceProfileID
        self.account = account
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.resetCredits = resetCredits
    }

    public static let notProven = CodexUsageAccountQuotaSnapshotV2(
        availability: .notProven, sourceProfileID: nil, account: nil,
        fiveHour: nil, sevenDay: nil, resetCredits: nil
    )
}

@MainActor
public protocol CodexUsageAccountQuotaProjectionSourceV2: CodexUsageAccountQuotaProjectionSource {
    var accountQuotaSnapshotV2: CodexUsageAccountQuotaSnapshotV2 { get }
    func refreshQuotaAccountIfNeeded()
}

public extension CodexUsageAccountQuotaProjectionSourceV2 {
    func refreshQuotaAccountIfNeeded() {}
}

/// Only while a V2 consumer is connected, request a bounded account read
/// before its independent observation expires. This does not alter the
/// donor's persistent refresh preferences or consume reset credits.
struct CodexUsageQuotaAccountRefreshPolicy {
    enum ClientSelection: Equatable { case managed, defaultAccount, unavailable }
    private var profileID: UUID?
    private var lastAttemptAt: Date?

    static func selectClient(isManaged: Bool, hasManagedWorker: Bool, defaultClientEnabled: Bool) -> ClientSelection {
        if isManaged { return hasManagedWorker ? .managed : .unavailable }
        return defaultClientEnabled ? .defaultAccount : .unavailable
    }

    mutating func shouldRefresh(profileID: UUID?, observedAt: Date?, now: Date, sourceRunning: Bool) -> Bool {
        guard sourceRunning, let profileID, let observedAt else { return false }
        if self.profileID != profileID {
            self.profileID = profileID
            lastAttemptAt = nil
        }
        let age = now.timeIntervalSince(observedAt)
        guard age < 0 || age >= 90 else { return false }
        if let lastAttemptAt {
            let elapsed = now.timeIntervalSince(lastAttemptAt)
            guard elapsed < 0 || elapsed >= 60 else { return false }
        }
        lastAttemptAt = now
        return true
    }
}

/// Keep quota callbacks tied to the account last read on this connection.
/// A quota received before identity, after a disconnect, or across an account
/// change is not exposed until a subsequent quota callback arrives.
struct CodexUsageQuotaIdentityGate {
    private(set) var identityKey: String?
    private(set) var snapshot: UsageSnapshot?

    mutating func observeHealth(_ health: AccountHealthSnapshot) {
        let email = health.identity.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !email.isEmpty else { clear(); return }
        let key = [email, health.identity.accountType ?? "", health.identity.authMode ?? ""].joined(separator: "|")
        if identityKey != key { snapshot = nil }
        identityKey = key
    }

    mutating func observeSnapshot(_ value: UsageSnapshot) {
        // Notifications do not carry an independently verifiable account
        // identity. The existing client invalidates old pending reads on an
        // account boundary; only its subsequent full response is attributable
        // to the selected connection. Keep sparse events out of this bridge.
        guard identityKey != nil, value.observedFromFullRead else { return }
        snapshot = value
    }

    mutating func clear() {
        identityKey = nil
        snapshot = nil
    }
}

enum CodexUsageQuotaV2Projection {
    static func make(profileID: UUID?, health: AccountHealthSnapshot?, snapshot: UsageSnapshot?, ready: Bool)
        -> CodexUsageAccountQuotaSnapshotV2 {
        guard ready, let profileID, let health,
              let identity = health.identity.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identity.isEmpty else { return .notProven }
        let account = CodexUsageAccountQuotaSnapshotV2.Account(displayIdentity: identity, observedAt: health.receivedAt,
                                                              plan: health.identity.planType)
        let attributableSnapshot = snapshot?.observedFromFullRead == true ? snapshot : nil
        func window(_ duration: Int64) -> CodexUsageAccountQuotaSnapshotV2.Window? {
            guard let snapshot = attributableSnapshot else { return nil }
            let candidates = [(snapshot.primary, snapshot.primaryObservedAt), (snapshot.secondary, snapshot.secondaryObservedAt)]
                .filter { $0.0?.windowDurationMins == duration }
            guard candidates.count == 1, let source = candidates[0].0,
                  let observedAt = candidates[0].1, let reset = source.resetsAt,
                  (0...100).contains(source.usedPercent) else { return nil }
            return .init(remainingPercent: source.remainingPercent, observedAt: observedAt,
                         resetsAt: Date(timeIntervalSince1970: TimeInterval(reset)))
        }
        let credits: CodexUsageAccountQuotaSnapshotV2.ResetCredits?
        if let snapshot = attributableSnapshot, let value = snapshot.rateLimitResetCredits,
           let observedAt = snapshot.resetCreditsObservedAt, value.availableCount >= 0 {
            let earliest = value.availableCredits.compactMap(\.expiresAt).min()
            credits = .init(count: value.availableCount, observedAt: observedAt,
                            earliestExpiry: earliest.map { Date(timeIntervalSince1970: TimeInterval($0)) })
        } else {
            credits = nil
        }
        return .init(availability: .available, sourceProfileID: profileID, account: account,
                     fiveHour: window(300), sevenDay: window(10_080), resetCredits: credits)
    }
}

/// A distinct version preserves the exact V1 schema and request semantics.
public enum CodexUsageAccountQuotaBridgeV2Codec {
    public static let protocolVersion = 2
    private struct Response: Codable {
        let protocolVersion: Int
        let snapshot: CodexUsageAccountQuotaSnapshotV2
    }

    public static func snapshotRequest() -> Data {
        Data("{\"operation\":\"snapshot\",\"protocolVersion\":2}".utf8)
    }

    public static func isSnapshotRequest(_ data: Data) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(value.keys) == ["operation", "protocolVersion"], value["operation"] as? String == "snapshot",
              let version = value["protocolVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID()
        else { return false }
        return version.intValue == protocolVersion
    }

    public static func encodeSnapshotResponse(_ snapshot: CodexUsageAccountQuotaSnapshotV2) throws -> Data {
        guard isSafe(snapshot) else { throw CodexUsageAccountQuotaBridgeError.unsafeProjection }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(Response(protocolVersion: protocolVersion, snapshot: snapshot))
    }

    public static func decodeSnapshotResponse(_ data: Data) throws -> CodexUsageAccountQuotaSnapshotV2 {
        guard data.count <= CodexUsageAccountQuotaBridgeCodec.maximumFrameSize,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(value.keys) == ["protocolVersion", "snapshot"],
              let version = value["protocolVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.intValue == protocolVersion,
              let snapshot = value["snapshot"] as? [String: Any],
              Set(snapshot.keys).isSubset(of: ["availability", "sourceProfileID", "account", "fiveHour", "sevenDay", "resetCredits"]),
              snapshot["availability"] is String,
              validObject(snapshot["account"], keys: ["displayIdentity", "observedAt", "plan"], required: ["displayIdentity", "observedAt"]),
              validObject(snapshot["fiveHour"], keys: ["remainingPercent", "observedAt", "resetsAt"], required: ["remainingPercent", "observedAt", "resetsAt"]),
              validObject(snapshot["sevenDay"], keys: ["remainingPercent", "observedAt", "resetsAt"], required: ["remainingPercent", "observedAt", "resetsAt"]),
              validObject(snapshot["resetCredits"], keys: ["count", "observedAt", "earliestExpiry"], required: ["count", "observedAt"])
        else { throw CodexUsageAccountQuotaBridgeError.invalidResponse }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let decoded = try decoder.decode(Response.self, from: data)
        guard isSafe(decoded.snapshot) else { throw CodexUsageAccountQuotaBridgeError.unsafeProjection }
        return decoded.snapshot
    }

    private static func validObject(_ value: Any?, keys: Set<String>, required: Set<String>) -> Bool {
        guard let value else { return true }
        if value is NSNull { return true }
        guard let object = value as? [String: Any] else { return false }
        let actual = Set(object.keys)
        return actual.isSubset(of: keys) && required.isSubset(of: actual)
    }

    private static func isSafe(_ snapshot: CodexUsageAccountQuotaSnapshotV2) -> Bool {
        let hasData = snapshot.account != nil || snapshot.fiveHour != nil || snapshot.sevenDay != nil || snapshot.resetCredits != nil
        if hasData && (snapshot.availability != .available || snapshot.account == nil || snapshot.sourceProfileID == nil) { return false }
        if let account = snapshot.account,
           account.displayIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || account.displayIdentity.utf8.count > 320 || !account.observedAt.timeIntervalSince1970.isFinite { return false }
        if let plan = snapshot.account?.plan, plan.utf8.count > 128 { return false }
        for window in [snapshot.fiveHour, snapshot.sevenDay].compactMap({ $0 }) {
            if !(0...100).contains(window.remainingPercent) || !window.observedAt.timeIntervalSince1970.isFinite
                || !window.resetsAt.timeIntervalSince1970.isFinite { return false }
        }
        if let credits = snapshot.resetCredits,
           credits.count < 0 || !credits.observedAt.timeIntervalSince1970.isFinite
            || !(credits.earliestExpiry?.timeIntervalSince1970.isFinite ?? true) { return false }
        return true
    }
}

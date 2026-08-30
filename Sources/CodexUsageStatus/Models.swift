import Foundation

enum ConnectionState: String, Codable, Equatable {
    case disconnected
    case connecting
    case connected
    case offline
    case error
    case stopped

    var displayName: String {
        switch self {
        case .disconnected: return "尚未連線"
        case .connecting: return "連線中…"
        case .connected: return "已連線"
        case .offline: return "離線"
        case .error: return "連線錯誤"
        case .stopped: return "已停止"
        }
    }
}

struct RateLimitWindow: Equatable {
    var usedPercent: Int
    var resetsAt: Int64?
    var windowDurationMins: Int64?

    var remainingPercent: Int {
        max(0, min(100, 100 - usedPercent))
    }

    var clampedUsedPercent: Int {
        max(0, min(100, usedPercent))
    }
}

struct SpendControlLimit: Equatable {
    var limit: String
    var used: String
    var remainingPercent: Int
    var resetsAt: Int64
}

struct RateLimitResetCredit: Codable, Equatable, Identifiable {
    let id: String
    let resetType: String?
    let status: String?
    let grantedAt: Int64?
    let expiresAt: Int64?
    let title: String?
    let description: String?

    var isAvailable: Bool {
        guard let status else { return true }
        return status.lowercased() == "available"
    }
}

struct RateLimitResetCredits: Codable, Equatable {
    let availableCount: Int
    let credits: [RateLimitResetCredit]?

    var availableCredits: [RateLimitResetCredit] {
        credits?.filter(\.isAvailable) ?? []
    }

    var hasCreditDetails: Bool { credits != nil }
}

enum ResetCreditOutcome: Equatable {
    case reset
    case alreadyRedeemed
    case nothingToReset
    case noCredit
    case unknown(String)
    case error(String)

    var succeeded: Bool {
        self == .reset || self == .alreadyRedeemed
    }

    var displayText: String {
        switch self {
        case .reset: return "Reset credit 已使用，正在重新讀取用量。"
        case .alreadyRedeemed: return "這張 Reset credit 已使用，正在確認目前用量。"
        case .nothingToReset: return "目前沒有需要重置的 quota。"
        case .noCredit: return "這張 Reset credit 已不可用。"
        case .unknown(let message): return message
        case .error(let message): return message
        }
    }
}

enum ResetCreditOperationState: Equatable {
    case idle
    case consuming
    case succeeded
    case alreadyRedeemed
    case nothingToReset
    case noCredit
    case unknown
    case error
}

struct HistorySample: Codable, Equatable, Identifiable {
    let receivedAt: Date
    let limitId: String?
    let primaryUsedPercent: Int?
    let secondaryUsedPercent: Int?
    let primaryResetsAt: Int64?
    let secondaryResetsAt: Int64?
    let connectionState: ConnectionState

    var id: Date { receivedAt }

    init(snapshot: UsageSnapshot, connectionState: ConnectionState, receivedAt: Date) {
        self.receivedAt = receivedAt
        self.limitId = snapshot.limitId
        self.primaryUsedPercent = snapshot.primary?.usedPercent
        self.secondaryUsedPercent = snapshot.secondary?.usedPercent
        self.primaryResetsAt = snapshot.primary?.resetsAt
        self.secondaryResetsAt = snapshot.secondary?.resetsAt
        self.connectionState = connectionState
    }
}

struct UsageSnapshot: Equatable {
    var limitId: String?
    var limitName: String?
    var planType: String?
    var primary: RateLimitWindow?
    var secondary: RateLimitWindow?
    /// The optional model-reserve bucket returned separately from the
    /// canonical `codex` bucket (currently `base_model_inference`). It is
    /// intentionally kept distinct from `individualLimit`, which represents
    /// a spend-control/monthly credit limit rather than a rate-limit window.
    var gptReserveWeekly: RateLimitWindow?
    var individualLimit: SpendControlLimit?
    var rateLimitReachedType: String?
    var spendControlReached: Bool?
    var rateLimitResetCredits: RateLimitResetCredits?
    var receivedAt: Date

    init(
        limitId: String?,
        limitName: String?,
        planType: String?,
        primary: RateLimitWindow?,
        secondary: RateLimitWindow?,
        individualLimit: SpendControlLimit?,
        rateLimitReachedType: String?,
        spendControlReached: Bool?,
        rateLimitResetCredits: RateLimitResetCredits? = nil,
        receivedAt: Date,
        gptReserveWeekly: RateLimitWindow? = nil
    ) {
        self.limitId = limitId
        self.limitName = limitName
        self.planType = planType
        self.primary = primary
        self.secondary = secondary
        self.gptReserveWeekly = gptReserveWeekly
        self.individualLimit = individualLimit
        self.rateLimitReachedType = rateLimitReachedType
        self.spendControlReached = spendControlReached
        self.rateLimitResetCredits = rateLimitResetCredits
        self.receivedAt = receivedAt
    }

    var primaryRemainingPercent: Int? {
        primary?.remainingPercent
    }

    var fallbackRemainingPercent: Int? {
        primary?.remainingPercent ?? secondary?.remainingPercent
    }
}

struct RateLimitWindowPatch: Equatable {
    var usedPercent: Int?
    var resetsAt: Int64?
    var windowDurationMins: Int64?
}

struct SpendControlPatch: Equatable {
    var limit: String?
    var used: String?
    var remainingPercent: Int?
    var resetsAt: Int64?
}

struct RateLimitPatch: Equatable {
    var limitId: String?
    var limitName: String?
    var planType: String?
    var primary: RateLimitWindowPatch?
    var secondary: RateLimitWindowPatch?
    var gptReserveWeekly: RateLimitWindowPatch?
    var individualLimit: SpendControlPatch?
    var rateLimitReachedType: String?
    var spendControlReached: Bool?

    func applying(to current: UsageSnapshot?, receivedAt: Date = Date()) -> UsageSnapshot? {
        let base = current ?? UsageSnapshot(
            limitId: nil,
            limitName: nil,
            planType: nil,
            primary: nil,
            secondary: nil,
            individualLimit: nil,
            rateLimitReachedType: nil,
            spendControlReached: nil,
            rateLimitResetCredits: nil,
            receivedAt: receivedAt
        )

        let primaryWindow = Self.mergeWindow(existing: base.primary, patch: primary)
        let secondaryWindow = Self.mergeWindow(existing: base.secondary, patch: secondary)
        let reserveWindow = Self.mergeWindow(existing: base.gptReserveWeekly, patch: gptReserveWeekly)
        let spendControl = Self.mergeSpendControl(existing: base.individualLimit, patch: individualLimit)

        return UsageSnapshot(
            limitId: limitId ?? base.limitId,
            limitName: limitName ?? base.limitName,
            planType: planType ?? base.planType,
            primary: primaryWindow,
            secondary: secondaryWindow,
            individualLimit: spendControl,
            rateLimitReachedType: rateLimitReachedType ?? base.rateLimitReachedType,
            spendControlReached: spendControlReached ?? base.spendControlReached,
            rateLimitResetCredits: base.rateLimitResetCredits,
            receivedAt: receivedAt,
            gptReserveWeekly: reserveWindow
        )
    }

    private static func mergeWindow(
        existing: RateLimitWindow?,
        patch: RateLimitWindowPatch?
    ) -> RateLimitWindow? {
        guard let patch else { return existing }
        guard let usedPercent = patch.usedPercent ?? existing?.usedPercent else {
            return existing
        }
        return RateLimitWindow(
            usedPercent: usedPercent,
            resetsAt: patch.resetsAt ?? existing?.resetsAt,
            windowDurationMins: patch.windowDurationMins ?? existing?.windowDurationMins
        )
    }

    private static func mergeSpendControl(
        existing: SpendControlLimit?,
        patch: SpendControlPatch?
    ) -> SpendControlLimit? {
        guard let patch else { return existing }
        guard let limit = patch.limit ?? existing?.limit,
              let used = patch.used ?? existing?.used,
              let remaining = patch.remainingPercent ?? existing?.remainingPercent,
              let resetsAt = patch.resetsAt ?? existing?.resetsAt else {
            return existing
        }
        return SpendControlLimit(
            limit: limit,
            used: used,
            remainingPercent: max(0, min(100, remaining)),
            resetsAt: resetsAt
        )
    }
}

enum UsageDataCodec {
    enum CodecError: Error, LocalizedError {
        case invalidObject
        case missingRateLimits

        var errorDescription: String? {
            switch self {
            case .invalidObject: return "rate-limit 回應不是有效的 JSON object"
            case .missingRateLimits: return "rate-limit 回應缺少 rateLimits"
            }
        }
    }

    static func decodeFullSnapshot(from result: Any, receivedAt: Date = Date()) throws -> UsageSnapshot {
        guard let result = result as? [String: Any] else { throw CodecError.invalidObject }
        let legacyObject = result["rateLimits"] as? [String: Any]
        let legacy = legacyObject ?? [:]
        let codexBucket = codexLimitObject(from: result)
        guard legacyObject != nil || codexBucket != nil else {
            throw CodecError.missingRateLimits
        }
        let source = mergedLimitObject(legacy: legacy, codexBucket: codexBucket) ?? [:]

        return UsageSnapshot(
            limitId: string(source["limitId"]),
            limitName: string(source["limitName"]),
            planType: string(source["planType"]),
            primary: decodeWindow(source["primary"]),
            secondary: decodeWindow(source["secondary"]),
            individualLimit: decodeSpendControl(source["individualLimit"]),
            rateLimitReachedType: string(source["rateLimitReachedType"]),
            spendControlReached: source["spendControlReached"] as? Bool,
            rateLimitResetCredits: decodeResetCredits(result["rateLimitResetCredits"]),
            receivedAt: receivedAt,
            gptReserveWeekly: decodeGPTReserveWindow(from: result)
        )
    }

    static func decodePatch(from params: Any) throws -> RateLimitPatch {
        guard let params = params as? [String: Any],
              let source = params["rateLimits"] as? [String: Any] else {
            throw CodecError.missingRateLimits
        }

        return RateLimitPatch(
            limitId: string(source["limitId"]),
            limitName: string(source["limitName"]),
            planType: string(source["planType"]),
            primary: decodeWindowPatch(source["primary"]),
            secondary: decodeWindowPatch(source["secondary"]),
            gptReserveWeekly: decodeGPTReserveWindowPatch(from: params),
            individualLimit: decodeSpendControlPatch(source["individualLimit"]),
            rateLimitReachedType: string(source["rateLimitReachedType"]),
            spendControlReached: source["spendControlReached"] as? Bool
        )
    }

    private static func codexLimitObject(from result: [String: Any]) -> [String: Any]? {
        guard let buckets = result["rateLimitsByLimitId"] as? [String: Any] else { return nil }
        return buckets["codex"] as? [String: Any]
    }

    /// Decode the optional reserve/model bucket without treating arbitrary
    /// multi-bucket rate limits as the user's shared Codex quota. The App
    /// Server currently calls this bucket `base_model_inference` and exposes
    /// the display name `gpt-reserve`; both identifiers are accepted to keep
    /// the client tolerant of either wire representation.
    private static func decodeGPTReserveWindow(from result: [String: Any]) -> RateLimitWindow? {
        guard let buckets = result["rateLimitsByLimitId"] as? [String: Any],
              let bucket = gptReserveBucket(from: buckets) else { return nil }
        return decodeWindow(bucket["primary"]) ?? decodeWindow(bucket["secondary"])
    }

    private static func decodeGPTReserveWindowPatch(from params: [String: Any]) -> RateLimitWindowPatch? {
        guard let buckets = params["rateLimitsByLimitId"] as? [String: Any],
              let bucket = gptReserveBucket(from: buckets) else { return nil }
        return decodeWindowPatch(bucket["primary"]) ?? decodeWindowPatch(bucket["secondary"])
    }

    private static func gptReserveBucket(from buckets: [String: Any]) -> [String: Any]? {
        let preferredKeys = ["base_model_inference", "gpt-reserve", "gpt_reserve"]
        for preferredKey in preferredKeys {
            if let value = buckets[preferredKey] as? [String: Any] {
                return value
            }
        }

        return buckets.first { key, value in
            guard let bucket = value as? [String: Any] else { return false }
            let identifiers = [
                key,
                string(bucket["limitId"]),
                string(bucket["limitName"])
            ].compactMap { $0?.lowercased() }
            return identifiers.contains { identifier in
                let compact = identifier.replacingOccurrences(of: "-", with: "")
                    .replacingOccurrences(of: "_", with: "")
                    .replacingOccurrences(of: " ", with: "")
                return compact.contains("gptreserve") || compact.contains("basemodelinference")
            }
        }?.value as? [String: Any]
    }

    private static func mergedLimitObject(legacy: [String: Any], codexBucket: [String: Any]?) -> [String: Any]? {
        guard !legacy.isEmpty || codexBucket != nil else { return nil }
        var merged = legacy
        if let codexBucket {
            for (key, value) in codexBucket {
                merged[key] = value
            }
        }
        return merged
    }

    private static func decodeWindow(_ value: Any?) -> RateLimitWindow? {
        guard let patch = decodeWindowPatch(value), let used = patch.usedPercent else { return nil }
        return RateLimitWindow(
            usedPercent: used,
            resetsAt: patch.resetsAt,
            windowDurationMins: patch.windowDurationMins
        )
    }

    private static func decodeWindowPatch(_ value: Any?) -> RateLimitWindowPatch? {
        guard let object = value as? [String: Any] else { return nil }
        return RateLimitWindowPatch(
            usedPercent: int(object["usedPercent"]),
            resetsAt: int64(object["resetsAt"]),
            windowDurationMins: int64(object["windowDurationMins"])
        )
    }

    private static func decodeSpendControl(_ value: Any?) -> SpendControlLimit? {
        guard let patch = decodeSpendControlPatch(value),
              let limit = patch.limit,
              let used = patch.used,
              let remaining = patch.remainingPercent,
              let resetsAt = patch.resetsAt else { return nil }
        return SpendControlLimit(
            limit: limit,
            used: used,
            remainingPercent: max(0, min(100, remaining)),
            resetsAt: resetsAt
        )
    }

    private static func decodeSpendControlPatch(_ value: Any?) -> SpendControlPatch? {
        guard let object = value as? [String: Any] else { return nil }
        return SpendControlPatch(
            limit: string(object["limit"]),
            used: string(object["used"]),
            remainingPercent: int(object["remainingPercent"]),
            resetsAt: int64(object["resetsAt"])
        )
    }

    private static func decodeResetCredits(_ value: Any?) -> RateLimitResetCredits? {
        guard let object = value as? [String: Any] else { return nil }
        let availableCount = int(object["availableCount"]) ?? 0
        let credits: [RateLimitResetCredit]?
        if let rawCredits = object["credits"] as? [Any] {
            credits = rawCredits.compactMap { raw -> RateLimitResetCredit? in
            guard let credit = raw as? [String: Any], let id = string(credit["id"]), !id.isEmpty else { return nil }
            return RateLimitResetCredit(
                id: id,
                resetType: string(credit["resetType"]),
                status: string(credit["status"]),
                grantedAt: int64(credit["grantedAt"]),
                expiresAt: int64(credit["expiresAt"]),
                title: string(credit["title"]),
                description: string(credit["description"])
            )
            }
        } else {
            credits = nil
        }
        return RateLimitResetCredits(availableCount: max(0, availableCount), credits: credits)
    }

    private static func string(_ value: Any?) -> String? { value as? String }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }
}

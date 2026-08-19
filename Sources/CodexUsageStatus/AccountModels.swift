import Foundation

enum AccountHealthState: Equatable {
    case idle
    case loading
    case loaded
    case offline
    case unsupported
    case error

    var displayName: String {
        switch self {
        case .idle: return "尚未取得"
        case .loading: return "同步中…"
        case .loaded: return "已同步"
        case .offline: return "離線，保留最後資料"
        case .unsupported: return "此登入模式不支援帳號資料"
        case .error: return "帳號資料讀取錯誤"
        }
    }
}

struct AccountIdentity: Equatable {
    let accountType: String?
    let authMode: String?
    let planType: String?
    let email: String?
    let requiresOpenAIAuth: Bool
}

struct AccountHealthSnapshot: Equatable {
    let identity: AccountIdentity
    let receivedAt: Date
    let connectionState: ConnectionState

    func applying(authMode: String?) -> AccountHealthSnapshot {
        guard let authMode else { return self }
        let updated = AccountIdentity(accountType: identity.accountType, authMode: authMode, planType: identity.planType, email: identity.email, requiresOpenAIAuth: identity.requiresOpenAIAuth)
        return AccountHealthSnapshot(identity: updated, receivedAt: receivedAt, connectionState: connectionState)
    }
}

enum AccountDataCodec {
    enum CodecError: Error, LocalizedError {
        case invalidObject

        var errorDescription: String? {
            switch self {
            case .invalidObject: return "account/read 回應不是有效的 JSON object"
            }
        }
    }

    static func decode(from result: Any, receivedAt: Date = Date(), connectionState: ConnectionState = .connected) throws -> AccountHealthSnapshot {
        guard let object = result as? [String: Any] else { throw CodecError.invalidObject }
        let account = object["account"] as? [String: Any]
        let identity = AccountIdentity(
            accountType: string(account?["type"]),
            authMode: string(object["authMode"]) ?? string(account?["authMode"]),
            planType: string(account?["planType"]) ?? string(object["planType"]),
            email: string(account?["email"]),
            requiresOpenAIAuth: (object["requiresOpenaiAuth"] as? Bool) ?? (object["requiresOpenAIAuth"] as? Bool) ?? false
        )
        return AccountHealthSnapshot(identity: identity, receivedAt: receivedAt, connectionState: connectionState)
    }

    static func merge(_ current: AccountHealthSnapshot?, params: Any, receivedAt: Date = Date()) -> AccountHealthSnapshot? {
        guard let object = params as? [String: Any] else { return current }
        let base = current?.identity ?? AccountIdentity(accountType: nil, authMode: nil, planType: nil, email: nil, requiresOpenAIAuth: false)
        let identity = AccountIdentity(
            accountType: base.accountType,
            authMode: string(object["authMode"]) ?? base.authMode,
            planType: string(object["planType"]) ?? base.planType,
            email: base.email,
            requiresOpenAIAuth: base.requiresOpenAIAuth
        )
        return AccountHealthSnapshot(identity: identity, receivedAt: receivedAt, connectionState: .connected)
    }

    private static func string(_ value: Any?) -> String? { value as? String }
}

enum TurnActivityState: Equatable {
    case idle
    case active
    case completed
    case failed
    case interrupted
    case unknown

    var displayName: String {
        switch self {
        case .idle: return "目前沒有執行中的 turn"
        case .active: return "執行中"
        case .completed: return "已完成"
        case .failed: return "失敗"
        case .interrupted: return "已中斷"
        case .unknown: return "等待狀態同步"
        }
    }
}

struct TurnActivitySnapshot: Equatable {
    var state: TurnActivityState
    var threadID: String?
    var turnID: String?
    var startedAt: Date?
    var completedAt: Date?
    var elapsedSeconds: Int64?
    var tokenTotal: Int64?
    var content: String?
    var errorMessage: String?
    var receivedAt: Date

    static let idle = TurnActivitySnapshot(
        state: .idle, threadID: nil, turnID: nil, startedAt: nil,
        completedAt: nil, elapsedSeconds: nil, tokenTotal: nil,
        content: nil, errorMessage: nil, receivedAt: Date()
    )

    static func unknownSnapshot(receivedAt: Date = Date()) -> TurnActivitySnapshot {
        TurnActivitySnapshot(
            state: .unknown, threadID: nil, turnID: nil, startedAt: nil,
            completedAt: nil, elapsedSeconds: nil, tokenTotal: nil,
            content: nil, errorMessage: nil, receivedAt: receivedAt
        )
    }
}

enum TurnActivityCodec {
    static func decodeEvent(method: String, params: Any, receivedAt: Date = Date()) -> TurnActivitySnapshot? {
        guard let object = params as? [String: Any],
              let threadID = object["threadId"] as? String,
              let turn = object["turn"] as? [String: Any],
              let turnID = turn["id"] as? String else { return nil }
        let status = turn["status"] as? String
        let state: TurnActivityState
        switch method {
        case "turn/started": state = .active
        case "turn/completed":
            switch status {
            case "failed": state = .failed
            case "interrupted": state = .interrupted
            default: state = .completed
            }
        default: state = .unknown
        }
        let started = int64(turn["startedAt"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let completed = int64(turn["completedAt"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let duration = int64(turn["durationMs"]).map { max(0, $0 / 1000) }
            ?? (started.flatMap { start in completed.map { end in max(0, Int64(end.timeIntervalSince(start))) } })
        let error = (turn["error"] as? [String: Any])?["message"] as? String
        return TurnActivitySnapshot(
            state: state,
            threadID: threadID,
            turnID: turnID,
            startedAt: started,
            completedAt: completed,
            elapsedSeconds: duration,
            tokenTotal: nil,
            content: extractContent(from: turn["items"]),
            errorMessage: error,
            receivedAt: receivedAt
        )
    }

    static func decodeTokenUsage(params: Any, receivedAt: Date = Date()) -> (threadID: String, turnID: String, tokenTotal: Int64?)? {
        guard let object = params as? [String: Any],
              let threadID = object["threadId"] as? String,
              let turnID = object["turnId"] as? String else { return nil }
        let usage = object["tokenUsage"] as? [String: Any]
        let total = usage?["total"] as? [String: Any]
        return (threadID, turnID, int64(total?["totalTokens"]))
    }

    private static func extractContent(from raw: Any?) -> String? {
        guard let items = raw as? [Any] else { return nil }
        let parts = items.compactMap { item -> String? in
            guard let object = item as? [String: Any] else { return nil }
            if let text = object["text"] as? String { return text }
            guard object["type"] as? String == "userMessage",
                  let content = object["content"] as? [Any] else { return nil }
            return content.compactMap { part in
                if let string = part as? String { return string }
                if let partObject = part as? [String: Any] { return partObject["text"] as? String }
                return nil
            }.joined(separator: "\n")
        }
        let value = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }
}

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

    /// Account reads also refresh their timestamp on every poll.  Identity and
    /// connection state are the downstream-relevant fields; an unchanged
    /// account must not re-drive profile and SwiftUI projections.
    func hasSameContent(as other: AccountHealthSnapshot) -> Bool {
        identity == other.identity && connectionState == other.connectionState
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
    /// The user-visible local thread/program name, when Codex has recorded
    /// one in its metadata-only session index.  This is intentionally kept
    /// separate from prompt/conversation content.
    var programName: String? = nil
    var repositoryDisplayName: String? = nil
    var workspaceDisplayName: String? = nil

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

/// Stable in-memory key for one observed execution. The physical rollout root
/// remains part of identity so two profiles cannot be collapsed by thread ID.
struct CodexExecutionKey: Hashable, Equatable, Sendable {
    let profileID: UUID?
    let normalizedPhysicalRootPath: String
    let threadID: String
    let turnID: String
    /// Stable, non-display repository identity carried from the rollout
    /// session metadata. The physical root remains authoritative for
    /// worktree isolation; this digest prevents same-named repositories from
    /// being treated as the same identity when the root is shared.
    let repositoryIdentityDigest: String?

    init(
        profileID: UUID?,
        normalizedPhysicalRootPath: String,
        threadID: String,
        turnID: String,
        repositoryIdentityDigest: String? = nil
    ) {
        self.profileID = profileID
        self.normalizedPhysicalRootPath = normalizedPhysicalRootPath
        self.threadID = threadID
        self.turnID = turnID
        self.repositoryIdentityDigest = repositoryIdentityDigest
    }
}

/// Identity of one Repo/worktree scope for the active-execution projection.
/// Thread and Turn IDs intentionally do not participate: multiple Chats in
/// one physical worktree belong under the same Repo group, while two
/// worktrees remain distinct even when their display names are identical.
struct CodexExecutionScopeKey: Hashable, Equatable, Sendable {
    let profileID: UUID?
    let normalizedPhysicalRootPath: String
    let repositoryIdentityDigest: String?
}

struct CodexExecutionProjection: Identifiable, Equatable, Sendable {
    let key: CodexExecutionKey
    var repositoryDisplayName: String?
    var workspaceDisplayName: String?
    var chatName: String?
    var startedAt: Date
    var tokenTotal: Int64?
    var plan: TurnPlanSnapshot?
    var lastObservedAt: Date

    var id: CodexExecutionKey { key }
    /// An absent scope is an explicitly unproven identity, not an unnamed
    /// repository that may be merged with another worktree.
    var groupName: String { repositoryDisplayName ?? workspaceDisplayName ?? "工作區身份未證明" }
    var isRepository: Bool { repositoryDisplayName != nil }
    var scopeKey: CodexExecutionScopeKey {
        CodexExecutionProjectionPolicy.scopeKey(for: self)
    }
}

enum CodexExecutionProjectionPolicy {
    static func normalizedRootPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Returns a safe, identity-bound Chat name update for an observed
    /// execution. A later metadata event may carry a renamed thread, but an
    /// unproven identity or an empty name must never overwrite what is
    /// already rendered.
    static func updatedChatName(
        current: String?,
        incoming: String?,
        identityProven: Bool
    ) -> String? {
        guard identityProven, let incoming else { return current }
        let normalized = incoming
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return current }
        return normalized
    }

    /// Computes elapsed execution time from the clock supplied by the
    /// presentation layer. Keeping this pure lets the compact execution row
    /// use a local TimelineView without coupling it to the ViewModel's slower
    /// display cadence.
    static func elapsedSeconds(startedAt: Date, now: Date) -> Int64 {
        max(0, Int64(now.timeIntervalSince(startedAt)))
    }

    static func key(for event: CodexLocalTurnActivityEvent) -> CodexExecutionKey {
        CodexExecutionKey(
            profileID: event.profileID,
            normalizedPhysicalRootPath: normalizedRootPath(event.physicalRootURL),
            threadID: event.threadID,
            turnID: event.turnID,
            repositoryIdentityDigest: event.sessionIdentity?.repositoryIdentityDigest
        )
    }

    static func keyWithoutRepositoryIdentity(for event: CodexLocalTurnActivityEvent) -> CodexExecutionKey {
        CodexExecutionKey(
            profileID: event.profileID,
            normalizedPhysicalRootPath: normalizedRootPath(event.physicalRootURL),
            threadID: event.threadID,
            turnID: event.turnID
        )
    }

    /// Returns the active rows that represent the same physical Turn without
    /// requiring repository identity. This is intentionally narrower than a
    /// display-name match: profile, physical root, thread, and Turn are the
    /// only fields safe to use when a terminal event has no repository digest.
    static func partialMatches(
        for event: CodexLocalTurnActivityEvent,
        in executions: [CodexExecutionProjection]
    ) -> [Int] {
        let root = normalizedRootPath(event.physicalRootURL)
        return executions.indices.filter { index in
            let execution = executions[index]
            return execution.key.profileID == event.profileID
                && execution.key.normalizedPhysicalRootPath == root
                && execution.key.threadID == event.threadID
                && execution.key.turnID == event.turnID
        }
    }

    /// A terminal event with a complete key removes the exact row. If the
    /// exact key differs only because the active row was admitted before
    /// repository metadata was proven, it may retire one and only one
    /// matching physical Turn. Ambiguous partial matches are left untouched
    /// so identity safety wins over eager cleanup.
    static func terminalMatchIndices(
        for event: CodexLocalTurnActivityEvent,
        in executions: [CodexExecutionProjection]
    ) -> [Int] {
        let exactKey = key(for: event)
        let exactMatches = executions.indices.filter { executions[$0].key == exactKey }
        if !exactMatches.isEmpty { return exactMatches }
        // A Turn may have been admitted from an early token/start event before
        // the rollout's session metadata exposed its repository digest.  A
        // later terminal event can therefore carry a complete digest while
        // the active projection still has a nil one.  Do not use this fallback
        // to retire a row that already has a different proven digest: the
        // physical tuple alone cannot override that stronger identity claim.
        let partial = partialMatches(for: event, in: executions).filter { index in
            guard let terminalDigest = event.sessionIdentity?.repositoryIdentityDigest else {
                return true
            }
            return executions[index].key.repositoryIdentityDigest == nil
                || executions[index].key.repositoryIdentityDigest == terminalDigest
        }
        return partial.count == 1 ? partial : []
    }

    static func scopeKey(for execution: CodexExecutionProjection) -> CodexExecutionScopeKey {
        CodexExecutionScopeKey(
            profileID: execution.key.profileID,
            normalizedPhysicalRootPath: execution.key.normalizedPhysicalRootPath,
            repositoryIdentityDigest: execution.key.repositoryIdentityDigest
        )
    }

    static func sorted(_ executions: [CodexExecutionProjection]) -> [CodexExecutionProjection] {
        executions.sorted {
            if $0.groupName != $1.groupName { return $0.groupName.localizedStandardCompare($1.groupName) == .orderedAscending }
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            if $0.key.threadID != $1.key.threadID { return $0.key.threadID < $1.key.threadID }
            return $0.key.turnID < $1.key.turnID
        }
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

    static func decodeTokenUsage(params: Any, receivedAt: Date = Date()) -> (
        threadID: String,
        turnID: String,
        tokenTotal: Int64?
    )? {
        guard let object = params as? [String: Any],
              let threadID = object["threadId"] as? String,
              let turnID = object["turnId"] as? String else { return nil }
        let usage = object["tokenUsage"] as? [String: Any]
        let total = usage?["total"] as? [String: Any]
        return (
            threadID,
            turnID,
            int64(total?["totalTokens"])
        )
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

import Foundation

enum CodexChatExecutionState: String, Equatable, Sendable {
    case running
    case waiting
    case toolRunning
    case completed
    case failed
    case interrupted

    var displayName: String {
        switch self {
        case .running: return "執行中"
        case .waiting: return "等待中"
        case .toolRunning: return "工具執行中"
        case .completed: return "已完成"
        case .failed: return "失敗"
        case .interrupted: return "已中斷"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .interrupted: return true
        case .running, .waiting, .toolRunning: return false
        }
    }
}

enum CodexExecutionModelSource: String, Codable, Equatable, Sendable {
    case sessionMetadata
    case turnContext
}

enum CodexExecutionModelConfidence: String, Codable, Equatable, Sendable {
    case observed
    case unavailable
}

struct CodexExecutionModelMetadata: Codable, Equatable, Sendable {
    let displayName: String?
    let source: CodexExecutionModelSource
    let confidence: CodexExecutionModelConfidence
    var reasoningEffort: String? = nil

    static let unavailable = CodexExecutionModelMetadata(
        displayName: nil,
        source: .sessionMetadata,
        confidence: .unavailable
    )

    var displayText: String {
        guard let displayName else { return "模型未取得" }
        return reasoningEffort.map { "\(displayName) · \($0)" } ?? displayName
    }

    var provenanceText: String {
        guard confidence == .observed else { return "尚無可靠本地模型資料" }
        return source == .turnContext
            ? "本地 turn_context.model / effort；觀測值"
            : "本地 session_meta；觀測值"
    }
}

struct CodexTokenUsageRateSample: Equatable, Sendable {
    let observedAt: Date
    let tokenTotal: Int64
}

enum CodexTokenUsageRate: Equatable, Sendable {
    case calculating
    case unavailable
    case measured(tokensPerSecond: Double, intervalSeconds: Double)

    var displayText: String {
        switch self {
        case .calculating: return "計算中"
        case .unavailable: return "—"
        case .measured(let value, _):
            if value >= 1_000_000 {
                return String(format: "%.1fM tok/s", locale: Locale(identifier: "en_US_POSIX"), value / 1_000_000)
            }
            if value >= 1_000 {
                return String(format: "%.1fK tok/s", locale: Locale(identifier: "en_US_POSIX"), value / 1_000)
            }
            return String(format: "%.1f tok/s", locale: Locale(identifier: "en_US_POSIX"), value)
        }
    }
}

/// Total-token usage, measured between factual rollout timestamps. This is
/// not output generation speed. Both the time span and allocation are bounded.
struct CodexTokenUsageRateWindow: Equatable, Sendable {
    static let retentionSeconds: TimeInterval = 180
    static let minimumIntervalSeconds: TimeInterval = 60
    static let maximumSampleCount = 512
    private(set) var samples: [CodexTokenUsageRateSample] = []

    mutating func record(tokenTotal: Int64, observedAt: Date) {
        guard tokenTotal >= 0 else { return }
        if let latest = samples.last {
            guard observedAt >= latest.observedAt else { return }
            if tokenTotal < latest.tokenTotal {
                samples.removeAll(keepingCapacity: true)
            } else if observedAt == latest.observedAt {
                samples.removeLast()
            }
        }
        samples.append(.init(observedAt: observedAt, tokenTotal: tokenTotal))
        let cutoff = observedAt.addingTimeInterval(-Self.retentionSeconds)
        samples.removeAll { $0.observedAt < cutoff }
        if samples.count > Self.maximumSampleCount {
            samples.removeFirst(samples.count - Self.maximumSampleCount)
        }
    }

    func rate(at now: Date) -> CodexTokenUsageRate {
        guard let latest = samples.last else { return .calculating }
        guard now.timeIntervalSince(latest.observedAt) <= Self.retentionSeconds else { return .unavailable }
        // Use actual samples only. A sparse window may cover less than 180s;
        // never invent a token total at the boundary or a zero-rate heartbeat.
        let cutoff = latest.observedAt.addingTimeInterval(-Self.retentionSeconds)
        guard let baseline = samples.first(where: { $0.observedAt >= cutoff }) else { return .unavailable }
        let interval = latest.observedAt.timeIntervalSince(baseline.observedAt)
        guard interval >= Self.minimumIntervalSeconds else { return .calculating }
        return .measured(
            tokensPerSecond: Double(latest.tokenTotal - baseline.tokenTotal) / interval,
            intervalSeconds: interval
        )
    }
}

/// Stable Chat identity. `turnID` is deliberately absent so a rerun updates
/// the same HUD card with fresh run metrics.
struct CodexChatExecutionKey: Hashable, Equatable, Sendable {
    let profileID: UUID?
    let normalizedPhysicalRootPath: String
    let threadID: String
    let repositoryIdentityDigest: String?

    init(
        profileID: UUID?,
        normalizedPhysicalRootPath: String,
        threadID: String,
        repositoryIdentityDigest: String? = nil
    ) {
        self.profileID = profileID
        self.normalizedPhysicalRootPath = normalizedPhysicalRootPath
        self.threadID = threadID
        self.repositoryIdentityDigest = repositoryIdentityDigest
    }
}

struct CodexChatExecutionTracking: Identifiable, Equatable, Sendable {
    var key: CodexChatExecutionKey
    var turnID: String
    var repositoryDisplayName: String?
    var workspaceDisplayName: String?
    var chatName: String?
    var model: CodexExecutionModelMetadata
    var state: CodexChatExecutionState
    var startedAt: Date
    var completedAt: Date?
    var tokenTotal: Int64?
    var plan: TurnPlanSnapshot?
    var lastObservedAt: Date
    var presentationLineage: CodexLocalSessionLineage?
    var tokenRateWindow = CodexTokenUsageRateWindow()

    var id: CodexChatExecutionKey { key }

    var groupName: String {
        repositoryDisplayName ?? workspaceDisplayName ?? "工作區身份未證明"
    }

    var isRepository: Bool {
        repositoryDisplayName != nil
    }

    var executionProjection: CodexExecutionProjection {
        CodexExecutionProjection(
            key: CodexExecutionKey(
                profileID: key.profileID,
                normalizedPhysicalRootPath: key.normalizedPhysicalRootPath,
                threadID: key.threadID,
                turnID: turnID,
                repositoryIdentityDigest: key.repositoryIdentityDigest
            ),
            repositoryDisplayName: repositoryDisplayName,
            workspaceDisplayName: workspaceDisplayName,
            chatName: chatName,
            startedAt: startedAt,
            tokenTotal: tokenTotal,
            plan: plan,
            lastObservedAt: lastObservedAt,
            presentationLineage: presentationLineage
        )
    }
}

struct CodexDismissedChatTurn: Equatable, Sendable {
    let turnID: String
    let observedAt: Date
}

struct CodexChatTrackingState: Equatable, Sendable {
    var cards: [CodexChatExecutionTracking] = []
    var dismissedTurns: [CodexChatExecutionKey: CodexDismissedChatTurn] = [:]
}

enum CodexChatExecutionTrackingPolicy {
    /// Admission requires top-level user provenance and either a live start
    /// or an observer-verified active Turn recovered after a reset.
    static func applying(
        _ event: CodexLocalTurnActivityEvent,
        to current: CodexChatTrackingState
    ) -> CodexChatTrackingState {
        var result = current
        let incomingKey = key(for: event)
        let matches = result.cards.indices.filter { compatible(result.cards[$0], with: incomingKey) }
        guard matches.count <= 1 else { return current }
        let index = matches.first
        if let index, event.observedAt < result.cards[index].lastObservedAt { return current }

        if event.presentationLineage?.isKnownInternalExecution == true {
            if let index { result.cards.remove(at: index) }
            return result
        }
        let dismissed = result.dismissedTurns.filter { compatible($0.key, with: incomingKey) }
        let recoversActiveTurn = event.activeTurnRecovery?.accepts(event) == true
        if !dismissed.isEmpty {
            guard event.kind == .started || recoversActiveTurn,
                  dismissed.values.allSatisfy({ $0.turnID != event.turnID && event.observedAt > $0.observedAt }) else {
                return current
            }
        }

        if event.kind == .started || recoversActiveTurn {
            guard event.sessionIdentity?.threadID == event.threadID,
                  event.presentationLineage?.isTopLevelUserChat == true else { return current }
            if let index, result.cards[index].turnID == event.turnID {
                // Replayed/duplicate starts must not reset samples, resurrect
                // a terminal run, or reopen a dismissed run.
                return current
            }
            dismissed.keys.forEach { result.dismissedTurns.removeValue(forKey: $0) }
            let previous = index.map { result.cards[$0] }
            var card = CodexChatExecutionTracking(
                key: previous.map { mergedKey(current: $0.key, incoming: incomingKey) } ?? incomingKey,
                turnID: event.turnID,
                repositoryDisplayName: event.sessionIdentity?.repositoryDisplayName ?? previous?.repositoryDisplayName,
                workspaceDisplayName: event.sessionIdentity?.workspaceDisplayName ?? previous?.workspaceDisplayName,
                chatName: CodexExecutionProjectionPolicy.updatedChatName(
                    current: previous?.chatName, incoming: event.programName, identityProven: true
                ),
                model: event.modelMetadata ?? .unavailable,
                state: .running,
                startedAt: event.startedAt ?? event.observedAt,
                completedAt: nil,
                tokenTotal: event.turnTokenTotal,
                plan: nil,
                lastObservedAt: event.observedAt,
                presentationLineage: event.presentationLineage
            )
            if let total = event.turnTokenTotal { card.tokenRateWindow.record(tokenTotal: total, observedAt: event.observedAt) }
            if let index { result.cards[index] = card } else { result.cards.append(card) }
        } else {
            guard let index, result.cards[index].turnID == event.turnID else { return current }
            var card = result.cards[index]
            card.key = mergedKey(current: card.key, incoming: incomingKey)
            card.lastObservedAt = event.observedAt
            card.chatName = CodexExecutionProjectionPolicy.updatedChatName(
                current: card.chatName, incoming: event.programName,
                identityProven: event.sessionIdentity?.threadID == event.threadID
            )
            card.repositoryDisplayName = event.sessionIdentity?.repositoryDisplayName ?? card.repositoryDisplayName
            card.workspaceDisplayName = event.sessionIdentity?.workspaceDisplayName ?? card.workspaceDisplayName
            card.model = event.modelMetadata ?? card.model
            if let total = event.turnTokenTotal {
                card.tokenTotal = total
                card.tokenRateWindow.record(tokenTotal: total, observedAt: event.observedAt)
            }
            switch event.kind {
            case .completed: card.state = .completed
            case .failed: card.state = .failed
            case .interrupted: card.state = .interrupted
            case .started, .tokenUpdated, .metadataUpdated: break
            }
            if card.state.isTerminal, card.completedAt == nil {
                card.completedAt = event.completedAt ?? event.observedAt
            }
            result.cards[index] = card
        }
        result.cards = sorted(result.cards)
        return result
    }

    /// Projection-only dismissal. No execution, observer, or Codex API call.
    static func dismissing(_ key: CodexChatExecutionKey, in current: CodexChatTrackingState) -> CodexChatTrackingState {
        var result = current
        guard let card = result.cards.first(where: { $0.key == key }) else { return current }
        result.dismissedTurns[key] = .init(turnID: card.turnID, observedAt: card.lastObservedAt)
        result.cards.removeAll { $0.key == key }
        return result
    }

    static func key(for event: CodexLocalTurnActivityEvent) -> CodexChatExecutionKey {
        CodexChatExecutionKey(
            profileID: event.profileID,
            normalizedPhysicalRootPath: CodexExecutionProjectionPolicy.normalizedRootPath(event.physicalRootURL),
            threadID: event.threadID,
            repositoryIdentityDigest: event.sessionIdentity?.repositoryIdentityDigest
        )
    }

    static func compatible(
        _ card: CodexChatExecutionTracking,
        with key: CodexChatExecutionKey
    ) -> Bool {
        compatible(card.key, with: key)
    }

    static func compatible(
        _ lhs: CodexChatExecutionKey,
        with rhs: CodexChatExecutionKey
    ) -> Bool {
        lhs.profileID == rhs.profileID
            && lhs.normalizedPhysicalRootPath == rhs.normalizedPhysicalRootPath
            && lhs.threadID == rhs.threadID
            && (lhs.repositoryIdentityDigest == nil
                || rhs.repositoryIdentityDigest == nil
                || lhs.repositoryIdentityDigest == rhs.repositoryIdentityDigest)
    }

    /// Preserve the strongest identity evidence already attached to a card.
    /// A later event may omit session metadata, but it must not erase a
    /// repository digest that was already proven.
    static func mergedKey(
        current: CodexChatExecutionKey,
        incoming: CodexChatExecutionKey
    ) -> CodexChatExecutionKey {
        CodexChatExecutionKey(
            profileID: current.profileID ?? incoming.profileID,
            normalizedPhysicalRootPath: current.normalizedPhysicalRootPath,
            threadID: current.threadID,
            repositoryIdentityDigest: incoming.repositoryIdentityDigest ?? current.repositoryIdentityDigest
        )
    }

    static func sorted(_ cards: [CodexChatExecutionTracking]) -> [CodexChatExecutionTracking] {
        cards.sorted {
            if $0.state.isTerminal != $1.state.isTerminal {
                return !$0.state.isTerminal
            }
            if $0.groupName != $1.groupName {
                return $0.groupName.localizedStandardCompare($1.groupName) == .orderedAscending
            }
            if $0.startedAt != $1.startedAt {
                return $0.startedAt > $1.startedAt
            }
            return $0.key.threadID < $1.key.threadID
        }
    }
}

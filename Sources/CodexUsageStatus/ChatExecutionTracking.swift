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
}

enum CodexExecutionModelConfidence: String, Codable, Equatable, Sendable {
    case observed
    case unavailable
}

struct CodexExecutionModelMetadata: Codable, Equatable, Sendable {
    let displayName: String?
    let source: CodexExecutionModelSource
    let confidence: CodexExecutionModelConfidence

    static let unavailable = CodexExecutionModelMetadata(
        displayName: nil,
        source: .sessionMetadata,
        confidence: .unavailable
    )

    var displayText: String {
        displayName ?? "模型未取得"
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

enum CodexChatExecutionTrackingPolicy {
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

import Foundation
import CryptoKit

/// The subset of a Codex Desktop `token_usage_record` that is safe and useful
/// to feed into the existing machine-local ledger. The rollout/session file is
/// treated as an append-only, read-only observation source; it is never edited
/// or resumed by UsageStatus.
struct CodexLocalTokenUsageRecord: Equatable, Sendable {
    let threadID: String
    let turnID: String
    let cumulativeTokenTotal: Int64
    let lastCallTokenTotal: Int64?
    /// Turn-local total from `turn_token_usage.total_tokens`; this is the
    /// value safe to show on the active Turn card.
    let turnTokenTotal: Int64?
    let observedAt: Date
}

struct CodexLocalTurnCompletionRecord: Equatable, Sendable {
    let threadID: String
    let turnID: String
    let startedAt: Date
    let completedAt: Date
    let durationSeconds: Int64
}

enum CodexLocalTurnActivityEventKind: Equatable, Sendable {
    case started
    case tokenUpdated
    case metadataUpdated
    case completed
    case failed
    case interrupted
}

/// Metadata-only lifecycle evidence from a physical Codex Desktop rollout
/// root.  The root URL is intentionally retained so a managed profile can
/// never be confused with the default CODEX_HOME namespace.
struct CodexLocalTurnActivityEvent: Equatable, Sendable {
    let profileID: UUID?
    let physicalRootURL: URL
    let threadID: String
    let turnID: String
    let kind: CodexLocalTurnActivityEventKind
    let startedAt: Date?
    let completedAt: Date?
    let durationSeconds: Int64?
    let turnTokenTotal: Int64?
    let observedAt: Date
    /// Read from the metadata-only CODEX_HOME session index for terminal
    /// events. It is never copied into the local ledger or persisted by this
    /// observer.
    var programName: String? = nil
    /// Safe, metadata-only session identity derived from the rollout head.
    /// Raw paths and repository URLs are intentionally never exposed here.
    var sessionIdentity: CodexLocalSessionIdentity? = nil
    /// Rollout-head provenance used by HUD admission. This does not change
    /// lifecycle identity or terminal matching for the existing ledger.
    var presentationLineage: CodexLocalSessionLineage? = nil
    /// Runtime model metadata is presentation-only. It is never used for
    /// identity reconciliation or lifecycle admission.
    var modelMetadata: CodexExecutionModelMetadata? = nil
    /// A bounded metadata read proved this Turn started, has not terminated
    /// through the read snapshot, and still has fresh matching activity.
    var activeTurnRecovery: CodexLocalActiveTurnRecovery? = nil

    // Presentation attribution is intentionally not part of event identity.
    // A later session_meta line may enrich an already-observed execution, but
    // that must never change lifecycle/token reconciliation semantics.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.profileID == rhs.profileID
            && lhs.physicalRootURL == rhs.physicalRootURL
            && lhs.threadID == rhs.threadID
            && lhs.turnID == rhs.turnID
            && lhs.kind == rhs.kind
            && lhs.startedAt == rhs.startedAt
            && lhs.completedAt == rhs.completedAt
            && lhs.durationSeconds == rhs.durationSeconds
            && lhs.turnTokenTotal == rhs.turnTokenTotal
            && lhs.observedAt == rhs.observedAt
            && lhs.programName == rhs.programName
            && lhs.sessionIdentity == rhs.sessionIdentity
            && lhs.activeTurnRecovery == rhs.activeTurnRecovery
    }
}

struct CodexLocalActiveTurnRecovery: Equatable, Sendable {
    static let activityFreshness: TimeInterval = 180
    let turnID: String
    let startedAt: Date
    let latestActivityAt: Date
    let verifiedAt: Date

    func accepts(_ event: CodexLocalTurnActivityEvent) -> Bool {
        let age = verifiedAt.timeIntervalSince(latestActivityAt)
        return event.kind == .tokenUpdated
            && event.turnID == turnID
            && event.startedAt == startedAt
            && event.observedAt == latestActivityAt
            && event.turnTokenTotal.map({ $0 >= 0 }) == true
            && startedAt <= latestActivityAt
            && age >= 0 && age <= Self.activityFreshness
    }
}

enum CodexLocalSessionThreadSource: String, Codable, Equatable, Sendable {
    case user
    case subagent
    case guardianReview
    case agentCreatedThread
    case unknown

    static func parse(_ raw: String?) -> Self {
        switch raw {
        case "user": return .user
        case "subagent": return .subagent
        case "guardian_review", "guardianReview": return .guardianReview
        case "agent_created_thread", "agentCreatedThread": return .agentCreatedThread
        default: return .unknown
        }
    }
}

enum CodexLocalSessionRelationKind: String, Codable, Equatable, Sendable {
    case threadSpawn
    case guardian
    case unknown
}

/// Metadata-only parent/agent attribution cached with the first session
/// identity so a tail-only scan cannot lose the admission classification.
struct CodexLocalSessionLineage: Codable, Equatable, Sendable {
    let parentThreadID: String?
    let threadSource: CodexLocalSessionThreadSource
    let relationKind: CodexLocalSessionRelationKind
    let agentRole: String?

    var isChildExecution: Bool {
        parentThreadID != nil
            && (threadSource == .subagent || threadSource == .guardianReview)
    }

    var isTopLevelUserChat: Bool {
        threadSource == .user && parentThreadID == nil && relationKind == .unknown
    }

    var isKnownInternalExecution: Bool {
        parentThreadID != nil || relationKind != .unknown
            || threadSource == .subagent || threadSource == .guardianReview
            || threadSource == .agentCreatedThread
    }
}

struct CodexLocalSessionMetadata: Sendable {
    let identity: CodexLocalSessionIdentity?
    let lineage: CodexLocalSessionLineage?
    let modelMetadata: CodexExecutionModelMetadata?

    init(
        identity: CodexLocalSessionIdentity?,
        lineage: CodexLocalSessionLineage?,
        modelMetadata: CodexExecutionModelMetadata? = nil
    ) {
        self.identity = identity
        self.lineage = lineage
        self.modelMetadata = modelMetadata
    }
}

enum CodexLocalSessionIdentityKind: String, Codable, Equatable, Sendable {
    case repository
    case workspace
    case unknown
}

/// Ephemeral identity for an observed Codex session.  Only display-safe
/// components are retained; full cwd and origin URL never leave the parser.
struct CodexLocalSessionIdentity: Codable, Equatable, Sendable {
    let threadID: String
    let repositoryDisplayName: String?
    let workspaceDisplayName: String?
    let kind: CodexLocalSessionIdentityKind
    /// One-way identity for the canonical repository remote. This lets
    /// callers distinguish same-named repositories without retaining a raw
    /// remote URL in the projection model.
    let repositoryIdentityDigest: String?

    init(
        threadID: String,
        repositoryDisplayName: String?,
        workspaceDisplayName: String?,
        kind: CodexLocalSessionIdentityKind,
        repositoryIdentityDigest: String? = nil
    ) {
        self.threadID = threadID
        self.repositoryDisplayName = repositoryDisplayName
        self.workspaceDisplayName = workspaceDisplayName
        self.kind = kind
        self.repositoryIdentityDigest = repositoryIdentityDigest
    }

    var displayName: String? { repositoryDisplayName ?? workspaceDisplayName }
}

struct CodexLocalTurnContextMetadata: Codable, Equatable, Sendable {
    let turnID: String
    let model: CodexExecutionModelMetadata
    let observedAt: Date
}

enum CodexLocalExecutionIdentityResolution: String, Equatable, Sendable {
    case proven
    case ambiguous
    case notProven
}

/// Pure Repo ↔ Chat identity reconciliation. A session index name is only
/// usable after the rollout session identity and event thread are proven to
/// refer to the same thread.
struct CodexLocalExecutionIdentityReconciliation: Equatable, Sendable {
    let status: CodexLocalExecutionIdentityResolution
    let sessionIdentity: CodexLocalSessionIdentity?

    var isProven: Bool { status == .proven && sessionIdentity != nil }

    /// Unproven starts/tokens can remain visible as explicitly unnamed local
    /// observations. An unproven terminal event is never admitted because it
    /// could remove a different Chat's active execution.
    func acceptsActivity(kind: CodexLocalTurnActivityEventKind) -> Bool {
        isProven || kind == .started || kind == .tokenUpdated
    }

    static func resolve(
        sessionIdentities: [CodexLocalSessionIdentity],
        eventThreadID: String?
    ) -> CodexLocalExecutionIdentityReconciliation {
        guard let first = sessionIdentities.first else {
            return .init(status: .notProven, sessionIdentity: nil)
        }
        guard sessionIdentities.dropFirst().allSatisfy({ $0 == first }) else {
            return .init(status: .ambiguous, sessionIdentity: nil)
        }
        guard let eventThreadID, !eventThreadID.isEmpty, eventThreadID == first.threadID else {
            return .init(status: .ambiguous, sessionIdentity: nil)
        }
        return .init(status: .proven, sessionIdentity: first)
    }

    static func resolve(
        sessionIdentity: CodexLocalSessionIdentity?,
        eventThreadID: String?,
        sourceIsAmbiguous: Bool = false
    ) -> CodexLocalExecutionIdentityReconciliation {
        guard !sourceIsAmbiguous else {
            return .init(status: .ambiguous, sessionIdentity: nil)
        }
        guard let sessionIdentity else {
            return .init(status: .notProven, sessionIdentity: nil)
        }
        return resolve(sessionIdentities: [sessionIdentity], eventThreadID: eventThreadID)
    }
}

struct CodexLocalTurnObservationCapabilities: Equatable, Sendable {
    let started: Bool
    let tokenUsage: Bool
    let completed: Bool
    let failed: Bool
    let interrupted: Bool
    let content: Bool

    static let current = CodexLocalTurnObservationCapabilities(
        started: true,
        tokenUsage: true,
        completed: true,
        failed: true,
        interrupted: true,
        content: false
    )
}

enum CodexLocalUsageArtifactParser {
    private struct Usage: Decodable {
        let totalTokens: Int64?

        enum CodingKeys: String, CodingKey {
            case totalTokens = "total_tokens"
        }
    }

    private struct Payload: Decodable {
        let threadID: String?
        let turnID: String?
        let usage: Usage?
        let threadTokenUsage: Usage?
        let turnTokenUsage: Usage?

        enum CodingKeys: String, CodingKey {
            case threadID = "thread_id"
            case turnID = "turn_id"
            case usage
            case threadTokenUsage = "thread_token_usage"
            case turnTokenUsage = "turn_token_usage"
        }
    }

    private struct Envelope: Decodable {
        let timestamp: String?
        let type: String?
        let payload: Payload?
    }

    private struct TurnContextPayload: Decodable {
        let turnID: String?
        let model: String?
        let effort: String?
        enum CodingKeys: String, CodingKey {
            case turnID = "turn_id"
            case model
            case effort
        }
    }

    private struct TurnContextEnvelope: Decodable {
        let timestamp: String?
        let type: String?
        let payload: TurnContextPayload?
    }

    private struct LifecyclePayload: Decodable {
        let type: String?
        let threadID: String?
        let turnID: String?
        let startedAt: Double?
        let completedAt: Double?
        let durationMilliseconds: Double?
        let reason: String?
        let error: LifecycleError?

        enum CodingKeys: String, CodingKey {
            case type
            case threadID = "thread_id"
            case turnID = "turn_id"
            case startedAt = "started_at"
            case completedAt = "completed_at"
            case durationMilliseconds = "duration_ms"
            case reason
            case error
        }
    }

    private struct LifecycleError: Decodable {
        let message: String?
    }

    private struct LifecycleEnvelope: Decodable {
        let timestamp: String?
        let type: String?
        let payload: LifecyclePayload?
    }

    private struct SessionMetaPayload: Decodable {
        let id: String?
        let cwd: String?
        let git: GitMetadata?
        let model: String?
        let modelName: String?
        let parentThreadID: String?
        let threadSource: String?
        let source: SessionMetaSource?
        let agentRole: String?

        enum CodingKeys: String, CodingKey {
            case id
            case cwd
            case git
            case model
            case modelName = "model_name"
            case parentThreadID = "parent_thread_id"
            case threadSource = "thread_source"
            case source
            case agentRole = "agent_role"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decodeIfPresent(String.self, forKey: .id)
            cwd = try values.decodeIfPresent(String.self, forKey: .cwd)
            git = try values.decodeIfPresent(GitMetadata.self, forKey: .git)
            // Some Codex builds expose the model as `model`, others as
            // `model_name`. Treat non-string shapes as unavailable rather
            // than rejecting otherwise valid session identity metadata.
            model = try? values.decode(String.self, forKey: .model)
            modelName = try? values.decode(String.self, forKey: .modelName)
            parentThreadID = try values.decodeIfPresent(String.self, forKey: .parentThreadID)
            threadSource = try values.decodeIfPresent(String.self, forKey: .threadSource)
            source = try? values.decode(SessionMetaSource.self, forKey: .source)
            agentRole = try values.decodeIfPresent(String.self, forKey: .agentRole)
        }
    }

    private struct SessionMetaSource: Decodable {
        let subagent: SessionMetaSubagent?
    }

    private struct SessionMetaSubagent: Decodable {
        let other: String?
        let threadSpawn: SessionMetaThreadSpawn?

        enum CodingKeys: String, CodingKey {
            case other
            case threadSpawn = "thread_spawn"
        }
    }

    private struct SessionMetaThreadSpawn: Decodable {
        let parentThreadID: String?
        let agentRole: String?

        enum CodingKeys: String, CodingKey {
            case parentThreadID = "parent_thread_id"
            case agentRole = "agent_role"
        }
    }

    private struct GitMetadata: Decodable {
        let branch: String?
        let commitHash: String?
        let repositoryURL: String?

        enum CodingKeys: String, CodingKey {
            case branch
            case commitHash = "commit_hash"
            case repositoryURL = "repository_url"
        }
    }

    private struct SessionMetaEnvelope: Decodable {
        let type: String?
        let payload: SessionMetaPayload?
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func parseLine(_ data: Data) -> CodexLocalTokenUsageRecord? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.type == "token_usage_record",
              let payload = envelope.payload,
              let threadID = payload.threadID, !threadID.isEmpty,
              let turnID = payload.turnID, !turnID.isEmpty,
              let cumulative = payload.threadTokenUsage?.totalTokens
                ?? payload.turnTokenUsage?.totalTokens,
              cumulative >= 0,
              let timestamp = envelope.timestamp,
              let observedAt = iso8601Formatter.date(from: timestamp) else {
            return nil
        }
        let last = payload.usage?.totalTokens.flatMap { $0 >= 0 ? $0 : nil }
        return CodexLocalTokenUsageRecord(
            threadID: threadID,
            turnID: turnID,
            cumulativeTokenTotal: cumulative,
            lastCallTokenTotal: last,
            turnTokenTotal: payload.turnTokenUsage?.totalTokens.flatMap { $0 >= 0 ? $0 : nil },
            observedAt: observedAt
        )
    }

    static func parseTurnContext(_ data: Data) -> CodexLocalTurnContextMetadata? {
        guard let envelope = try? JSONDecoder().decode(TurnContextEnvelope.self, from: data),
              envelope.type == "turn_context",
              let payload = envelope.payload,
              let turnID = normalizedMetadataValue(payload.turnID, maxLength: 256),
              let modelName = normalizedMetadataValue(payload.model, maxLength: 128),
              let observedAt = envelope.timestamp.flatMap({ iso8601Formatter.date(from: $0) }) else { return nil }
        return CodexLocalTurnContextMetadata(
            turnID: turnID,
            model: CodexExecutionModelMetadata(
                displayName: modelName,
                source: .turnContext,
                confidence: .observed,
                reasoningEffort: normalizedMetadataValue(payload.effort, maxLength: 64)
            ),
            observedAt: observedAt
        )
    }

    static func parseSessionThreadID(_ data: Data) -> String? {
        parseSessionIdentity(data)?.threadID
    }

    static func parseSessionMetadata(_ data: Data) -> CodexLocalSessionMetadata? {
        guard let envelope = try? JSONDecoder().decode(SessionMetaEnvelope.self, from: data),
              envelope.type == "session_meta",
              let payload = envelope.payload,
              let id = payload.id,
              !id.isEmpty else { return nil }

        let workspace = Self.safeWorkspaceName(from: payload.cwd)
        let repository = Self.safeRepositoryName(from: payload.git?.repositoryURL)
        let repositoryIdentityDigest = Self.repositoryIdentityDigest(from: payload.git?.repositoryURL)
        let kind: CodexLocalSessionIdentityKind = repository != nil ? .repository : (workspace != nil ? .workspace : .unknown)
        let identity = CodexLocalSessionIdentity(
            threadID: id,
            repositoryDisplayName: repository,
            workspaceDisplayName: workspace,
            kind: kind,
            repositoryIdentityDigest: repositoryIdentityDigest
        )
        let nested = payload.source?.subagent
        let source: CodexLocalSessionThreadSource = {
            if let explicit = payload.threadSource {
                return CodexLocalSessionThreadSource.parse(explicit)
            }
            if let other = nested?.other {
                let parsed = CodexLocalSessionThreadSource.parse(other)
                if parsed != .unknown { return parsed }
            }
            if nested?.threadSpawn != nil { return .subagent }
            return .unknown
        }()
        let relation: CodexLocalSessionRelationKind =
            (nested?.other == "guardian" || nested?.other == "guardian_review")
                ? .guardian : (nested?.threadSpawn != nil ? .threadSpawn : .unknown)
        let parent = normalizedMetadataValue(payload.parentThreadID ?? nested?.threadSpawn?.parentThreadID, maxLength: 256)
        let role = normalizedMetadataValue(payload.agentRole ?? nested?.threadSpawn?.agentRole, maxLength: 128)
        let lineage: CodexLocalSessionLineage? = (parent != nil || source != .unknown || relation != .unknown)
            ? CodexLocalSessionLineage(parentThreadID: parent, threadSource: source, relationKind: relation, agentRole: role)
            : nil
        let modelName = normalizedMetadataValue(payload.modelName ?? payload.model, maxLength: 128)
        let modelMetadata = modelName.map {
            CodexExecutionModelMetadata(
                displayName: $0,
                source: .sessionMetadata,
                confidence: .observed
            )
        }
        return CodexLocalSessionMetadata(
            identity: identity,
            lineage: lineage,
            modelMetadata: modelMetadata
        )
    }

    static func parseSessionIdentity(_ data: Data) -> CodexLocalSessionIdentity? {
        parseSessionMetadata(data)?.identity
    }

    private static func normalizedMetadataValue(_ value: String?, maxLength: Int) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(maxLength))
    }

    private static func safeWorkspaceName(from raw: String?) -> String? {
        guard let raw else { return nil }
        let url = URL(fileURLWithPath: raw).standardizedFileURL
        let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "/", name != "." else { return nil }
        return name
    }

    private static func safeRepositoryName(from raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        var value = raw
        if let range = value.range(of: "#") { value.removeSubrange(range.lowerBound..<value.endIndex) }
        if let range = value.range(of: "?") { value.removeSubrange(range.lowerBound..<value.endIndex) }
        let component = value.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? value
        let name = component.hasSuffix(".git") ? String(component.dropLast(4)) : component
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized != ".", !normalized.contains("\\") else { return nil }
        return normalized
    }

    private static func repositoryIdentityDigest(from raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: "#") { value.removeSubrange(range.lowerBound..<value.endIndex) }
        if let range = value.range(of: "?") { value.removeSubrange(range.lowerBound..<value.endIndex) }

        // Normalize HTTPS and SCP-style Git remotes to a stable host/path
        // identity. Credentials and query/fragment data never participate.
        if value.hasPrefix("git@"), let separator = value.firstIndex(of: ":") {
            let hostStart = value.index(value.startIndex, offsetBy: 4)
            let host = String(value[hostStart..<separator]).lowercased()
            value = host + "/" + value[value.index(after: separator)...]
        } else if let components = URLComponents(string: value),
                  let host = components.host {
            value = host.lowercased() + components.path
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        if value.hasSuffix(".git") { value.removeLast(4) }
        guard !value.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func parseTurnCompletion(_ data: Data, threadID: String?) -> CodexLocalTurnCompletionRecord? {
        guard let event = parseTurnActivity(data, threadID: threadID),
              event.kind == .completed,
              let startedAt = event.startedAt,
              let completedAt = event.completedAt,
              let durationSeconds = event.durationSeconds else { return nil }

        return CodexLocalTurnCompletionRecord(
            threadID: event.threadID,
            turnID: event.turnID,
            startedAt: startedAt,
            completedAt: completedAt,
            durationSeconds: durationSeconds
        )
    }

    static func parseTurnActivity(_ data: Data, threadID: String?) -> (kind: CodexLocalTurnActivityEventKind, threadID: String, turnID: String, startedAt: Date?, completedAt: Date?, durationSeconds: Int64?, observedAt: Date)? {
        guard let threadID, !threadID.isEmpty,
              let envelope = try? JSONDecoder().decode(LifecycleEnvelope.self, from: data),
              envelope.type == "event_msg",
              let payload = envelope.payload,
              let turnID = payload.turnID,
              !turnID.isEmpty else { return nil }

        // Newer lifecycle records may carry their own thread_id. When
        // present it must agree with the rollout/session cursor; disagreement
        // is an identity contradiction and is rejected fail-closed.
        if let payloadThreadID = payload.threadID,
           payloadThreadID.isEmpty || payloadThreadID != threadID {
            return nil
        }

        let started = payload.startedAt.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
        let completed = payload.completedAt.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
        guard completed == nil || started == nil || completed! >= started! else { return nil }
        let durationSeconds: Int64?
        if let durationMilliseconds = payload.durationMilliseconds,
           durationMilliseconds.isFinite,
           durationMilliseconds >= 0 {
            durationSeconds = max(0, Int64((durationMilliseconds / 1_000).rounded(.down)))
        } else if let started, let completed {
            durationSeconds = max(0, Int64(completed.timeIntervalSince(started).rounded(.down)))
        } else {
            durationSeconds = nil
        }
        guard let observedAt = envelope.timestamp.flatMap({ iso8601Formatter.date(from: $0) })
                ?? completed
                ?? started else {
            // Lifecycle records are authority data only when the artifact
            // provides a factual timestamp.  Scan time is deliberately not
            // substituted because it would invent an event chronology.
            return nil
        }

        switch payload.type {
        case "task_started":
            return (.started, threadID, turnID, started, nil, nil, observedAt)
        case "task_complete":
            return (payload.error == nil ? .completed : .failed, threadID, turnID, started, completed, durationSeconds, observedAt)
        case "turn_aborted":
            guard payload.reason == "interrupted" else { return nil }
            return (.interrupted, threadID, turnID, started, completed, durationSeconds, observedAt)
        default:
            return nil
        }
    }
}

/// Read-only access to Codex's append-only session name index.  Codex keeps
/// thread names outside the rollout JSONL so a completion notification can
/// identify the finished work without reading prompt or conversation text.
enum CodexLocalSessionIndex {
    private struct Entry: Decodable {
        let id: String?
        let threadName: String?

        enum CodingKeys: String, CodingKey {
            case id
            case threadName = "thread_name"
        }
    }

    private struct CacheEntry {
        let fileSize: Int64?
        let modificationTime: Date?
        let fileResourceIdentifier: String?
        let names: [String: String?]
        let isComplete: Bool
        var lastAccess: UInt64
    }

    private static let cacheLock = NSLock()
    private static var cache: [String: CacheEntry] = [:]
    private static var accessCounter: UInt64 = 0
    private static let maximumCacheEntries = 32
    private static var fullReadCountStorage = 0

    static var fullReadCount: Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return fullReadCountStorage
    }

#if CODEX_USAGE_TESTING
    nonisolated(unsafe) static var testFullReadCount = 0

    static func resetTestCache() {
        cacheLock.lock()
        cache.removeAll()
        accessCounter = 0
        fullReadCountStorage = 0
        testFullReadCount = 0
        cacheLock.unlock()
    }
#endif

    static func threadName(for threadID: String, in codexHomeURL: URL) -> String? {
        guard !threadID.isEmpty else { return nil }
        let indexURL = codexHomeURL.appendingPathComponent("session_index.jsonl")
        let metadata = try? indexURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ])
        guard metadata?.isRegularFile == true else {
            cacheLock.lock()
            cache.removeValue(forKey: indexURL.path)
            cacheLock.unlock()
            return nil
        }

        let fileSize = metadata?.fileSize.map(Int64.init)
        let modificationTime = metadata?.contentModificationDate
        let fileResourceIdentifier = metadata?.fileResourceIdentifier.map { String(describing: $0) }
        let path = indexURL.path

        cacheLock.lock()
        if var cached = cache[path],
           cached.fileSize == fileSize,
           cached.modificationTime == modificationTime,
           cached.fileResourceIdentifier == fileResourceIdentifier,
           cached.isComplete || cached.names.keys.contains(threadID) {
            accessCounter &+= 1
            cached.lastAccess = accessCounter
            cache[path] = cached
            let hasThread = cached.names.keys.contains(threadID)
            let name = hasThread ? cached.names[threadID]! : nil
            cacheLock.unlock()
            return name
        }
        cacheLock.unlock()

        guard let data = try? Data(contentsOf: indexURL) else { return nil }
        var names: [String: String?] = [:]
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let entry = try? JSONDecoder().decode(Entry.self, from: Data(line)),
                  let id = entry.id,
                  !id.isEmpty else { continue }
            // The index is append-only. Assigning in file order means the
            // latest row remains authoritative, including an empty title.
            guard let rawName = entry.threadName else {
                // `nil` is a meaningful cached value here. `updateValue`
                // stores Optional.none as the dictionary value, whereas
                // `names[id] = nil` would remove the key and resurrect an
                // older title on a later lookup.
                names.updateValue(nil, forKey: id)
                continue
            }
            let name = rawName
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            names[id] = name.isEmpty ? nil : name
        }

        cacheLock.lock()
        accessCounter &+= 1
#if CODEX_USAGE_TESTING
        testFullReadCount += 1
#endif
        fullReadCountStorage += 1
        let isComplete = names.count <= 4_096
        var retainedNames = names
        if !isComplete {
            retainedNames = [:]
            if names.keys.contains(threadID) {
                retainedNames.updateValue(names[threadID]!, forKey: threadID)
            }
        }
        cache[path] = CacheEntry(
            fileSize: fileSize,
            modificationTime: modificationTime,
            fileResourceIdentifier: fileResourceIdentifier,
            names: retainedNames,
            isComplete: isComplete,
            lastAccess: accessCounter
        )
        if cache.count > maximumCacheEntries,
           let leastRecentlyUsed = cache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            cache.removeValue(forKey: leastRecentlyUsed)
        }
        let hasThread = names.keys.contains(threadID)
        let name = hasThread ? names[threadID]! : nil
        cacheLock.unlock()
        return name
    }
}

struct CodexLocalUsageObservationRoot: Equatable, Sendable {
    let profileID: UUID?
    let codexHomeURL: URL

    /// Resolves the one physical default CODEX_HOME namespace used by the
    /// local observer.  The default namespace intentionally retains a nil
    /// profile attribution even when the UI has selected an unmanaged profile.
    static func canonicalDefaultHomeURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let configured = environment["CODEX_HOME"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }
}

/// Pure authority checks shared by the observer projection and its tests.
/// Physical CODEX_HOME identity is part of the source boundary; a UUID alone
/// is never sufficient to accept a lifecycle event.
enum CodexLocalTurnActivityAuthority {
    static func normalizedRoot(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func sourceKey(profileID: UUID?, physicalRootURL: URL) -> String {
        let namespace = profileID?.uuidString ?? "default"
        return namespace + "|" + normalizedRoot(physicalRootURL).path
    }

    static func acceptsCurrentRoot(
        event: CodexLocalTurnActivityEvent,
        currentProfileID: UUID?,
        currentProfileIsManaged: Bool,
        managedHomeURL: URL?,
        defaultHomeURL: URL
    ) -> Bool {
        let eventRoot = normalizedRoot(event.physicalRootURL)
        if currentProfileIsManaged {
            guard let currentProfileID,
                  event.profileID == currentProfileID,
                  let managedHomeURL else { return false }
            return eventRoot == normalizedRoot(managedHomeURL)
        }

        // Unmanaged/default UI profiles still observe only the stable default
        // namespace, whose event profile attribution is intentionally nil.
        return event.profileID == nil && eventRoot == normalizedRoot(defaultHomeURL)
    }

    static func matchesActiveTurn(
        event: CodexLocalTurnActivityEvent,
        activeTurn: TurnActivitySnapshot,
        activeTurnSourceKey: String?,
        sourceKey: String
    ) -> Bool {
        activeTurn.state == .active
            && activeTurnSourceKey == sourceKey
            && activeTurn.threadID == event.threadID
            && activeTurn.turnID == event.turnID
    }

    static func acceptsTerminal(
        event: CodexLocalTurnActivityEvent,
        activeTurn: TurnActivitySnapshot,
        activeTurnSourceKey: String?,
        sourceKey: String
    ) -> Bool {
        switch event.kind {
        case .completed, .failed, .interrupted:
            return matchesActiveTurn(
                event: event,
                activeTurn: activeTurn,
                activeTurnSourceKey: activeTurnSourceKey,
                sourceKey: sourceKey
            )
        default:
            return false
        }
    }
}

/// Durable proof that a factual top-level user Turn was admitted from one
/// specific rollout. The path, root, resource, session identity, and lineage
/// are all bound so a copied or replaced file cannot borrow the proof.
struct CodexLocalActiveTurnEvidence: Codable, Equatable, Sendable {
    let threadID: String
    let turnID: String
    let startedAt: Date
    let startedEvidenceOffset: UInt64
    var lastValidatedOffset: UInt64
    var lastMatchingTokenAt: Date?
    var lastTurnTokenTotal: Int64?
    let rolloutPathIdentity: String
    let observationRootIdentity: String
    let resourceIdentifier: String
    let sessionIdentity: CodexLocalSessionIdentity
    let lineage: CodexLocalSessionLineage
    var turnContextMetadata: CodexLocalTurnContextMetadata?
}

struct CodexLocalUsageCursor: Codable, Equatable, Sendable {
    var byteOffset: UInt64
    var threadID: String?
    /// The first session identity observed for this rollout. Caching it in
    /// the cursor lets an unchanged, caught-up rollout avoid reopening and
    /// reparsing its head on every observer tick.
    var sessionIdentity: CodexLocalSessionIdentity?
    var sessionLineage: CodexLocalSessionLineage?
    /// Presentation-only session model metadata cached with the head identity
    /// so tail-only scans can continue to label the same Chat.
    var modelMetadata: CodexExecutionModelMetadata?
    var turnContextMetadata: CodexLocalTurnContextMetadata?
    /// Resource metadata used to validate the head-identity cache. Older
    /// cursor files decode these as nil and pay one compatibility read.
    var fileSize: UInt64?
    var modificationTime: Date?
    /// A resource identifier catches atomic replacement even when the new
    /// rollout happens to have the same size and modification timestamp.
    var fileResourceIdentifier: String?
    var completedTurnIDs: Set<String>
    var activeTurnEvidence: CodexLocalActiveTurnEvidence?
    /// Once a rollout contains contradictory session metadata, its identity
    /// remains ambiguous across incremental scans. This prevents a tail-only
    /// scan from restoring stale Repo/Chat provenance.
    var identityIsAmbiguous: Bool

    private enum CodingKeys: String, CodingKey {
        case byteOffset
        case threadID
        case sessionIdentity
        case sessionLineage
        case modelMetadata
        case turnContextMetadata
        case fileSize
        case modificationTime
        case fileResourceIdentifier
        case completedTurnIDs
        case activeTurnEvidence
        case identityIsAmbiguous
    }

    init(
        byteOffset: UInt64,
        threadID: String? = nil,
        sessionIdentity: CodexLocalSessionIdentity? = nil,
        sessionLineage: CodexLocalSessionLineage? = nil,
        modelMetadata: CodexExecutionModelMetadata? = nil,
        turnContextMetadata: CodexLocalTurnContextMetadata? = nil,
        fileSize: UInt64? = nil,
        modificationTime: Date? = nil,
        fileResourceIdentifier: String? = nil,
        completedTurnIDs: Set<String> = [],
        activeTurnEvidence: CodexLocalActiveTurnEvidence? = nil,
        identityIsAmbiguous: Bool = false
    ) {
        self.byteOffset = byteOffset
        self.threadID = threadID
        self.sessionIdentity = sessionIdentity
        self.sessionLineage = sessionLineage
        self.modelMetadata = modelMetadata
        self.turnContextMetadata = turnContextMetadata
        self.fileSize = fileSize
        self.modificationTime = modificationTime
        self.fileResourceIdentifier = fileResourceIdentifier
        self.completedTurnIDs = completedTurnIDs
        self.activeTurnEvidence = activeTurnEvidence
        self.identityIsAmbiguous = identityIsAmbiguous
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        byteOffset = try values.decode(UInt64.self, forKey: .byteOffset)
        threadID = try values.decodeIfPresent(String.self, forKey: .threadID)
        sessionIdentity = try values.decodeIfPresent(CodexLocalSessionIdentity.self, forKey: .sessionIdentity)
        sessionLineage = try values.decodeIfPresent(CodexLocalSessionLineage.self, forKey: .sessionLineage)
        modelMetadata = try values.decodeIfPresent(CodexExecutionModelMetadata.self, forKey: .modelMetadata)
        turnContextMetadata = try values.decodeIfPresent(CodexLocalTurnContextMetadata.self, forKey: .turnContextMetadata)
        fileSize = try values.decodeIfPresent(UInt64.self, forKey: .fileSize)
        modificationTime = try values.decodeIfPresent(Date.self, forKey: .modificationTime)
        fileResourceIdentifier = try values.decodeIfPresent(String.self, forKey: .fileResourceIdentifier)
        completedTurnIDs = try values.decodeIfPresent(Set<String>.self, forKey: .completedTurnIDs) ?? []
        // A damaged optional proof must fail closed without discarding the
        // rest of a legacy cursor or crashing observer startup.
        activeTurnEvidence = (try? values.decodeIfPresent(CodexLocalActiveTurnEvidence.self, forKey: .activeTurnEvidence)) ?? nil
        identityIsAmbiguous = try values.decodeIfPresent(Bool.self, forKey: .identityIsAmbiguous) ?? false
    }
}

struct CodexLocalUsageScanResult: Sendable {
    let events: [(profileID: UUID?, record: CodexLocalTokenUsageRecord)]
    let turnCompletions: [(profileID: UUID?, record: CodexLocalTurnCompletionRecord)]
    let turnActivities: [CodexLocalTurnActivityEvent]
    let cursors: [String: CodexLocalUsageCursor]
    let seededPaths: Set<String>
    let knownRolloutPaths: Set<String>
    let fastPollPaths: Set<String>
    let sessionIdentityReadCount: Int
    let metrics: CodexLocalUsageScanMetrics
}

struct CodexLocalUsageScanMetrics: Equatable, Sendable {
    let directoryEnumerationCount: Int
    let rolloutMetadataReadCount: Int
    let rolloutContentFileHandleOpenCount: Int
    let sessionIndexFullReadCount: Int
}

enum CodexLocalUsageDiscoveryProbeEvent: Sendable {
    case afterRootPreflight
    case beforeNamespace
    case afterNamespace
    case beforeRootFinalize
}

struct CodexLocalUsageDiscoveryRootIdentity: Equatable, Sendable {
    let resourceIdentifier: String
    let creationDate: Date?
}

/// Bounded reconciliation metadata emitted by the existing rollout scan. It
/// does not persist an active-execution database or introduce another timer;
/// it tells the projection when an observation epoch changed and which roots
/// are no longer authoritative.
struct CodexLocalActiveExecutionReconciliation: Equatable, Sendable {
    let observationEpoch: UInt64
    let resetActiveExecutions: Bool
    let prunedPhysicalRootURLs: [URL]
    let observedActivityCount: Int
}

/// Watches only already-known Codex HOME session roots and tails append-only
/// rollout JSONL files. Existing files are initially positioned at EOF, so an
/// old conversation cannot be imported as new local usage on first launch.
@MainActor
final class CodexLocalUsageObserver {
    /// Regular polls only inspect this many rollout files. Cold historical
    /// paths remain in `knownRolloutPaths` and are revisited by bounded
    /// discovery, where they can be promoted again when they change.
    nonisolated static let regularPollPathLimit = 32
#if CODEX_USAGE_TESTING
    /// Test-only evidence that the unchanged rollout fast path never opens a
    /// rollout. This is compiled out of production builds.
    nonisolated(unsafe) static var testFileHandleOpenCount = 0
    nonisolated(unsafe) static var testCursorPersistRequestCount = 0
#endif

    typealias ObservationHandler = (UUID?, CodexLocalTokenUsageRecord) -> Void
    typealias TurnCompletionHandler = (UUID?, CodexLocalTurnCompletionRecord) -> Void
    typealias TurnActivityHandler = (CodexLocalTurnActivityEvent) -> Void
    typealias ActiveExecutionReconciliationHandler = (CodexLocalActiveExecutionReconciliation) -> Void
    typealias SessionIdentityReader = @Sendable (URL) -> CodexLocalSessionIdentity?
    typealias SessionMetadataReader = @Sendable (URL) -> CodexLocalSessionMetadata?

    /// A rollout discovered by the detached bootstrap seed. The complete
    /// metadata snapshot lets the first normal scan start caught up at EOF
    /// without another MainActor filesystem probe. A head thread identity is
    /// only needed for a root added after observation has already started.
    private struct RolloutSeed: Sendable {
        let path: String
        let fileSize: UInt64
        let modificationTime: Date?
        let fileResourceIdentifier: String?
        let threadID: String?
    }

    private enum RolloutSeedMode: Sendable, Equatable {
        case startup
        case addedRoot
    }

    private let cursorURL: URL
    private var roots: [CodexLocalUsageObservationRoot] = []
    private var cursors: [String: CodexLocalUsageCursor] = [:]
    private var seededPaths: Set<String> = []
    private var knownRolloutPaths: Set<String> = []
    private var fastPollPaths: Set<String> = []
    private var timer: Timer?
    private var scanInFlight = false
    private var scanTick: UInt64 = 0
    private var scanGeneration: UInt64 = 0
    private var handler: ObservationHandler?
    private var turnCompletionHandler: TurnCompletionHandler?
    private var turnActivityHandler: TurnActivityHandler?
    private var activeExecutionReconciliationHandler: ActiveExecutionReconciliationHandler?
    private let sessionIdentityReader: SessionIdentityReader
    private let sessionMetadataReader: SessionMetadataReader
    private var hasStarted = false
    private var rootsGeneration: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 0
    private var observationEpoch: UInt64 = 0
    private var rolloutSeedTask: Task<Void, Never>?
    private var rolloutSeedGeneration: UInt64 = 0
    private var rolloutSeedPending = false
    private var rolloutSeedMode: RolloutSeedMode?
    private var rolloutSeedBlocksScan = false
    private var activeTurnRecoveryPending = false

    init(
        cursorURL: URL,
        handler: ObservationHandler? = nil,
        turnCompletionHandler: TurnCompletionHandler? = nil,
        turnActivityHandler: TurnActivityHandler? = nil,
        activeExecutionReconciliationHandler: ActiveExecutionReconciliationHandler? = nil,
        sessionIdentityReader: SessionIdentityReader? = nil,
        sessionMetadataReader: SessionMetadataReader? = nil
    ) {
        self.cursorURL = cursorURL
        self.handler = handler
        self.turnCompletionHandler = turnCompletionHandler
        self.turnActivityHandler = turnActivityHandler
        self.activeExecutionReconciliationHandler = activeExecutionReconciliationHandler
        let identityReader = sessionIdentityReader ?? { CodexLocalUsageObserver.sessionIdentity(for: $0) }
        self.sessionIdentityReader = identityReader
        self.sessionMetadataReader = sessionMetadataReader ?? {
            if sessionIdentityReader == nil {
                return CodexLocalUsageObserver.sessionMetadata(for: $0)
            }
            return CodexLocalSessionMetadata(identity: identityReader($0), lineage: nil)
        }
        loadCursors()
    }

    func setRoots(_ roots: [CodexLocalUsageObservationRoot]) {
        let previousRoots = self.roots
        let previousRootPaths = Set(previousRoots.map { $0.codexHomeURL.path })
        self.roots = roots
        rootsGeneration &+= 1
        guard hasStarted else { return }

        if previousRoots != roots {
            observationEpoch &+= 1
            let currentRootPaths = Set(roots.map { $0.codexHomeURL.path })
            let removedRoots = previousRoots
                .map(\.codexHomeURL)
                .filter { !currentRootPaths.contains($0.path) }
            activeExecutionReconciliationHandler?(
                CodexLocalActiveExecutionReconciliation(
                    observationEpoch: observationEpoch,
                    resetActiveExecutions: true,
                    prunedPhysicalRootURLs: removedRoots,
                    observedActivityCount: 0
                )
            )
        }

        // A managed profile can be added after observation has started. Seed
        // rollout files that already exist at their current EOF so adding a
        // profile cannot replay its historical session data into the machine
        // ledger. Newly appended lines are still consumed on the next scan.
        let newlyAddedRoots = roots.filter { !previousRootPaths.contains($0.codexHomeURL.path) }
        // If startup seeding (or a previous root addition) is still pending,
        // resnapshot every current root.  Otherwise a stale worker result for
        // the old root set could be discarded and leave an existing root
        // unseeded.  The generation gate in scheduleRolloutSeed() makes the
        // superseded worker harmless.
        if rolloutSeedPending, rolloutSeedMode == .startup {
            scheduleRolloutSeed(for: roots, mode: .startup)
            return
        }
        // Changing the root set resets the HUD projection for retained roots
        // too. Recheck their current Turns without replaying their ledger.
        guard previousRoots != roots || !newlyAddedRoots.isEmpty else { return }
        let rootsToSeed = roots
        let mode: RolloutSeedMode = .addedRoot
        scheduleRolloutSeed(for: rootsToSeed, mode: mode)
    }

    /// Returns whether a physical root is currently inside the observer's
    /// allow-list. This is used by the parallel execution projection before
    /// the selected-account Turn authority applies its narrower filter.
    func containsObservationRoot(_ url: URL) -> Bool {
        let normalized = CodexLocalTurnActivityAuthority.normalizedRoot(url)
        return roots.contains { CodexLocalTurnActivityAuthority.normalizedRoot($0.codexHomeURL) == normalized }
    }

    func start() {
        stop()
        hasStarted = true
        lifecycleGeneration &+= 1
        observationEpoch &+= 1
        activeExecutionReconciliationHandler?(
            CodexLocalActiveExecutionReconciliation(
                observationEpoch: observationEpoch,
                resetActiveExecutions: true,
                prunedPhysicalRootURLs: [],
                observedActivityCount: 0
            )
        )
        seededPaths = []
        knownRolloutPaths = []
        fastPollPaths = []
        scanTick = 0
        scheduleRolloutSeed(for: roots, mode: .startup)
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scan()
            }
        }
    }

    func stop() {
        let wasStarted = hasStarted
        timer?.invalidate()
        timer = nil
        hasStarted = false
        lifecycleGeneration &+= 1
        observationEpoch &+= 1
        scanInFlight = false
        rolloutSeedTask?.cancel()
        rolloutSeedTask = nil
        rolloutSeedGeneration &+= 1
        rolloutSeedPending = false
        rolloutSeedMode = nil
        rolloutSeedBlocksScan = false
        activeTurnRecoveryPending = false
        if wasStarted {
            activeExecutionReconciliationHandler?(
                CodexLocalActiveExecutionReconciliation(
                    observationEpoch: observationEpoch,
                    resetActiveExecutions: true,
                    prunedPhysicalRootURLs: [],
                    observedActivityCount: 0
                )
            )
        }
    }

    deinit {
        timer?.invalidate()
        rolloutSeedTask?.cancel()
    }

    private func loadCursors() {
        guard let data = try? Data(contentsOf: cursorURL),
              let decoded = try? JSONDecoder().decode([String: CodexLocalUsageCursor].self, from: data) else {
            return
        }
        var normalized: [String: CodexLocalUsageCursor] = [:]
        for (path, cursor) in decoded {
            let canonical = Self.canonicalPath(path)
            if let existing = normalized[canonical] {
                normalized[canonical] = Self.preferredCursor(existing, cursor)
            } else {
                normalized[canonical] = cursor
            }
        }
        cursors = normalized
    }

    private func persistCursors() {
#if CODEX_USAGE_TESTING
        Self.testCursorPersistRequestCount += 1
#endif
        let snapshot = cursors
        // Encoding is performed by the persistence actor, and the actual
        // atomic write remains on its detached utility task. The observer's
        // MainActor only publishes the newest in-memory cursor snapshot.
        Task {
            await PersistenceWriteCoordinator.shared.enqueueJSON(
                url: cursorURL,
                value: snapshot
            )
        }
    }

    /// Enumerates the current rollout namespace off the MainActor.  The
    /// resulting seed is applied only after the captured lifecycle/root/epoch
    /// generations still match, so a stop/restart or root replacement cannot
    /// publish stale paths or EOF cursors.
    private func scheduleRolloutSeed(
        for rootsToSeed: [CodexLocalUsageObservationRoot],
        mode: RolloutSeedMode
    ) {
        rolloutSeedTask?.cancel()
        guard !rootsToSeed.isEmpty else {
            rolloutSeedPending = false
            rolloutSeedMode = nil
            rolloutSeedBlocksScan = false
            rolloutSeedTask = nil
            return
        }

        rolloutSeedPending = true
        rolloutSeedMode = mode
        rolloutSeedBlocksScan = mode == .startup
        rolloutSeedGeneration &+= 1
        let seedGeneration = rolloutSeedGeneration
        let lifecycleGeneration = self.lifecycleGeneration
        let rootsGeneration = self.rootsGeneration
        let observationEpoch = self.observationEpoch

        rolloutSeedTask = Task { @MainActor [weak self] in
            let work = Task.detached(priority: .utility) {
                Self.rolloutSeeds(in: rootsToSeed, includeThreadIdentity: mode == .addedRoot)
            }
            let seeds = await withTaskCancellationHandler(operation: {
                await work.value
            }, onCancel: {
                work.cancel()
            })
            guard !Task.isCancelled, let self else { return }
            guard self.hasStarted,
                  self.rolloutSeedPending,
                  self.rolloutSeedGeneration == seedGeneration,
                  self.lifecycleGeneration == lifecycleGeneration,
                  self.rootsGeneration == rootsGeneration,
                  self.observationEpoch == observationEpoch else {
                return
            }

            let paths = Set(seeds.map(\.path))
            let pathsBefore = self.seededPaths
            self.seededPaths.formUnion(paths)
            self.knownRolloutPaths.formUnion(paths)

            var didAddCursor = false
            for seed in seeds where !pathsBefore.contains(seed.path) {
                guard self.cursors[seed.path] == nil else { continue }
                self.cursors[seed.path] = CodexLocalUsageCursor(
                    byteOffset: seed.fileSize,
                    threadID: mode == .addedRoot ? seed.threadID : nil,
                    fileSize: seed.fileSize,
                    modificationTime: seed.modificationTime,
                    fileResourceIdentifier: seed.fileResourceIdentifier
                )
                didAddCursor = true
            }
            // Persisted cursors may have old mtimes while their Chats kept
            // running with this app closed. Rank bootstrap polling by the
            // fresh seed snapshot without advancing unread ledger offsets.
            var seedRankingCursors = self.cursors
            for seed in seeds {
                seedRankingCursors[seed.path]?.modificationTime = seed.modificationTime
            }
            self.fastPollPaths = Self.initialFastPollPaths(self.fastPollPaths.union(paths), cursors: seedRankingCursors)
            self.rolloutSeedPending = false
            self.rolloutSeedMode = nil
            self.rolloutSeedBlocksScan = false
            self.rolloutSeedTask = nil
            self.activeTurnRecoveryPending = true
            // The detached seed already carries the complete metadata
            // snapshot, so the first scan can stay on the cheap caught-up
            // path. Persist the EOF cursor once; subsequent scans only write
            // when file metadata or byte offsets actually change.
            if didAddCursor { self.persistCursors() }
            self.scan()
        }
    }

    private func scan() {
        guard !scanInFlight, !roots.isEmpty, !rolloutSeedBlocksScan else { return }
        scanInFlight = true
        scanGeneration &+= 1
        scanTick &+= 1
        let roots = roots
        let cursors = cursors
        let seededPaths = seededPaths
        let knownRolloutPaths = knownRolloutPaths
        let fastPollPaths = fastPollPaths
        // start()/setRoots() already seed the current known paths. The first
        // poll can therefore use the cheap known-path path; recursive
        // discovery runs on the bounded cadence and still finds later files.
        let shouldDiscoverNewRollouts = scanTick % 15 == 0
        let rootsGeneration = rootsGeneration
        let lifecycleGeneration = lifecycleGeneration
        let observationEpoch = observationEpoch
        let scanGeneration = scanGeneration
        let sessionMetadataReader = self.sessionMetadataReader
        let recoverActiveTurns = activeTurnRecoveryPending
        Task.detached(priority: .utility) { [roots, cursors, seededPaths, knownRolloutPaths, fastPollPaths, shouldDiscoverNewRollouts, rootsGeneration, lifecycleGeneration, observationEpoch, scanGeneration, sessionMetadataReader, recoverActiveTurns] in
            let result = Self.scanRoots(
                roots,
                cursors: cursors,
                seededPaths: seededPaths,
                sessionMetadataReader: sessionMetadataReader,
                knownRolloutPaths: knownRolloutPaths,
                discoverNewRollouts: shouldDiscoverNewRollouts,
                fastPollPaths: fastPollPaths,
                statePathsAreCanonical: true,
                recoverActiveTurns: recoverActiveTurns
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.scanGeneration == scanGeneration else { return }
                self.scanInFlight = false
                guard self.hasStarted,
                      self.lifecycleGeneration == lifecycleGeneration else { return }
                guard self.observationEpoch == observationEpoch else {
                    // The root set changed while this detached scan was
                    // reading. Discard its events and immediately scan the
                    // current roots instead of leaving scanInFlight latched.
                    self.scan()
                    return
                }
                guard self.rootsGeneration == rootsGeneration else {
                    // Roots changed while this detached scan was reading. Do
                    // not apply events or replace cursors from the stale root
                    // set; the next scan will use the current roots/cursors.
                    self.scan()
                    return
                }
                let cursorsChanged = self.cursors != result.cursors
                self.cursors = result.cursors
                self.seededPaths = result.seededPaths
                self.knownRolloutPaths = result.knownRolloutPaths
                self.fastPollPaths = result.fastPollPaths
                if recoverActiveTurns { self.activeTurnRecoveryPending = false }
                if cursorsChanged { self.persistCursors() }
                for event in result.events {
                    self.handler?(event.profileID, event.record)
                }
                for event in result.turnActivities {
                    self.turnActivityHandler?(event)
                }
                for event in result.turnCompletions {
                    self.turnCompletionHandler?(event.profileID, event.record)
                }
                self.activeExecutionReconciliationHandler?(
                    CodexLocalActiveExecutionReconciliation(
                        observationEpoch: observationEpoch,
                        resetActiveExecutions: false,
                        prunedPhysicalRootURLs: [],
                        observedActivityCount: result.turnActivities.count
                    )
                )
            }
        }
    }

    nonisolated static func scanRoots(
        _ roots: [CodexLocalUsageObservationRoot],
        cursors: [String: CodexLocalUsageCursor],
        seededPaths: Set<String>,
        sessionIdentityReader: SessionIdentityReader? = nil,
        sessionMetadataReader: SessionMetadataReader? = nil,
        knownRolloutPaths: Set<String>? = nil,
        discoverNewRollouts: Bool = true,
        discoveryProbe: @escaping @Sendable (CodexLocalUsageDiscoveryProbeEvent, URL) -> Void = { _, _ in },
        discoveryFailureInjector: @escaping @Sendable (URL) -> Bool = { _ in false },
        discoveryRootIdentityReader: @escaping @Sendable (URL) -> CodexLocalUsageDiscoveryRootIdentity? = { CodexLocalUsageObserver.discoveryRootIdentity(for: $0) },
        fastPollPaths: Set<String>? = nil,
        statePathsAreCanonical: Bool = false,
        recoverActiveTurns: Bool = false
    ) -> CodexLocalUsageScanResult {
        let fileManager = FileManager.default
        let metadataReader: SessionMetadataReader = sessionMetadataReader ?? {
            if let sessionIdentityReader {
                return CodexLocalSessionMetadata(identity: sessionIdentityReader($0), lineage: nil)
            }
            return CodexLocalUsageObserver.sessionMetadata(for: $0)
        }
        func canonicalPath(_ path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        }
        let canonicalRootPaths = roots.map { canonicalPath($0.codexHomeURL.path) }
        let rootByCanonicalPath = Dictionary(zip(canonicalRootPaths, roots), uniquingKeysWith: { first, _ in first })
        var updatedCursors: [String: CodexLocalUsageCursor] = [:]
        if statePathsAreCanonical {
            updatedCursors = cursors
        } else {
            for (path, cursor) in cursors {
                // Multiple historical aliases can resolve to one physical path
                // (for example /var versus /private/var). Merge aliases with a
                // deterministic cursor preference instead of trapping on a
                // duplicate uniqueKeysWithValues key.
                let canonical = canonicalPath(path)
                if let existing = updatedCursors[canonical] {
                    updatedCursors[canonical] = Self.preferredCursor(existing, cursor)
                } else {
                    updatedCursors[canonical] = cursor
                }
            }
        }
        var updatedSeededPaths = statePathsAreCanonical ? seededPaths : Set(seededPaths.map(canonicalPath))
        var updatedKnownRolloutPaths = statePathsAreCanonical
            ? (knownRolloutPaths ?? [])
            : Set((knownRolloutPaths ?? []).map(canonicalPath))
        var updatedFastPollPaths = statePathsAreCanonical
            ? (fastPollPaths ?? updatedKnownRolloutPaths)
            : Set((fastPollPaths ?? updatedKnownRolloutPaths).map(canonicalPath))
        var events: [(profileID: UUID?, record: CodexLocalTokenUsageRecord)] = []
        var turnCompletions: [(profileID: UUID?, record: CodexLocalTurnCompletionRecord)] = []
        var turnActivities: [CodexLocalTurnActivityEvent] = []
        var seenPaths = Set<String>()
        var sessionIdentityReadCount = 0
        var directoryEnumerationCount = 0
        var rolloutMetadataReadCount = 0
        var rolloutContentFileHandleOpenCount = 0
        let sessionIndexReadsBefore = CodexLocalSessionIndex.fullReadCount
        var discoveredPaths = Set<String>()
        var successfulRootPaths = Set<String>()

        func isRolloutFile(_ url: URL) -> Bool {
            url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-")
        }

        if discoverNewRollouts {
            for root in roots {
                let rootURL = root.codexHomeURL
                let preflightIdentity = discoveryRootIdentityReader(rootURL)
                var rootDiscoverySucceeded = preflightIdentity != nil
                guard rootDiscoverySucceeded else { continue }
                discoveryProbe(.afterRootPreflight, rootURL)

                for directoryName in ["sessions.local", "sessions"] {
                    guard rootDiscoverySucceeded,
                          discoveryRootIdentityReader(rootURL) == preflightIdentity else {
                        rootDiscoverySucceeded = false
                        break
                    }
                    let directory = rootURL.appendingPathComponent(directoryName, isDirectory: true)
                    discoveryProbe(.beforeNamespace, directory)
                    // These two namespaces are optional. A missing one is an
                    // empty namespace only while the root identity remains
                    // stable before and after that observation.
                    guard fileManager.fileExists(atPath: directory.path) else {
                        discoveryProbe(.afterNamespace, directory)
                        if discoveryRootIdentityReader(rootURL) != preflightIdentity {
                            rootDiscoverySucceeded = false
                        }
                        continue
                    }
                    guard discoveryRootIdentityReader(directory) != nil,
                          !discoveryFailureInjector(directory) else {
                        rootDiscoverySucceeded = false
                        break
                    }
                    var enumerationHadError = false
                    guard let enumerator = fileManager.enumerator(
                        at: directory,
                        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                        options: [.skipsHiddenFiles],
                        errorHandler: { _, _ in
                            enumerationHadError = true
                            return false
                        }
                    ) else {
                        rootDiscoverySucceeded = false
                        break
                    }
                    directoryEnumerationCount += 1
                    for case let fileURL as URL in enumerator where isRolloutFile(fileURL) {
                        discoveredPaths.insert(canonicalPath(fileURL.path))
                    }
                    discoveryProbe(.afterNamespace, directory)
                    if enumerationHadError
                        || discoveryRootIdentityReader(rootURL) != preflightIdentity {
                        rootDiscoverySucceeded = false
                        break
                    }
                }
                discoveryProbe(.beforeRootFinalize, rootURL)
                if rootDiscoverySucceeded,
                   discoveryRootIdentityReader(rootURL) == preflightIdentity {
                    successfulRootPaths.insert(canonicalPath(rootURL.path))
                }
            }
            updatedKnownRolloutPaths.formUnion(discoveredPaths)
        }

        // Once a path has been discovered, regular 2-second polls stat only
        // those known rollouts. Full recursive discovery is bounded to every
        // 15th poll, so newly-created rollouts are still found without paying
        // the directory walk on every timer tick.
        updatedKnownRolloutPaths.formUnion(updatedCursors.keys)
        updatedKnownRolloutPaths.formUnion(updatedSeededPaths)
        let persistedEvidencePaths = Set(updatedCursors.compactMap { path, cursor in
            cursor.activeTurnEvidence == nil ? nil : path
        })
        let pollPaths = discoverNewRollouts
            ? updatedKnownRolloutPaths
            : updatedFastPollPaths.union(persistedEvidencePaths)
        let candidatePaths = pollPaths
            .filter { path in
                canonicalRootPaths.contains { rootPath in
                    path == rootPath || path.hasPrefix(rootPath + "/")
                }
            }
            .sorted()
        let legacyRecoveryPaths = recoverActiveTurns
            ? Self.initialFastPollPaths(Set(candidatePaths), cursors: updatedCursors) : []
        let recoveryPaths = legacyRecoveryPaths.union(persistedEvidencePaths.intersection(Set(candidatePaths)))
        var promotedFastPollPaths = Set<String>()
        for path in candidatePaths {
            let fileURL = URL(fileURLWithPath: path)
            guard isRolloutFile(fileURL), seenPaths.insert(path).inserted else { continue }
            guard let rootPath = canonicalRootPaths.first(where: { path == $0 || path.hasPrefix($0 + "/") }),
                  let root = rootByCanonicalPath[rootPath] else { continue }
            rolloutMetadataReadCount += 1
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize >= 0 else { continue }

            let size = UInt64(fileSize)
            let modificationTime = values.contentModificationDate
            let fileResourceIdentifier = values.fileResourceIdentifier.map { String(describing: $0) }
            var cursor = updatedCursors[path]
            let metadataUnchanged = cursor?.fileSize != nil
                && cursor?.fileSize == size
                && cursor?.modificationTime == modificationTime
                && cursor?.fileResourceIdentifier == fileResourceIdentifier

            if discoverNewRollouts && (!metadataUnchanged || !updatedFastPollPaths.contains(path)) {
                promotedFastPollPaths.insert(path)
            }

            let recoveryNow = Date()
            let hasPersistedEvidence = cursor?.activeTurnEvidence != nil
            let shouldAttemptPersistedRecovery = hasPersistedEvidence
                && (recoverActiveTurns || !metadataUnchanged)
            let shouldAttemptLegacyRecovery = !hasPersistedEvidence && legacyRecoveryPaths.contains(path)
            if recoveryPaths.contains(path),
               (shouldAttemptPersistedRecovery || shouldAttemptLegacyRecovery),
               cursor?.identityIsAmbiguous != true,
               let modified = modificationTime,
               recoveryNow.timeIntervalSince(modified) >= 0,
               recoveryNow.timeIntervalSince(modified) <= CodexLocalActiveTurnRecovery.activityFreshness {
                sessionIdentityReadCount += 1
                let metadata = metadataReader(fileURL)
                if metadata?.lineage?.isTopLevelUserChat == true {
                    rolloutContentFileHandleOpenCount += 1
                    let recovered: CodexLocalTurnActivityEvent?
                    if shouldAttemptPersistedRecovery, let cursor {
                        recovered = Self.recoverPersistedActiveTurn(
                            from: fileURL, size: size, resourceIdentifier: fileResourceIdentifier,
                            metadata: metadata, root: root, cursor: cursor, now: recoveryNow
                        )
                    } else if shouldAttemptLegacyRecovery {
                        recovered = Self.recoverActiveTurn(
                            from: fileURL, size: size, resourceIdentifier: fileResourceIdentifier,
                            metadata: metadata, root: root
                        )
                    } else {
                        recovered = nil
                    }
                    if let recovered {
                        // Recovery precedes live appends, so a later terminal
                        // event can complete the card and cannot resurrect it.
                        turnActivities.append(recovered)
                    }
                }
            }

            // A metadata-stable rollout that is already caught up has
            // no new bytes to observe. Exit before identity work or
            // any FileHandle open/read. Keep the partial-line case
            // below: when byteOffset has not reached EOF, the file
            // still needs one incremental read even if its metadata
            // has not changed since the previous scan.
            if metadataUnchanged, let cursor, cursor.byteOffset == size {
                continue
            }

            let headMetadata: CodexLocalSessionMetadata?
            if metadataUnchanged, let cursor {
                // A nil identity is also a resolved result. Keeping
                // that distinction prevents an unproven but stable
                // rollout from paying the head-read cost forever.
                headMetadata = CodexLocalSessionMetadata(
                    identity: cursor.sessionIdentity,
                    lineage: cursor.sessionLineage,
                    modelMetadata: cursor.modelMetadata
                )
            } else {
                sessionIdentityReadCount += 1
                headMetadata = metadataReader(fileURL)
            }
            let headIdentity = headMetadata?.identity
            // A rollout is bound to its first session_meta identity.
            // Any later identity change makes the entire file
            // ambiguous; subsequent events may still be observed for
            // liveness, but can never receive Repo/Chat provenance.
            var canonicalIdentity = headIdentity
            var canonicalLineage = headMetadata?.lineage
            var canonicalModelMetadata = headMetadata?.modelMetadata
            var turnContextMetadata = cursor?.turnContextMetadata
            var identityIsAmbiguous = cursor?.identityIsAmbiguous ?? false
            if let headIdentity,
               let cursorThreadID = cursor?.threadID,
               cursorThreadID != headIdentity.threadID {
                identityIsAmbiguous = true
            }
            if let previousIdentity = cursor?.sessionIdentity,
               let headIdentity,
               previousIdentity != headIdentity {
                identityIsAmbiguous = true
            }
            if let previousLineage = cursor?.sessionLineage,
               let canonicalLineage,
               previousLineage != canonicalLineage {
                identityIsAmbiguous = true
            }
            if let evidence = cursor?.activeTurnEvidence,
               evidence.resourceIdentifier != fileResourceIdentifier
                    || evidence.sessionIdentity != canonicalIdentity
                    || evidence.lineage != canonicalLineage
                    || evidence.rolloutPathIdentity != path
                    || evidence.observationRootIdentity != canonicalPath(root.codexHomeURL.path) {
                cursor?.activeTurnEvidence = nil
            }
            if identityIsAmbiguous { cursor?.activeTurnEvidence = nil }
            if cursor == nil {
                // Existing rollouts are seeded at EOF; a rollout created
                // after observation began is a live source and may be
                // consumed from its beginning.
                cursor = CodexLocalUsageCursor(
                    byteOffset: updatedSeededPaths.contains(path) ? size : 0,
                    threadID: updatedSeededPaths.contains(path) ? (canonicalIdentity?.threadID ?? Self.threadIdentity(for: fileURL)) : nil,
                    sessionIdentity: canonicalIdentity,
                    sessionLineage: canonicalLineage,
                    modelMetadata: canonicalModelMetadata,
                    turnContextMetadata: turnContextMetadata,
                    fileSize: size,
                    modificationTime: modificationTime,
                    fileResourceIdentifier: fileResourceIdentifier
                )
                updatedCursors[path] = cursor!
                updatedSeededPaths.insert(path)
                if cursor?.byteOffset == size { continue }
            }
            cursor?.sessionIdentity = canonicalIdentity
            cursor?.sessionLineage = canonicalLineage
            cursor?.modelMetadata = canonicalModelMetadata
            cursor?.turnContextMetadata = turnContextMetadata
            cursor?.fileSize = size
            cursor?.modificationTime = modificationTime
            cursor?.fileResourceIdentifier = fileResourceIdentifier
            cursor?.identityIsAmbiguous = identityIsAmbiguous
            if cursor?.threadID == nil {
                cursor?.threadID = Self.threadIdentity(for: fileURL)
            }
            guard let startingOffset = cursor?.byteOffset else { continue }
            guard startingOffset <= size else {
                // A truncated/replaced rollout is not a reason to
                // replay its old contents. Re-anchor at EOF and only
                // observe future appends.
                updatedCursors[path] = CodexLocalUsageCursor(
                    byteOffset: size,
                    threadID: canonicalIdentity?.threadID ?? Self.threadIdentity(for: fileURL),
                    sessionIdentity: canonicalIdentity,
                    sessionLineage: canonicalLineage,
                    modelMetadata: canonicalModelMetadata,
                    turnContextMetadata: turnContextMetadata,
                    fileSize: size,
                    modificationTime: modificationTime,
                    fileResourceIdentifier: fileResourceIdentifier
                )
                continue
            }
            let offset = startingOffset
#if CODEX_USAGE_TESTING
            testFileHandleOpenCount += 1
#endif
            rolloutContentFileHandleOpenCount += 1
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else { continue }
            defer { try? handle.close() }
            do {
                        try handle.seek(toOffset: offset)
                        let data = try handle.readToEnd() ?? Data()
                        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
                        // split(..., omittingEmptySubsequences: false) includes
                        // an empty sentinel after a trailing newline. All
                        // complete records are therefore the slices before
                        // the final slice, whether that last slice is an
                        // unterminated record or the trailing sentinel.
                        let completeLineCount = max(0, lines.count - 1)
                        var consumed = 0
                        var threadID = cursor?.threadID
                        for line in lines.prefix(completeLineCount) {
                            let lineLength = line.count + 1
                            consumed += lineLength
                            let lineData = Data(line)
                            let lineStartOffset = offset + UInt64(consumed - lineLength)
                            let lineEndOffset = offset + UInt64(consumed)
                            if cursor?.activeTurnEvidence != nil,
                               (try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]) == nil {
                                cursor?.activeTurnEvidence = nil
                            }
                            if let sessionThreadID = CodexLocalUsageArtifactParser.parseSessionThreadID(lineData) {
                                threadID = sessionThreadID
                                cursor?.threadID = sessionThreadID
                                if let observedMetadata = CodexLocalUsageArtifactParser.parseSessionMetadata(lineData) {
                                    let observedIdentity = observedMetadata.identity
                                    if let canonicalIdentity {
                                        if observedIdentity != canonicalIdentity {
                                            identityIsAmbiguous = true
                                            cursor?.activeTurnEvidence = nil
                                        }
                                    } else {
                                        canonicalIdentity = observedIdentity
                                        canonicalLineage = observedMetadata.lineage
                                    }
                                    if let canonicalLineage,
                                       observedMetadata.lineage != canonicalLineage {
                                        identityIsAmbiguous = true
                                        cursor?.activeTurnEvidence = nil
                                    }
                                    if let observedModelMetadata = observedMetadata.modelMetadata {
                                        canonicalModelMetadata = observedModelMetadata
                                        cursor?.modelMetadata = observedModelMetadata
                                    }
                                }
                                cursor?.identityIsAmbiguous = identityIsAmbiguous
                            }
                            if let record = CodexLocalUsageArtifactParser.parseLine(lineData) {
                                if var evidence = cursor?.activeTurnEvidence,
                                   evidence.threadID == record.threadID,
                                   evidence.turnID == record.turnID,
                                   record.observedAt >= evidence.startedAt,
                                   let total = record.turnTokenTotal,
                                   total >= 0,
                                   evidence.lastMatchingTokenAt.map({ record.observedAt >= $0 }) ?? true {
                                    evidence.lastMatchingTokenAt = record.observedAt
                                    evidence.lastTurnTokenTotal = total
                                    if turnContextMetadata?.turnID == record.turnID {
                                        evidence.turnContextMetadata = turnContextMetadata
                                    }
                                    evidence.lastValidatedOffset = lineEndOffset
                                    cursor?.activeTurnEvidence = evidence
                                }
                                events.append((root.profileID, record))
                                let identity = CodexLocalExecutionIdentityReconciliation.resolve(
                                    sessionIdentity: canonicalIdentity,
                                    eventThreadID: record.threadID,
                                    sourceIsAmbiguous: identityIsAmbiguous
                                )
                                let provenIdentity = identity.sessionIdentity
                                turnActivities.append(CodexLocalTurnActivityEvent(
                                    profileID: root.profileID,
                                    physicalRootURL: root.codexHomeURL,
                                    threadID: record.threadID,
                                    turnID: record.turnID,
                                    kind: .tokenUpdated,
                                    startedAt: nil,
                                    completedAt: nil,
                                    durationSeconds: nil,
                                    turnTokenTotal: record.turnTokenTotal,
                                    observedAt: record.observedAt,
                                    programName: provenIdentity == nil ? nil : CodexLocalSessionIndex.threadName(for: record.threadID, in: root.codexHomeURL),
                                    sessionIdentity: provenIdentity,
                                    presentationLineage: canonicalLineage,
                                    modelMetadata: turnContextMetadata?.turnID == record.turnID
                                        ? turnContextMetadata?.model : canonicalModelMetadata
                                ))
                            }
                            if let context = CodexLocalUsageArtifactParser.parseTurnContext(lineData),
                               let proven = CodexLocalExecutionIdentityReconciliation.resolve(
                                    sessionIdentity: canonicalIdentity,
                                    eventThreadID: canonicalIdentity?.threadID,
                                    sourceIsAmbiguous: identityIsAmbiguous
                               ).sessionIdentity {
                                turnContextMetadata = context
                                cursor?.turnContextMetadata = context
                                if var evidence = cursor?.activeTurnEvidence,
                                   evidence.turnID == context.turnID {
                                    evidence.turnContextMetadata = context
                                    evidence.lastValidatedOffset = lineEndOffset
                                    cursor?.activeTurnEvidence = evidence
                                }
                                turnActivities.append(CodexLocalTurnActivityEvent(
                                    profileID: root.profileID,
                                    physicalRootURL: root.codexHomeURL,
                                    threadID: proven.threadID,
                                    turnID: context.turnID,
                                    kind: .metadataUpdated,
                                    startedAt: nil,
                                    completedAt: nil,
                                    durationSeconds: nil,
                                    turnTokenTotal: nil,
                                    observedAt: context.observedAt,
                                    sessionIdentity: proven,
                                    presentationLineage: canonicalLineage,
                                    modelMetadata: context.model
                                ))
                            }
                            if let activity = CodexLocalUsageArtifactParser.parseTurnActivity(lineData, threadID: threadID) {
                                let identity = CodexLocalExecutionIdentityReconciliation.resolve(
                                    sessionIdentity: canonicalIdentity,
                                    eventThreadID: activity.threadID,
                                    sourceIsAmbiguous: identityIsAmbiguous
                                )
                                // An unproven terminal record is still useful
                                // to the active projection when its physical
                                // Turn identity can be matched uniquely. The
                                // ViewModel performs that ambiguity check;
                                // unknown lifecycle payloads remain rejected
                                // by the parser above.
                                let isTerminal: Bool = {
                                    switch activity.kind {
                                    case .completed, .failed, .interrupted: return true
                                    case .started, .tokenUpdated, .metadataUpdated: return false
                                    }
                                }()
                                if activity.kind == .started {
                                    // A later start supersedes every older
                                    // active Turn for this rollout, including
                                    // starts whose lineage is not admissible.
                                    cursor?.activeTurnEvidence = nil
                                    if identity.isProven,
                                       !identityIsAmbiguous,
                                       activity.threadID == identity.sessionIdentity?.threadID,
                                       (activity.startedAt ?? activity.observedAt) <= activity.observedAt,
                                       let sessionIdentity = identity.sessionIdentity,
                                       let lineage = canonicalLineage,
                                       lineage.isTopLevelUserChat,
                                       let fileResourceIdentifier {
                                        cursor?.activeTurnEvidence = CodexLocalActiveTurnEvidence(
                                            threadID: activity.threadID,
                                            turnID: activity.turnID,
                                            startedAt: activity.startedAt ?? activity.observedAt,
                                            startedEvidenceOffset: lineStartOffset,
                                            lastValidatedOffset: lineEndOffset,
                                            lastMatchingTokenAt: nil,
                                            lastTurnTokenTotal: nil,
                                            rolloutPathIdentity: path,
                                            observationRootIdentity: canonicalPath(root.codexHomeURL.path),
                                            resourceIdentifier: fileResourceIdentifier,
                                            sessionIdentity: sessionIdentity,
                                            lineage: lineage,
                                            turnContextMetadata: turnContextMetadata?.turnID == activity.turnID
                                                ? turnContextMetadata : nil
                                        )
                                    }
                                } else if isTerminal,
                                          let evidence = cursor?.activeTurnEvidence,
                                          evidence.threadID == activity.threadID,
                                          evidence.turnID == activity.turnID {
                                    cursor?.activeTurnEvidence = nil
                                }
                                guard identity.acceptsActivity(kind: activity.kind) || isTerminal else {
                                    continue
                                }
                                let provenIdentity = identity.sessionIdentity
                                let programName = provenIdentity == nil ? nil : CodexLocalSessionIndex.threadName(
                                    for: activity.threadID,
                                    in: root.codexHomeURL
                                )
                                turnActivities.append(CodexLocalTurnActivityEvent(
                                    profileID: root.profileID,
                                    physicalRootURL: root.codexHomeURL,
                                    threadID: activity.threadID,
                                    turnID: activity.turnID,
                                    kind: activity.kind,
                                    startedAt: activity.startedAt,
                                    completedAt: activity.completedAt,
                                    durationSeconds: activity.durationSeconds,
                                    turnTokenTotal: nil,
                                    observedAt: activity.observedAt,
                                    programName: programName,
                                    sessionIdentity: provenIdentity,
                                    presentationLineage: canonicalLineage,
                                    modelMetadata: turnContextMetadata?.turnID == activity.turnID
                                        ? turnContextMetadata?.model : canonicalModelMetadata
                                ))
                            }
                            if let completion = CodexLocalUsageArtifactParser.parseTurnCompletion(
                                lineData,
                                threadID: threadID
                            ), CodexLocalExecutionIdentityReconciliation.resolve(
                                sessionIdentity: canonicalIdentity,
                                eventThreadID: completion.threadID,
                                sourceIsAmbiguous: identityIsAmbiguous
                            ).isProven,
                               !cursor!.completedTurnIDs.contains(completion.turnID) {
                                cursor!.completedTurnIDs.insert(completion.turnID)
                                turnCompletions.append((root.profileID, completion))
                            }
                        }
                        cursor?.byteOffset = offset + UInt64(consumed)
                        if var evidence = cursor?.activeTurnEvidence {
                            evidence.lastValidatedOffset = offset + UInt64(consumed)
                            cursor?.activeTurnEvidence = evidence
                        }
                        cursor?.identityIsAmbiguous = identityIsAmbiguous
                        cursor?.sessionLineage = canonicalLineage
                        cursor?.turnContextMetadata = turnContextMetadata
                        updatedCursors[path] = cursor!
            } catch {
                continue
            }
        }

        if discoverNewRollouts && successfulRootPaths.count == roots.count {
            let stalePaths = updatedCursors.keys
                .filter { !discoveredPaths.contains($0) }
                .sorted()
                .prefix(256)
            for stalePath in stalePaths {
                updatedCursors.removeValue(forKey: stalePath)
                updatedSeededPaths.remove(stalePath)
                updatedKnownRolloutPaths.remove(stalePath)
                updatedFastPollPaths.remove(stalePath)
            }
        }
        updatedFastPollPaths.formUnion(promotedFastPollPaths)
        updatedFastPollPaths = Self.boundedFastPollPaths(updatedFastPollPaths, cursors: updatedCursors)
        return CodexLocalUsageScanResult(
            events: events,
            turnCompletions: turnCompletions,
            turnActivities: turnActivities,
            cursors: updatedCursors,
            seededPaths: updatedSeededPaths,
            knownRolloutPaths: updatedKnownRolloutPaths,
            fastPollPaths: updatedFastPollPaths,
            sessionIdentityReadCount: sessionIdentityReadCount,
            metrics: CodexLocalUsageScanMetrics(
                directoryEnumerationCount: directoryEnumerationCount,
                rolloutMetadataReadCount: rolloutMetadataReadCount,
                rolloutContentFileHandleOpenCount: rolloutContentFileHandleOpenCount,
                sessionIndexFullReadCount: CodexLocalSessionIndex.fullReadCount - sessionIndexReadsBefore
            )
        )
    }

    /// Only recent, proven main Chats pay this bounded read during an epoch
    /// reset when a legacy cursor has no durable start proof. Historical
    /// records are not sent to the ledger/notifications.
    nonisolated static let activeTurnRecoveryReadLimit = 8 * 1024 * 1024

    private nonisolated static func recoverPersistedActiveTurn(
        from fileURL: URL,
        size: UInt64,
        resourceIdentifier: String?,
        metadata: CodexLocalSessionMetadata?,
        root: CodexLocalUsageObservationRoot,
        cursor: CodexLocalUsageCursor,
        now: Date
    ) -> CodexLocalTurnActivityEvent? {
        guard let evidence = cursor.activeTurnEvidence,
              cursor.byteOffset == evidence.lastValidatedOffset,
              cursor.byteOffset <= size,
              size - cursor.byteOffset <= UInt64(activeTurnRecoveryReadLimit),
              let resourceIdentifier,
              let metadata else { return nil }

        let delta = size - cursor.byteOffset
        let data: Data
        if delta == 0 {
            data = Data()
        } else {
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: cursor.byteOffset)
                guard let read = try handle.read(upToCount: Int(delta)), read.count == Int(delta) else { return nil }
                data = read
            } catch {
                return nil
            }
        }
        guard data.isEmpty || data.last == 0x0A else { return nil }

        var refreshedURL = fileURL
        refreshedURL.removeAllCachedResourceValues()
        guard let values = try? refreshedURL.resourceValues(forKeys: [.fileSizeKey, .fileResourceIdentifierKey]),
              values.fileResourceIdentifier.map({ String(describing: $0) }) == resourceIdentifier,
              let currentSize = values.fileSize, currentSize >= 0,
              UInt64(currentSize) == size else { return nil }
        return recoverPersistedActiveTurnSnapshot(
            data,
            cursor: cursor,
            metadata: metadata,
            root: root,
            rolloutPath: Self.canonicalPath(fileURL.path),
            resourceIdentifier: resourceIdentifier,
            now: now
        )
    }

    nonisolated static func recoverPersistedActiveTurnSnapshot(
        _ data: Data,
        cursor: CodexLocalUsageCursor,
        metadata: CodexLocalSessionMetadata,
        root: CodexLocalUsageObservationRoot,
        rolloutPath: String,
        resourceIdentifier: String?,
        now: Date
    ) -> CodexLocalTurnActivityEvent? {
        guard let evidence = cursor.activeTurnEvidence,
              !cursor.identityIsAmbiguous,
              cursor.threadID == evidence.threadID,
              cursor.byteOffset == evidence.lastValidatedOffset,
              evidence.startedEvidenceOffset < evidence.lastValidatedOffset,
              evidence.rolloutPathIdentity == Self.canonicalPath(rolloutPath),
              evidence.observationRootIdentity == Self.canonicalPath(root.codexHomeURL.path),
              let resourceIdentifier,
              evidence.resourceIdentifier == resourceIdentifier,
              cursor.fileResourceIdentifier == resourceIdentifier,
              cursor.sessionIdentity == evidence.sessionIdentity,
              metadata.identity == evidence.sessionIdentity,
              evidence.sessionIdentity.threadID == evidence.threadID,
              cursor.sessionLineage == evidence.lineage,
              metadata.lineage == evidence.lineage,
              evidence.lineage.isTopLevelUserChat,
              evidence.startedAt.timeIntervalSince1970.isFinite,
              data.isEmpty || data.last == 0x0A else { return nil }

        var latestTokenAt = evidence.lastMatchingTokenAt
        var latestTokenTotal = evidence.lastTurnTokenTotal
        var turnContext = evidence.turnContextMetadata
        guard turnContext == nil || turnContext?.turnID == evidence.turnID else { return nil }

        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let lineData = Data(line)
            guard let envelope = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = envelope["type"] as? String else { return nil }
            switch type {
            case "session_meta":
                guard let observed = CodexLocalUsageArtifactParser.parseSessionMetadata(lineData),
                      observed.identity == evidence.sessionIdentity,
                      observed.lineage == evidence.lineage,
                      observed.lineage?.isTopLevelUserChat == true else { return nil }
            case "event_msg":
                if let activity = CodexLocalUsageArtifactParser.parseTurnActivity(
                    lineData,
                    threadID: evidence.threadID
                ) {
                    guard activity.threadID == evidence.threadID else { return nil }
                    switch activity.kind {
                    case .started:
                        guard activity.turnID == evidence.turnID,
                              (activity.startedAt ?? activity.observedAt) == evidence.startedAt else { return nil }
                    case .completed, .failed, .interrupted:
                        if activity.turnID == evidence.turnID { return nil }
                    case .tokenUpdated, .metadataUpdated:
                        break
                    }
                }
            case "token_usage_record":
                guard let token = CodexLocalUsageArtifactParser.parseLine(lineData),
                      token.threadID == evidence.threadID else { return nil }
                if token.turnID != evidence.turnID {
                    if token.observedAt >= evidence.startedAt { return nil }
                } else if token.observedAt >= evidence.startedAt,
                          latestTokenAt.map({ token.observedAt >= $0 }) ?? true {
                    guard let total = token.turnTokenTotal, total >= 0 else { return nil }
                    latestTokenAt = token.observedAt
                    latestTokenTotal = total
                }
            case "turn_context":
                if let context = CodexLocalUsageArtifactParser.parseTurnContext(lineData),
                   context.turnID == evidence.turnID {
                    turnContext = context
                }
            default:
                break
            }
        }

        guard let latestTokenAt,
              let latestTokenTotal,
              latestTokenAt >= evidence.startedAt,
              now.timeIntervalSince(latestTokenAt) >= 0,
              now.timeIntervalSince(latestTokenAt) <= CodexLocalActiveTurnRecovery.activityFreshness else { return nil }
        return CodexLocalTurnActivityEvent(
            profileID: root.profileID,
            physicalRootURL: root.codexHomeURL,
            threadID: evidence.threadID,
            turnID: evidence.turnID,
            kind: .tokenUpdated,
            startedAt: evidence.startedAt,
            completedAt: nil,
            durationSeconds: nil,
            turnTokenTotal: latestTokenTotal,
            observedAt: latestTokenAt,
            programName: CodexLocalSessionIndex.threadName(for: evidence.threadID, in: root.codexHomeURL),
            sessionIdentity: evidence.sessionIdentity,
            presentationLineage: evidence.lineage,
            modelMetadata: turnContext?.model,
            activeTurnRecovery: CodexLocalActiveTurnRecovery(
                turnID: evidence.turnID,
                startedAt: evidence.startedAt,
                latestActivityAt: latestTokenAt,
                verifiedAt: now
            )
        )
    }

    private nonisolated static func recoverActiveTurn(
        from fileURL: URL, size: UInt64, resourceIdentifier: String?,
        metadata: CodexLocalSessionMetadata?, root: CodexLocalUsageObservationRoot
    ) -> CodexLocalTurnActivityEvent? {
        guard let metadata, metadata.lineage?.isTopLevelUserChat == true,
              size > 0, let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        let offset = size > UInt64(activeTurnRecoveryReadLimit) ? size - UInt64(activeTurnRecoveryReadLimit) : 0
        let readOffset = offset == 0 ? 0 : offset - 1
        do {
            try handle.seek(toOffset: readOffset)
            guard var data = try handle.read(upToCount: Int(size - readOffset)),
                  data.count == Int(size - readOffset), data.last == 0x0A else { return nil }
            if offset > 0 {
                let beginsAtLineBoundary = data.first == 0x0A
                data.removeFirst()
                if !beginsAtLineBoundary {
                    guard let newline = data.firstIndex(of: 0x0A) else { return nil }
                    data = Data(data[data.index(after: newline)...])
                }
            }
            var refreshedURL = fileURL
            refreshedURL.removeAllCachedResourceValues()
            let values = try refreshedURL.resourceValues(forKeys: [.fileSizeKey, .fileResourceIdentifierKey])
            guard values.fileResourceIdentifier.map({ String(describing: $0) }) == resourceIdentifier,
                  let currentSize = values.fileSize, currentSize >= 0,
                  UInt64(currentSize) >= size else { return nil }
            return recoverActiveTurnSnapshot(data, metadata: metadata, root: root, now: Date())
        } catch {
            return nil
        }
    }

    nonisolated static func recoverActiveTurnSnapshot(
        _ data: Data, metadata: CodexLocalSessionMetadata,
        root: CodexLocalUsageObservationRoot, now: Date
    ) -> CodexLocalTurnActivityEvent? {
        guard let identity = metadata.identity,
              metadata.lineage?.isTopLevelUserChat == true,
              data.last == 0x0A else { return nil }
        var active: (turnID: String, startedAt: Date)?
        var latestToken: CodexLocalTokenUsageRecord?
        var context: CodexLocalTurnContextMetadata?
        var terminalTurns = Set<String>()
        for line in data.split(separator: 0x0A) {
            let recordData = Data(line)
            guard let envelope = try? JSONSerialization.jsonObject(with: recordData) as? [String: Any],
                  let type = envelope["type"] as? String else { return nil }
            switch type {
            case "session_meta":
                guard let observed = CodexLocalUsageArtifactParser.parseSessionMetadata(recordData),
                      observed.identity == identity,
                      observed.lineage?.isTopLevelUserChat == true else { return nil }
            case "event_msg":
                guard let payload = envelope["payload"] as? [String: Any],
                      let kind = payload["type"] as? String else { return nil }
                if kind == "task_complete" || kind == "turn_aborted" {
                    guard let turn = payload["turn_id"] as? String, !turn.isEmpty else { return nil }
                    if let thread = payload["thread_id"] as? String, thread != identity.threadID { return nil }
                    terminalTurns.insert(turn)
                    if active?.turnID == turn { active = nil; latestToken = nil }
                } else if kind == "task_started" {
                    guard let start = CodexLocalUsageArtifactParser.parseTurnActivity(recordData, threadID: identity.threadID),
                          !terminalTurns.contains(start.turnID) else { return nil }
                    if active?.turnID != start.turnID {
                        active = (start.turnID, start.startedAt ?? start.observedAt)
                        latestToken = nil
                    }
                }
            case "token_usage_record":
                guard let token = CodexLocalUsageArtifactParser.parseLine(recordData),
                      token.threadID == identity.threadID else { return nil }
                // A different current Turn's token cannot borrow the older
                // Turn's start proof from elsewhere in the same file.
                if let active, token.turnID != active.turnID { return nil }
                if let active, token.observedAt >= active.startedAt {
                    guard latestToken == nil || token.observedAt >= latestToken!.observedAt else { return nil }
                    latestToken = token
                }
            case "turn_context":
                guard let observed = CodexLocalUsageArtifactParser.parseTurnContext(recordData) else { return nil }
                context = observed
            default:
                break
            }
        }
        guard let active, let token = latestToken, let total = token.turnTokenTotal,
              token.turnID == active.turnID,
              now.timeIntervalSince(token.observedAt) >= 0,
              now.timeIntervalSince(token.observedAt) <= CodexLocalActiveTurnRecovery.activityFreshness else { return nil }
        return CodexLocalTurnActivityEvent(
            profileID: root.profileID, physicalRootURL: root.codexHomeURL,
            threadID: identity.threadID, turnID: active.turnID, kind: .tokenUpdated,
            startedAt: active.startedAt, completedAt: nil, durationSeconds: nil,
            turnTokenTotal: total, observedAt: token.observedAt,
            programName: CodexLocalSessionIndex.threadName(for: identity.threadID, in: root.codexHomeURL),
            sessionIdentity: identity, presentationLineage: metadata.lineage,
            modelMetadata: context?.turnID == active.turnID ? context?.model : nil,
            activeTurnRecovery: CodexLocalActiveTurnRecovery(
                turnID: active.turnID, startedAt: active.startedAt,
                latestActivityAt: token.observedAt, verifiedAt: now
            )
        )
    }

    private nonisolated static func rolloutSeeds(
        in roots: [CodexLocalUsageObservationRoot],
        includeThreadIdentity: Bool
    ) -> [RolloutSeed] {
        let fileManager = FileManager.default
        var seedsByPath: [String: RolloutSeed] = [:]
        for root in roots {
            if Task.isCancelled { return [] }
            for directoryName in ["sessions.local", "sessions"] {
                if Task.isCancelled { return [] }
                let directory = root.codexHomeURL.appendingPathComponent(directoryName, isDirectory: true)
                guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
                for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" && fileURL.lastPathComponent.hasPrefix("rollout-") {
                    if Task.isCancelled { return [] }
                    let path = canonicalPath(fileURL.path)
                    guard let values = try? fileURL.resourceValues(
                        forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]
                    ),
                    values.isRegularFile == true,
                    let size = values.fileSize else { continue }
                    let threadID = includeThreadIdentity ? Self.threadIdentity(for: fileURL) : nil
                    seedsByPath[path] = RolloutSeed(
                        path: path,
                        fileSize: UInt64(size),
                        modificationTime: values.contentModificationDate,
                        fileResourceIdentifier: values.fileResourceIdentifier.map { String(describing: $0) },
                        threadID: threadID
                    )
                }
            }
        }
        return seedsByPath.values.sorted { $0.path < $1.path }
    }

    private nonisolated static func boundedFastPollPaths(
        _ paths: Set<String>,
        cursors: [String: CodexLocalUsageCursor]
    ) -> Set<String> {
        guard paths.count > regularPollPathLimit else { return paths }
        return Set(
            paths
                .sorted { lhs, rhs in
                    let lhsDate = cursors[lhs]?.modificationTime ?? .distantPast
                    let rhsDate = cursors[rhs]?.modificationTime ?? .distantPast
                    if lhsDate != rhsDate { return lhsDate > rhsDate }
                    return lhs < rhs
                }
                .prefix(regularPollPathLimit)
        )
    }

    private nonisolated static func initialFastPollPaths(
        _ paths: Set<String>,
        cursors: [String: CodexLocalUsageCursor]
    ) -> Set<String> {
        guard paths.count > regularPollPathLimit else { return paths }
        return Set(
            paths
                .sorted { lhs, rhs in
                    let lhsDate = cursors[lhs]?.modificationTime ?? .distantPast
                    let rhsDate = cursors[rhs]?.modificationTime ?? .distantPast
                    if lhsDate != rhsDate { return lhsDate > rhsDate }
                    return lhs < rhs
                }
                .prefix(regularPollPathLimit)
        )
    }

    private nonisolated static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private nonisolated static func discoveryRootIdentity(for url: URL) -> CodexLocalUsageDiscoveryRootIdentity? {
        guard FileManager.default.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileResourceIdentifierKey, .creationDateKey]),
              values.isDirectory == true,
              let identifier = values.fileResourceIdentifier else { return nil }
        return CodexLocalUsageDiscoveryRootIdentity(
            resourceIdentifier: String(describing: identifier),
            creationDate: values.creationDate
        )
    }

    private nonisolated static func preferredCursor(
        _ lhs: CodexLocalUsageCursor,
        _ rhs: CodexLocalUsageCursor
    ) -> CodexLocalUsageCursor {
        let lhsModification = lhs.modificationTime?.timeIntervalSince1970 ?? -.greatestFiniteMagnitude
        let rhsModification = rhs.modificationTime?.timeIntervalSince1970 ?? -.greatestFiniteMagnitude
        if lhsModification != rhsModification { return lhsModification > rhsModification ? lhs : rhs }
        if lhs.byteOffset != rhs.byteOffset { return lhs.byteOffset > rhs.byteOffset ? lhs : rhs }
        let lhsSize = lhs.fileSize ?? 0
        let rhsSize = rhs.fileSize ?? 0
        if lhsSize != rhsSize { return lhsSize > rhsSize ? lhs : rhs }
        if lhs.identityIsAmbiguous != rhs.identityIsAmbiguous {
            return lhs.identityIsAmbiguous ? lhs : rhs
        }
        let lhsTieBreak = [
            lhs.fileResourceIdentifier ?? "",
            lhs.threadID ?? "",
            lhs.sessionIdentity?.threadID ?? "",
            lhs.completedTurnIDs.sorted().joined(separator: "\u{1F}")
        ].joined(separator: "\u{1E}")
        let rhsTieBreak = [
            rhs.fileResourceIdentifier ?? "",
            rhs.threadID ?? "",
            rhs.sessionIdentity?.threadID ?? "",
            rhs.completedTurnIDs.sorted().joined(separator: "\u{1F}")
        ].joined(separator: "\u{1E}")
        return lhsTieBreak >= rhsTieBreak ? lhs : rhs
    }

    private nonisolated static func threadIdentity(for fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 128 * 1024) else { return nil }
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            if let id = CodexLocalUsageArtifactParser.parseSessionThreadID(Data(line)) {
                return id
            }
        }
        return nil
    }

    private nonisolated static func sessionIdentity(for fileURL: URL) -> CodexLocalSessionIdentity? {
        sessionMetadata(for: fileURL)?.identity
    }

    private nonisolated static func sessionMetadata(for fileURL: URL) -> CodexLocalSessionMetadata? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 128 * 1024) else { return nil }
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            if let metadata = CodexLocalUsageArtifactParser.parseSessionMetadata(Data(line)) {
                return metadata
            }
        }
        return nil
    }
}

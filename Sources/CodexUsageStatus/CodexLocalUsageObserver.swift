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

        enum CodingKeys: String, CodingKey {
            case id
            case cwd
            case git
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

    static func parseSessionThreadID(_ data: Data) -> String? {
        parseSessionIdentity(data)?.threadID
    }

    static func parseSessionIdentity(_ data: Data) -> CodexLocalSessionIdentity? {
        guard let envelope = try? JSONDecoder().decode(SessionMetaEnvelope.self, from: data),
              envelope.type == "session_meta",
              let payload = envelope.payload,
              let id = payload.id,
              !id.isEmpty else { return nil }

        let workspace = Self.safeWorkspaceName(from: payload.cwd)
        let repository = Self.safeRepositoryName(from: payload.git?.repositoryURL)
        let repositoryIdentityDigest = Self.repositoryIdentityDigest(from: payload.git?.repositoryURL)
        let kind: CodexLocalSessionIdentityKind = repository != nil ? .repository : (workspace != nil ? .workspace : .unknown)
        return CodexLocalSessionIdentity(
            threadID: id,
            repositoryDisplayName: repository,
            workspaceDisplayName: workspace,
            kind: kind,
            repositoryIdentityDigest: repositoryIdentityDigest
        )
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

    static func threadName(for threadID: String, in codexHomeURL: URL) -> String? {
        guard !threadID.isEmpty else { return nil }
        let indexURL = codexHomeURL.appendingPathComponent("session_index.jsonl")
        guard let data = try? Data(contentsOf: indexURL) else { return nil }

        // The index is append-only and the latest matching row wins. Scanning
        // from the end avoids returning an obsolete name after a rename.
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
            guard let entry = try? JSONDecoder().decode(Entry.self, from: Data(line)),
                  entry.id == threadID else { continue }
            // A matching row with no usable name is authoritative evidence
            // that the current title is unavailable. Do not resurrect an
            // older title from an earlier row for the same thread.
            guard let rawName = entry.threadName else { return nil }
            let name = rawName
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
        return nil
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

struct CodexLocalUsageCursor: Codable, Equatable, Sendable {
    var byteOffset: UInt64
    var threadID: String?
    /// The first session identity observed for this rollout. Caching it in
    /// the cursor lets an unchanged, caught-up rollout avoid reopening and
    /// reparsing its head on every observer tick.
    var sessionIdentity: CodexLocalSessionIdentity?
    /// Resource metadata used to validate the head-identity cache. Older
    /// cursor files decode these as nil and pay one compatibility read.
    var fileSize: UInt64?
    var modificationTime: Date?
    /// A resource identifier catches atomic replacement even when the new
    /// rollout happens to have the same size and modification timestamp.
    var fileResourceIdentifier: String?
    var completedTurnIDs: Set<String>
    /// Once a rollout contains contradictory session metadata, its identity
    /// remains ambiguous across incremental scans. This prevents a tail-only
    /// scan from restoring stale Repo/Chat provenance.
    var identityIsAmbiguous: Bool

    private enum CodingKeys: String, CodingKey {
        case byteOffset
        case threadID
        case sessionIdentity
        case fileSize
        case modificationTime
        case fileResourceIdentifier
        case completedTurnIDs
        case identityIsAmbiguous
    }

    init(
        byteOffset: UInt64,
        threadID: String? = nil,
        sessionIdentity: CodexLocalSessionIdentity? = nil,
        fileSize: UInt64? = nil,
        modificationTime: Date? = nil,
        fileResourceIdentifier: String? = nil,
        completedTurnIDs: Set<String> = [],
        identityIsAmbiguous: Bool = false
    ) {
        self.byteOffset = byteOffset
        self.threadID = threadID
        self.sessionIdentity = sessionIdentity
        self.fileSize = fileSize
        self.modificationTime = modificationTime
        self.fileResourceIdentifier = fileResourceIdentifier
        self.completedTurnIDs = completedTurnIDs
        self.identityIsAmbiguous = identityIsAmbiguous
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        byteOffset = try values.decode(UInt64.self, forKey: .byteOffset)
        threadID = try values.decodeIfPresent(String.self, forKey: .threadID)
        sessionIdentity = try values.decodeIfPresent(CodexLocalSessionIdentity.self, forKey: .sessionIdentity)
        fileSize = try values.decodeIfPresent(UInt64.self, forKey: .fileSize)
        modificationTime = try values.decodeIfPresent(Date.self, forKey: .modificationTime)
        fileResourceIdentifier = try values.decodeIfPresent(String.self, forKey: .fileResourceIdentifier)
        completedTurnIDs = try values.decodeIfPresent(Set<String>.self, forKey: .completedTurnIDs) ?? []
        identityIsAmbiguous = try values.decodeIfPresent(Bool.self, forKey: .identityIsAmbiguous) ?? false
    }
}

struct CodexLocalUsageScanResult: Sendable {
    let events: [(profileID: UUID?, record: CodexLocalTokenUsageRecord)]
    let turnCompletions: [(profileID: UUID?, record: CodexLocalTurnCompletionRecord)]
    let turnActivities: [CodexLocalTurnActivityEvent]
    let cursors: [String: CodexLocalUsageCursor]
    let seededPaths: Set<String>
    let sessionIdentityReadCount: Int
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
    typealias ObservationHandler = (UUID?, CodexLocalTokenUsageRecord) -> Void
    typealias TurnCompletionHandler = (UUID?, CodexLocalTurnCompletionRecord) -> Void
    typealias TurnActivityHandler = (CodexLocalTurnActivityEvent) -> Void
    typealias ActiveExecutionReconciliationHandler = (CodexLocalActiveExecutionReconciliation) -> Void
    typealias SessionIdentityReader = @Sendable (URL) -> CodexLocalSessionIdentity?

    private let cursorURL: URL
    private var roots: [CodexLocalUsageObservationRoot] = []
    private var cursors: [String: CodexLocalUsageCursor] = [:]
    private var seededPaths: Set<String> = []
    private var timer: Timer?
    private var scanInFlight = false
    private var scanGeneration: UInt64 = 0
    private var handler: ObservationHandler?
    private var turnCompletionHandler: TurnCompletionHandler?
    private var turnActivityHandler: TurnActivityHandler?
    private var activeExecutionReconciliationHandler: ActiveExecutionReconciliationHandler?
    private let sessionIdentityReader: SessionIdentityReader
    private var hasStarted = false
    private var rootsGeneration: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 0
    private var observationEpoch: UInt64 = 0

    init(
        cursorURL: URL,
        handler: ObservationHandler? = nil,
        turnCompletionHandler: TurnCompletionHandler? = nil,
        turnActivityHandler: TurnActivityHandler? = nil,
        activeExecutionReconciliationHandler: ActiveExecutionReconciliationHandler? = nil,
        sessionIdentityReader: @escaping SessionIdentityReader = { CodexLocalUsageObserver.sessionIdentity(for: $0) }
    ) {
        self.cursorURL = cursorURL
        self.handler = handler
        self.turnCompletionHandler = turnCompletionHandler
        self.turnActivityHandler = turnActivityHandler
        self.activeExecutionReconciliationHandler = activeExecutionReconciliationHandler
        self.sessionIdentityReader = sessionIdentityReader
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
        let paths = Self.rolloutPaths(in: newlyAddedRoots)
        var didAddCursor = false
        for path in paths where !seededPaths.contains(path) {
            seededPaths.insert(path)
            if cursors[path] == nil,
               let attributes = try? FileManager.default.attributesOfItem(atPath: path),
               let fileSize = attributes[.size] as? NSNumber {
                cursors[path] = CodexLocalUsageCursor(
                    byteOffset: fileSize.uint64Value,
                    threadID: Self.threadIdentity(for: URL(fileURLWithPath: path))
                )
                didAddCursor = true
            }
        }
        if didAddCursor { persistCursors() }
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
        seededPaths = Self.rolloutPaths(in: roots)
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
    }

    private func loadCursors() {
        guard let data = try? Data(contentsOf: cursorURL),
              let decoded = try? JSONDecoder().decode([String: CodexLocalUsageCursor].self, from: data) else {
            return
        }
        cursors = decoded
    }

    private func persistCursors() {
        guard let data = try? JSONEncoder().encode(cursors) else { return }
        let directory = cursorURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: cursorURL, options: .atomic)
    }

    private func scan() {
        guard !scanInFlight, !roots.isEmpty else { return }
        scanInFlight = true
        scanGeneration &+= 1
        let roots = roots
        let cursors = cursors
        let seededPaths = seededPaths
        let rootsGeneration = rootsGeneration
        let lifecycleGeneration = lifecycleGeneration
        let observationEpoch = observationEpoch
        let scanGeneration = scanGeneration
        let sessionIdentityReader = self.sessionIdentityReader
        Task.detached(priority: .utility) { [roots, cursors, seededPaths, rootsGeneration, lifecycleGeneration, observationEpoch, scanGeneration, sessionIdentityReader] in
            let result = Self.scanRoots(
                roots,
                cursors: cursors,
                seededPaths: seededPaths,
                sessionIdentityReader: sessionIdentityReader
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
        sessionIdentityReader: @escaping SessionIdentityReader = { CodexLocalUsageObserver.sessionIdentity(for: $0) }
    ) -> CodexLocalUsageScanResult {
        let fileManager = FileManager.default
        var updatedCursors = cursors
        var updatedSeededPaths = seededPaths
        var events: [(profileID: UUID?, record: CodexLocalTokenUsageRecord)] = []
        var turnCompletions: [(profileID: UUID?, record: CodexLocalTurnCompletionRecord)] = []
        var turnActivities: [CodexLocalTurnActivityEvent] = []
        var seenPaths = Set<String>()
        var sessionIdentityReadCount = 0

        for root in roots {
            for directoryName in ["sessions.local", "sessions"] {
                let directory = root.codexHomeURL.appendingPathComponent(directoryName, isDirectory: true)
                guard let enumerator = fileManager.enumerator(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for case let fileURL as URL in enumerator {
                    guard fileURL.pathExtension == "jsonl",
                          fileURL.lastPathComponent.hasPrefix("rollout-"),
                          seenPaths.insert(fileURL.path).inserted,
                          let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]),
                          values.isRegularFile == true,
                          let fileSize = values.fileSize,
                          fileSize >= 0 else { continue }

                    let path = fileURL.path
                    let size = UInt64(fileSize)
                    let modificationTime = values.contentModificationDate
                    let fileResourceIdentifier = values.fileResourceIdentifier.map { String(describing: $0) }
                    var cursor = updatedCursors[path]
                    let metadataUnchanged = cursor?.fileSize != nil
                        && cursor?.fileSize == size
                        && cursor?.modificationTime == modificationTime
                        && cursor?.fileResourceIdentifier == fileResourceIdentifier
                    let headIdentity: CodexLocalSessionIdentity?
                    if metadataUnchanged, let cursor {
                        // A nil identity is also a resolved result. Keeping
                        // that distinction prevents an unproven but stable
                        // rollout from paying the head-read cost forever.
                        headIdentity = cursor.sessionIdentity
                    } else {
                        sessionIdentityReadCount += 1
                        headIdentity = sessionIdentityReader(fileURL)
                    }
                    // A rollout is bound to its first session_meta identity.
                    // Any later identity change makes the entire file
                    // ambiguous; subsequent events may still be observed for
                    // liveness, but can never receive Repo/Chat provenance.
                    var canonicalIdentity = headIdentity
                    var identityIsAmbiguous = cursor?.identityIsAmbiguous ?? false
                    if let headIdentity,
                       let cursorThreadID = cursor?.threadID,
                       cursorThreadID != headIdentity.threadID {
                        identityIsAmbiguous = true
                    }
                    if cursor == nil {
                        // Existing rollouts are seeded at EOF; a rollout created
                        // after observation began is a live source and may be
                        // consumed from its beginning.
                        cursor = CodexLocalUsageCursor(
                            byteOffset: updatedSeededPaths.contains(path) ? size : 0,
                            threadID: updatedSeededPaths.contains(path) ? (canonicalIdentity?.threadID ?? Self.threadIdentity(for: fileURL)) : nil,
                            sessionIdentity: canonicalIdentity,
                            fileSize: size,
                            modificationTime: modificationTime,
                            fileResourceIdentifier: fileResourceIdentifier
                        )
                        updatedCursors[path] = cursor
                        updatedSeededPaths.insert(path)
                        if cursor?.byteOffset == size { continue }
                    }
                    cursor?.sessionIdentity = canonicalIdentity
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
                            fileSize: size,
                            modificationTime: modificationTime,
                            fileResourceIdentifier: fileResourceIdentifier
                        )
                        continue
                    }
                    let offset = startingOffset
                    guard let handle = try? FileHandle(forReadingFrom: fileURL) else { continue }
                    defer { try? handle.close() }
                    do {
                        try handle.seek(toOffset: offset)
                        let data = try handle.readToEnd() ?? Data()
                        let endsWithNewline = data.last == 0x0A
                        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
                        let completeLineCount = endsWithNewline ? lines.count : max(0, lines.count - 1)
                        var consumed = 0
                        var threadID = cursor?.threadID
                        for line in lines.prefix(completeLineCount) {
                            let lineLength = line.count + 1
                            consumed += lineLength
                            let lineData = Data(line)
                            if let sessionThreadID = CodexLocalUsageArtifactParser.parseSessionThreadID(lineData) {
                                threadID = sessionThreadID
                                cursor?.threadID = sessionThreadID
                                if let observedIdentity = CodexLocalUsageArtifactParser.parseSessionIdentity(lineData) {
                                    if let canonicalIdentity {
                                        if observedIdentity != canonicalIdentity {
                                            identityIsAmbiguous = true
                                        }
                                    } else {
                                        canonicalIdentity = observedIdentity
                                    }
                                }
                                cursor?.identityIsAmbiguous = identityIsAmbiguous
                            }
                            if let record = CodexLocalUsageArtifactParser.parseLine(lineData) {
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
                                    sessionIdentity: provenIdentity
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
                                    case .started, .tokenUpdated: return false
                                    }
                                }()
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
                                    sessionIdentity: provenIdentity
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
                        cursor?.identityIsAmbiguous = identityIsAmbiguous
                        updatedCursors[path] = cursor!
                    } catch {
                        continue
                    }
                }
            }
        }
        return CodexLocalUsageScanResult(
            events: events,
            turnCompletions: turnCompletions,
            turnActivities: turnActivities,
            cursors: updatedCursors,
            seededPaths: updatedSeededPaths,
            sessionIdentityReadCount: sessionIdentityReadCount
        )
    }

    private nonisolated static func rolloutPaths(
        in roots: [CodexLocalUsageObservationRoot]
    ) -> Set<String> {
        let fileManager = FileManager.default
        var paths = Set<String>()
        for root in roots {
            for directoryName in ["sessions.local", "sessions"] {
                let directory = root.codexHomeURL.appendingPathComponent(directoryName, isDirectory: true)
                guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
                for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" && fileURL.lastPathComponent.hasPrefix("rollout-") {
                    paths.insert(fileURL.path)
                }
            }
        }
        return paths
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
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 128 * 1024) else { return nil }
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            if let identity = CodexLocalUsageArtifactParser.parseSessionIdentity(Data(line)) {
                return identity
            }
        }
        return nil
    }
}

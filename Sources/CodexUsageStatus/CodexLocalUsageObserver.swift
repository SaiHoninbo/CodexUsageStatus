import Foundation

/// The subset of a Codex Desktop `token_usage_record` that is safe and useful
/// to feed into the existing machine-local ledger. The rollout/session file is
/// treated as an append-only, read-only observation source; it is never edited
/// or resumed by UsageStatus.
struct CodexLocalTokenUsageRecord: Equatable, Sendable {
    let threadID: String
    let turnID: String
    let cumulativeTokenTotal: Int64
    let lastCallTokenTotal: Int64?
    let observedAt: Date
}

struct CodexLocalTurnCompletionRecord: Equatable, Sendable {
    let threadID: String
    let turnID: String
    let startedAt: Date
    let completedAt: Date
    let durationSeconds: Int64
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
        let turnID: String?
        let startedAt: Double?
        let completedAt: Double?
        let durationMilliseconds: Double?

        enum CodingKeys: String, CodingKey {
            case type
            case turnID = "turn_id"
            case startedAt = "started_at"
            case completedAt = "completed_at"
            case durationMilliseconds = "duration_ms"
        }
    }

    private struct LifecycleEnvelope: Decodable {
        let type: String?
        let payload: LifecyclePayload?
    }

    private struct SessionMetaPayload: Decodable {
        let id: String?
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
            observedAt: observedAt
        )
    }

    static func parseSessionThreadID(_ data: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(SessionMetaEnvelope.self, from: data),
              envelope.type == "session_meta",
              let id = envelope.payload?.id,
              !id.isEmpty else { return nil }
        return id
    }

    static func parseTurnCompletion(_ data: Data, threadID: String?) -> CodexLocalTurnCompletionRecord? {
        guard let threadID, !threadID.isEmpty,
              let envelope = try? JSONDecoder().decode(LifecycleEnvelope.self, from: data),
              envelope.type == "event_msg",
              let payload = envelope.payload,
              payload.type == "task_complete",
              let turnID = payload.turnID,
              !turnID.isEmpty,
              let started = payload.startedAt,
              let completed = payload.completedAt,
              started.isFinite,
              completed.isFinite,
              completed >= started else { return nil }

        let durationSeconds: Int64
        if let durationMilliseconds = payload.durationMilliseconds,
           durationMilliseconds.isFinite,
           durationMilliseconds >= 0 {
            durationSeconds = max(0, Int64((durationMilliseconds / 1_000).rounded(.down)))
        } else {
            durationSeconds = max(0, Int64((completed - started).rounded(.down)))
        }
        return CodexLocalTurnCompletionRecord(
            threadID: threadID,
            turnID: turnID,
            startedAt: Date(timeIntervalSince1970: started),
            completedAt: Date(timeIntervalSince1970: completed),
            durationSeconds: durationSeconds
        )
    }
}

struct CodexLocalUsageObservationRoot: Equatable, Sendable {
    let profileID: UUID?
    let codexHomeURL: URL
}

private struct CodexLocalUsageCursor: Codable, Equatable, Sendable {
    var byteOffset: UInt64
    var threadID: String?
    var completedTurnIDs: Set<String>

    private enum CodingKeys: String, CodingKey {
        case byteOffset
        case threadID
        case completedTurnIDs
    }

    init(byteOffset: UInt64, threadID: String? = nil, completedTurnIDs: Set<String> = []) {
        self.byteOffset = byteOffset
        self.threadID = threadID
        self.completedTurnIDs = completedTurnIDs
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        byteOffset = try values.decode(UInt64.self, forKey: .byteOffset)
        threadID = try values.decodeIfPresent(String.self, forKey: .threadID)
        completedTurnIDs = try values.decodeIfPresent(Set<String>.self, forKey: .completedTurnIDs) ?? []
    }
}

private struct CodexLocalUsageScanResult: Sendable {
    let events: [(profileID: UUID?, record: CodexLocalTokenUsageRecord)]
    let turnCompletions: [(profileID: UUID?, record: CodexLocalTurnCompletionRecord)]
    let cursors: [String: CodexLocalUsageCursor]
    let seededPaths: Set<String>
}

/// Watches only already-known Codex HOME session roots and tails append-only
/// rollout JSONL files. Existing files are initially positioned at EOF, so an
/// old conversation cannot be imported as new local usage on first launch.
@MainActor
final class CodexLocalUsageObserver {
    typealias ObservationHandler = (UUID?, CodexLocalTokenUsageRecord) -> Void
    typealias TurnCompletionHandler = (UUID?, CodexLocalTurnCompletionRecord) -> Void

    private let cursorURL: URL
    private var roots: [CodexLocalUsageObservationRoot] = []
    private var cursors: [String: CodexLocalUsageCursor] = [:]
    private var seededPaths: Set<String> = []
    private var timer: Timer?
    private var scanInFlight = false
    private var handler: ObservationHandler?
    private var turnCompletionHandler: TurnCompletionHandler?
    private var hasStarted = false
    private var rootsGeneration: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 0

    init(
        cursorURL: URL,
        handler: ObservationHandler? = nil,
        turnCompletionHandler: TurnCompletionHandler? = nil
    ) {
        self.cursorURL = cursorURL
        self.handler = handler
        self.turnCompletionHandler = turnCompletionHandler
        loadCursors()
    }

    func setRoots(_ roots: [CodexLocalUsageObservationRoot]) {
        let previousRootPaths = Set(self.roots.map { $0.codexHomeURL.path })
        self.roots = roots
        rootsGeneration &+= 1
        guard hasStarted else { return }

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

    func start() {
        stop()
        hasStarted = true
        lifecycleGeneration &+= 1
        seededPaths = Self.rolloutPaths(in: roots)
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scan()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        hasStarted = false
        lifecycleGeneration &+= 1
        scanInFlight = false
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
        let roots = roots
        let cursors = cursors
        let seededPaths = seededPaths
        let rootsGeneration = rootsGeneration
        let lifecycleGeneration = lifecycleGeneration
        Task.detached(priority: .utility) { [roots, cursors, seededPaths, rootsGeneration, lifecycleGeneration] in
            let result = Self.scanRoots(roots, cursors: cursors, seededPaths: seededPaths)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.hasStarted,
                      self.lifecycleGeneration == lifecycleGeneration else { return }
                self.scanInFlight = false
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
                for event in result.turnCompletions {
                    self.turnCompletionHandler?(event.profileID, event.record)
                }
            }
        }
    }

    private nonisolated static func scanRoots(
        _ roots: [CodexLocalUsageObservationRoot],
        cursors: [String: CodexLocalUsageCursor],
        seededPaths: Set<String>
    ) -> CodexLocalUsageScanResult {
        let fileManager = FileManager.default
        var updatedCursors = cursors
        var updatedSeededPaths = seededPaths
        var events: [(profileID: UUID?, record: CodexLocalTokenUsageRecord)] = []
        var turnCompletions: [(profileID: UUID?, record: CodexLocalTurnCompletionRecord)] = []
        var seenPaths = Set<String>()

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
                          let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                          values.isRegularFile == true,
                          let fileSize = values.fileSize,
                          fileSize >= 0 else { continue }

                    let path = fileURL.path
                    var cursor = updatedCursors[path]
                    let size = UInt64(fileSize)
                    if cursor == nil {
                        // Existing rollouts are seeded at EOF; a rollout created
                        // after observation began is a live source and may be
                        // consumed from its beginning.
                        cursor = CodexLocalUsageCursor(
                            byteOffset: updatedSeededPaths.contains(path) ? size : 0,
                            threadID: updatedSeededPaths.contains(path) ? Self.threadIdentity(for: fileURL) : nil
                        )
                        updatedCursors[path] = cursor
                        updatedSeededPaths.insert(path)
                        if cursor?.byteOffset == size { continue }
                    }
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
                            threadID: Self.threadIdentity(for: fileURL)
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
                            }
                            if let record = CodexLocalUsageArtifactParser.parseLine(lineData) {
                                events.append((root.profileID, record))
                            }
                            if let completion = CodexLocalUsageArtifactParser.parseTurnCompletion(
                                lineData,
                                threadID: threadID
                            ), !cursor!.completedTurnIDs.contains(completion.turnID) {
                                cursor!.completedTurnIDs.insert(completion.turnID)
                                turnCompletions.append((root.profileID, completion))
                            }
                        }
                        cursor?.byteOffset = offset + UInt64(consumed)
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
            cursors: updatedCursors,
            seededPaths: updatedSeededPaths
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
}

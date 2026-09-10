import Foundation

/// Metadata-only duration evidence for one completed local Codex Turn.  The
/// sample is intentionally kept in memory by the estimator; the existing
/// rollout observer remains the only lifecycle authority and no new history
/// store is introduced.
struct CodexExecutionDurationSample: Equatable, Sendable {
    let profileID: UUID?
    let normalizedPhysicalRootPath: String
    let threadID: String
    let turnID: String
    let repositoryDisplayName: String?
    let repositoryIdentityDigest: String?
    let workspaceDisplayName: String?
    let chatName: String?
    let durationSeconds: Int64
    let completedAt: Date

    init(
        profileID: UUID?,
        physicalRootURL: URL,
        threadID: String,
        turnID: String,
        repositoryDisplayName: String?,
        repositoryIdentityDigest: String? = nil,
        workspaceDisplayName: String?,
        chatName: String?,
        durationSeconds: Int64,
        completedAt: Date
    ) {
        self.profileID = profileID
        self.normalizedPhysicalRootPath = physicalRootURL.standardizedFileURL.resolvingSymlinksInPath().path
        self.threadID = threadID
        self.turnID = turnID
        self.repositoryDisplayName = repositoryDisplayName
        self.repositoryIdentityDigest = repositoryIdentityDigest
        self.workspaceDisplayName = workspaceDisplayName
        self.chatName = chatName
        self.durationSeconds = max(0, durationSeconds)
        self.completedAt = completedAt
    }
}

enum CodexExecutionEstimateConfidence: String, Equatable, Sendable {
    case high
    case medium
    case low

    var displayName: String {
        switch self {
        case .high: return "高"
        case .medium: return "中"
        case .low: return "低"
        }
    }
}

enum CodexExecutionEstimateCohort: String, Equatable, Sendable {
    case sameChat
    case sameRepository
    case sameProfile
    case global

    var displayName: String {
        switch self {
        case .sameChat: return "同一 Chat"
        case .sameRepository: return "同一 Repo"
        case .sameProfile: return "同一帳號"
        case .global: return "本機歷史"
        }
    }
}

/// A bounded, deliberately non-authoritative estimate for an active Turn.
/// It never represents terminal state and is capped below 100% so the UI
/// cannot accidentally imply that a Turn has completed.
struct CodexExecutionEstimate: Equatable, Sendable {
    let lowerProgressPercent: Int
    let upperProgressPercent: Int
    let lowerRemainingSeconds: Int64
    let upperRemainingSeconds: Int64
    let confidence: CodexExecutionEstimateConfidence
    let cohort: CodexExecutionEstimateCohort
    let sampleCount: Int

    var progressText: String {
        if lowerProgressPercent == upperProgressPercent {
            return "本機耗時推估 \(lowerProgressPercent)%"
        }
        return "本機耗時推估 \(lowerProgressPercent)–\(upperProgressPercent)%"
    }

    var remainingText: String {
        let lower = Self.displayMinutes(lowerRemainingSeconds)
        let upper = Self.displayMinutes(upperRemainingSeconds)
        if lower == upper {
            return "預估剩餘 約 \(lower) 分鐘"
        }
        return "預估剩餘 約 \(lower)–\(upper) 分鐘"
    }

    var confidenceText: String {
        "信心：\(confidence.displayName)"
    }

    private static func displayMinutes(_ seconds: Int64) -> Int64 {
        guard seconds > 0 else { return 0 }
        return max(1, (seconds + 59) / 60)
    }
}

/// Pure policy for observer-based estimation.  It uses only completed local
/// duration metadata. Token activity is intentionally not an input: it can
/// establish liveness, but cannot prove how much work remains.
enum CodexExecutionEstimationPolicy {
    private struct CohortCandidate {
        let kind: CodexExecutionEstimateCohort
        let samples: [CodexExecutionDurationSample]
        let minimumForMediumConfidence: Int
    }

    private static let retainedSampleLimit = 200
    private static let maximumActiveProgress = 95

    static func estimate(
        for execution: CodexExecutionProjection,
        now: Date,
        samples: [CodexExecutionDurationSample]
    ) -> CodexExecutionEstimate? {
        let elapsed = max(0, now.timeIntervalSince(execution.startedAt))
        let candidate = selectCohort(for: execution, samples: samples)
        let durations = candidate.samples
            .map(\.durationSeconds)
            .filter { $0 > 0 }
        guard !durations.isEmpty else { return nil }

        // Prefer completed durations that could still contain the active Turn.
        // If elapsed already exceeds all history, retain the full distribution
        // and use a robust upper quantile instead of fabricating an ETA.
        let comparable = durations.filter { Double($0) > elapsed }
        let distribution = comparable.isEmpty ? durations : comparable
        let lowerQuantile = quantile(distribution, comparable.isEmpty ? 0.50 : 0.25)
        let upperQuantile = quantile(distribution, comparable.isEmpty ? 0.90 : 0.75)
        guard let lowerQuantile, let upperQuantile else { return nil }

        let lowerTotal = max(0, lowerQuantile)
        let upperTotal = max(lowerTotal, upperQuantile)
        let lowerProgress = boundedPercentage(elapsed / max(1, upperTotal))
        let upperProgress = boundedPercentage(elapsed / max(1, lowerTotal))
        let lowerRemaining = max(0, Int64((lowerTotal - elapsed).rounded(.down)))
        let upperRemaining = max(lowerRemaining, Int64((upperTotal - elapsed).rounded(.down)))

        return CodexExecutionEstimate(
            lowerProgressPercent: min(lowerProgress, upperProgress),
            upperProgressPercent: max(lowerProgress, upperProgress),
            lowerRemainingSeconds: lowerRemaining,
            upperRemainingSeconds: upperRemaining,
            confidence: confidence(for: candidate, durations: durations),
            cohort: candidate.kind,
            sampleCount: candidate.samples.count
        )
    }

    static func selectCohort(
        for execution: CodexExecutionProjection,
        samples: [CodexExecutionDurationSample]
    ) -> (kind: CodexExecutionEstimateCohort, samples: [CodexExecutionDurationSample], minimumForMediumConfidence: Int) {
        let root = execution.key.normalizedPhysicalRootPath
        let sameChat = samples.filter {
            $0.profileID == execution.key.profileID
                && $0.normalizedPhysicalRootPath == root
                && $0.threadID == execution.key.threadID
                && $0.repositoryIdentityDigest == execution.key.repositoryIdentityDigest
        }
        let sameRepository = samples.filter {
            $0.profileID == execution.key.profileID
                && $0.normalizedPhysicalRootPath == root
                && matchesRepositoryOrWorkspace($0, execution: execution)
        }
        let sameProfile = samples.filter { $0.profileID == execution.key.profileID }
        let global = newestFirst(samples)
        let candidates = [
            CohortCandidate(kind: .sameChat, samples: sameChat, minimumForMediumConfidence: 5),
            CohortCandidate(kind: .sameRepository, samples: sameRepository, minimumForMediumConfidence: 8),
            CohortCandidate(kind: .sameProfile, samples: sameProfile, minimumForMediumConfidence: 12),
            CohortCandidate(kind: .global, samples: global, minimumForMediumConfidence: 15)
        ]

        // Choose the most specific cohort with enough evidence for a medium
        // confidence claim. This prevents one old Chat sample from winning
        // over a useful Repo history.
        if let sufficient = candidates.first(where: { $0.samples.count >= $0.minimumForMediumConfidence }) {
            return (sufficient.kind, newestFirst(sufficient.samples), sufficient.minimumForMediumConfidence)
        }

        // With sparse history, prefer a broad distribution and explicitly mark
        // the result low confidence. There is still no estimate when history
        // is empty; the caller then renders the cold-start state.
        if !global.isEmpty {
            return (.global, newestFirst(global), 15)
        }
        if let sparse = candidates.first(where: { !$0.samples.isEmpty }) {
            return (sparse.kind, newestFirst(sparse.samples), sparse.minimumForMediumConfidence)
        }
        return (.global, [], 15)
    }

    private static func matchesRepositoryOrWorkspace(
        _ sample: CodexExecutionDurationSample,
        execution: CodexExecutionProjection
    ) -> Bool {
        if execution.repositoryDisplayName != nil {
            // A display name is never sufficient to establish Repo identity.
            // If the execution lacks a canonical remote digest, the
            // repository-specific cohort is not proven and must not match.
            guard let digest = execution.key.repositoryIdentityDigest else { return false }
            return sample.repositoryIdentityDigest == digest
        }
        if let workspace = execution.workspaceDisplayName {
            // Workspace-only observations are already scoped by the physical
            // root in the caller. Keep them separate from repository-backed
            // samples and retain the display name only as a local label.
            return sample.repositoryIdentityDigest == nil
                && sample.workspaceDisplayName == workspace
        }
        return sample.repositoryIdentityDigest == nil
            && sample.repositoryDisplayName == nil
            && sample.workspaceDisplayName == nil
    }

    private static func confidence(
        for candidate: (
            kind: CodexExecutionEstimateCohort,
            samples: [CodexExecutionDurationSample],
            minimumForMediumConfidence: Int
        ),
        durations: [Int64]
    ) -> CodexExecutionEstimateConfidence {
        guard candidate.samples.count >= candidate.minimumForMediumConfidence else { return .low }
        guard let lower = quantile(durations, 0.25), lower > 0,
              let upper = quantile(durations, 0.75) else { return .medium }
        let dispersion = upper / lower
        if candidate.kind == .sameChat && dispersion <= 1.35 { return .high }
        return .medium
    }

    private static func newestFirst(_ samples: [CodexExecutionDurationSample]) -> [CodexExecutionDurationSample] {
        Array(samples.sorted { $0.completedAt > $1.completedAt }.prefix(retainedSampleLimit))
    }

    private static func boundedPercentage(_ fraction: Double) -> Int {
        guard fraction.isFinite else { return 0 }
        let percentage = Int((max(0, fraction) * 100).rounded())
        return min(maximumActiveProgress, max(0, percentage))
    }

    private static func quantile(_ values: [Int64], _ percentile: Double) -> Double? {
        let sorted = values.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return nil }
        let bounded = min(1, max(0, percentile))
        if sorted.count == 1 { return Double(sorted[0]) }
        let position = Double(sorted.count - 1) * bounded
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = min(sorted.count - 1, lowerIndex + 1)
        let fraction = position - Double(lowerIndex)
        return Double(sorted[lowerIndex])
            + Double(sorted[upperIndex] - sorted[lowerIndex]) * fraction
    }
}

/// Bounded metadata-only fallback scan for completed local Turn durations.
/// It is deliberately separate from the live observer cursor: this scan never
/// emits lifecycle events, changes cursors, or replays a Turn into the UI.
enum CodexExecutionDurationHistoryScanner {
    private static let maximumFiles = 256
    private static let maximumSamples = 200
    private static let headBytes = 128 * 1024
    private static let tailBytes = 512 * 1024

    static func scan(
        roots: [CodexLocalUsageObservationRoot],
        maxSamples: Int = maximumSamples,
        fileManager: FileManager = .default
    ) -> [CodexExecutionDurationSample] {
        var samplesByIdentity: [String: CodexExecutionDurationSample] = [:]
        var examinedFiles = 0

        for root in roots {
            for directoryName in ["sessions.local", "sessions"] {
                guard examinedFiles < maximumFiles else { break }
                let directory = root.codexHomeURL.appendingPathComponent(directoryName, isDirectory: true)
                guard let enumerator = fileManager.enumerator(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for case let fileURL as URL in enumerator {
                    guard examinedFiles < maximumFiles else { break }
                    guard fileURL.pathExtension == "jsonl",
                          fileURL.lastPathComponent.hasPrefix("rollout-"),
                          let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                          values.isRegularFile == true,
                          let fileSize = values.fileSize,
                          fileSize >= 0 else { continue }
                    examinedFiles += 1
                    let data = readBoundedMetadataData(from: fileURL, size: fileSize)
                    let bytes: [UInt8] = Array(data)
                    let rawLines = bytes.split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
                    let lines: [Data] = rawLines.map { Data($0) }
                    let sessionIdentities = lines.compactMap(CodexLocalUsageArtifactParser.parseSessionIdentity)
                    guard let sessionThreadID = sessionIdentities.first?.threadID,
                          let identity = CodexLocalExecutionIdentityReconciliation.resolve(
                              sessionIdentities: sessionIdentities,
                              eventThreadID: sessionThreadID
                          ).sessionIdentity else { continue }
                    let chatName = CodexLocalSessionIndex.threadName(for: identity.threadID, in: root.codexHomeURL)
                    var startedAtByTurn: [String: Date] = [:]

                    for line in lines {
                        guard let activity = CodexLocalUsageArtifactParser.parseTurnActivity(
                            line,
                            threadID: identity.threadID
                        ), CodexLocalExecutionIdentityReconciliation.resolve(
                            sessionIdentity: identity,
                            eventThreadID: activity.threadID
                        ).isProven else { continue }
                        switch activity.kind {
                        case .started:
                            if let startedAt = activity.startedAt {
                                startedAtByTurn[activity.turnID] = startedAt
                            }
                        case .completed:
                            let duration = activity.durationSeconds
                                ?? activity.startedAt.flatMap { started in
                                    activity.completedAt.map { completed in
                                        max(0, Int64(floor(completed.timeIntervalSince(started))))
                                    }
                                }
                            guard let duration, duration > 0 else { continue }
                            let completedAt = activity.completedAt ?? activity.observedAt
                            let sample = CodexExecutionDurationSample(
                                profileID: root.profileID,
                                physicalRootURL: root.codexHomeURL,
                                threadID: identity.threadID,
                                turnID: activity.turnID,
                                repositoryDisplayName: identity.repositoryDisplayName,
                                repositoryIdentityDigest: identity.repositoryIdentityDigest,
                                workspaceDisplayName: identity.workspaceDisplayName,
                                chatName: chatName,
                                durationSeconds: duration,
                                completedAt: completedAt
                            )
                            let key = sample.profileID?.uuidString ?? "default"
                            let identityKey = "\(key)|\(sample.normalizedPhysicalRootPath)|\(sample.threadID)|\(sample.turnID)"
                            samplesByIdentity[identityKey] = sample
                        case .failed, .interrupted, .tokenUpdated:
                            continue
                        }
                    }
                }
            }
        }

        return samplesByIdentity.values
            .sorted { $0.completedAt > $1.completedAt }
            .prefix(max(0, maxSamples))
            .map { $0 }
    }

    private static func readBoundedMetadataData(from fileURL: URL, size: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return Data() }
        defer { try? handle.close() }
        do {
            if size <= headBytes + tailBytes {
                return try handle.readToEnd() ?? Data()
            }
            let head = try handle.read(upToCount: headBytes) ?? Data()
            try handle.seek(toOffset: UInt64(size - tailBytes))
            let tail = try handle.read(upToCount: tailBytes) ?? Data()
            return head + Data("\n".utf8) + tail
        } catch {
            return Data()
        }
    }
}

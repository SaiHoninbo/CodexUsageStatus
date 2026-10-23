import Combine
import Foundation

public enum CodexUsageProjectionAvailability: String, Equatable, Sendable {
    case checking
    case available
    case unavailable
}

public enum CodexUsageAccountQuotaAvailability: String, Equatable, Codable, Sendable {
    case checking
    case available
    case unavailable
    case notProven
}

/// Credential-free account/quota values owned by CodexUsageStatus.
/// This value intentionally contains no account IDs, tokens, cookies,
/// authentication headers, or Keychain material.
public struct CodexUsageAccountQuotaSnapshot: Equatable, Codable, Sendable {
    public let availability: CodexUsageAccountQuotaAvailability
    public let observedAt: Date?
    public let accountDisplayIdentity: String?
    public let plan: String?
    public let appVersion: String?
    public let rollingQuotaPercent: Int?
    public let quotaWindowLabel: String?
    public let quotaRemainingDuration: String?
    public let resetAt: Date?
    public let resetCredits: Int?
    public let resetCreditExpiry: Date?

    private enum CodingKeys: String, CodingKey {
        case availability
        case observedAt
        case accountDisplayIdentity
        case plan
        case appVersion
        case rollingQuotaPercent
        case quotaWindowLabel
        case quotaRemainingDuration
        case resetAt
        case resetCredits
        case resetCreditExpiry
    }

    public init(
        availability: CodexUsageAccountQuotaAvailability,
        observedAt: Date? = nil,
        accountDisplayIdentity: String? = nil,
        plan: String? = nil,
        appVersion: String? = nil,
        rollingQuotaPercent: Int? = nil,
        quotaWindowLabel: String? = nil,
        quotaRemainingDuration: String? = nil,
        resetAt: Date? = nil,
        resetCredits: Int? = nil,
        resetCreditExpiry: Date? = nil
    ) {
        self.availability = availability
        self.observedAt = observedAt
        self.accountDisplayIdentity = accountDisplayIdentity
        self.plan = plan
        self.appVersion = appVersion
        self.rollingQuotaPercent = rollingQuotaPercent
        self.quotaWindowLabel = quotaWindowLabel
        self.quotaRemainingDuration = quotaRemainingDuration
        self.resetAt = resetAt
        self.resetCredits = resetCredits
        self.resetCreditExpiry = resetCreditExpiry
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        availability = try values.decode(CodexUsageAccountQuotaAvailability.self, forKey: .availability)
        observedAt = try values.decodeIfPresent(Date.self, forKey: .observedAt)
        accountDisplayIdentity = try values.decodeIfPresent(String.self, forKey: .accountDisplayIdentity)
        plan = try values.decodeIfPresent(String.self, forKey: .plan)
        appVersion = try values.decodeIfPresent(String.self, forKey: .appVersion)
        rollingQuotaPercent = try values.decodeIfPresent(Int.self, forKey: .rollingQuotaPercent)
        quotaWindowLabel = try values.decodeIfPresent(String.self, forKey: .quotaWindowLabel)
        quotaRemainingDuration = try values.decodeIfPresent(String.self, forKey: .quotaRemainingDuration)
        resetAt = try values.decodeIfPresent(Date.self, forKey: .resetAt)
        resetCredits = try values.decodeIfPresent(Int.self, forKey: .resetCredits)
        resetCreditExpiry = try values.decodeIfPresent(Date.self, forKey: .resetCreditExpiry)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(availability, forKey: .availability)
        try Self.encodeOptional(observedAt, to: &values, forKey: .observedAt)
        try Self.encodeOptional(accountDisplayIdentity, to: &values, forKey: .accountDisplayIdentity)
        try Self.encodeOptional(plan, to: &values, forKey: .plan)
        try Self.encodeOptional(appVersion, to: &values, forKey: .appVersion)
        try Self.encodeOptional(rollingQuotaPercent, to: &values, forKey: .rollingQuotaPercent)
        try Self.encodeOptional(quotaWindowLabel, to: &values, forKey: .quotaWindowLabel)
        try Self.encodeOptional(quotaRemainingDuration, to: &values, forKey: .quotaRemainingDuration)
        try Self.encodeOptional(resetAt, to: &values, forKey: .resetAt)
        try Self.encodeOptional(resetCredits, to: &values, forKey: .resetCredits)
        try Self.encodeOptional(resetCreditExpiry, to: &values, forKey: .resetCreditExpiry)
    }

    private static func encodeOptional<Value: Encodable>(
        _ value: Value?,
        to container: inout KeyedEncodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws {
        if let value {
            try container.encode(value, forKey: key)
        } else {
            try container.encodeNil(forKey: key)
        }
    }

    public static let notProven = CodexUsageAccountQuotaSnapshot(availability: .notProven)
}

/// Injection boundary for a donor-owned account session that already exists.
/// CodexUsageProjectionProvider only reads this value; it never creates an
/// account client or acquires credentials on behalf of the consumer.
@MainActor
public protocol CodexUsageAccountQuotaProjectionSource: AnyObject {
    var accountQuotaSnapshot: CodexUsageAccountQuotaSnapshot { get }
}

@MainActor
public protocol CodexUsageAccountQuotaProjectionLifecycle: AnyObject {
    func stop()
}

public struct CodexUsageSessionProjection: Equatable, Sendable {
    public let id: String
    public let displayName: String?
    public let workspaceName: String?
    public let state: String
    public let model: String?
    public let startedAt: Date
    public let completedAt: Date?
    public let lastObservedAt: Date
    public let currentTurnTokens: Int64?
    public let tokenRate: String?
    public let eta: String?
    public let etaConfidence: String?
    public let modelOutputSpeed: String?

    public init(
        id: String? = nil,
        displayName: String?,
        workspaceName: String?,
        state: String,
        model: String?,
        startedAt: Date,
        completedAt: Date? = nil,
        lastObservedAt: Date,
        currentTurnTokens: Int64?,
        tokenRate: String?,
        eta: String?,
        etaConfidence: String? = nil,
        modelOutputSpeed: String? = nil
    ) {
        self.id = id ?? "\(Int64(startedAt.timeIntervalSince1970 * 1_000))|\(workspaceName ?? "")|\(displayName ?? "")"
        self.displayName = displayName
        self.workspaceName = workspaceName
        self.state = state
        self.model = model
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.lastObservedAt = lastObservedAt
        self.currentTurnTokens = currentTurnTokens
        self.tokenRate = tokenRate
        self.eta = eta
        self.etaConfidence = etaConfidence
        self.modelOutputSpeed = modelOutputSpeed
    }
}

public struct CodexUsageLocalMetricProjection: Equatable, Sendable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct CodexUsageProjectionSnapshot: Equatable, Sendable {
    public let availability: CodexUsageProjectionAvailability
    /// Donor-equivalent Chat tracking. This includes terminal cards retained
    /// by the canonical tracking policy until the user dismisses them.
    public let trackedSessions: [CodexUsageSessionProjection]
    public let lastObservedAt: Date?
    public let tokenRateRetentionSeconds: Int
    /// Existing CodexUsageStatus local-ledger metrics. Nil means no trustworthy
    /// ledger snapshot has been loaded; it is never a fabricated zero.
    public let localTokenMetrics: [CodexUsageLocalMetricProjection]?
    public let localTokenMetricsLastObservedAt: Date?
    public let accountQuotaSnapshot: CodexUsageAccountQuotaSnapshot

    public init(
        availability: CodexUsageProjectionAvailability,
        trackedSessions: [CodexUsageSessionProjection],
        lastObservedAt: Date?,
        tokenRateRetentionSeconds: Int,
        localTokenMetrics: [CodexUsageLocalMetricProjection]? = nil,
        localTokenMetricsLastObservedAt: Date? = nil,
        accountQuotaSnapshot: CodexUsageAccountQuotaSnapshot = .notProven
    ) {
        self.availability = availability
        self.trackedSessions = trackedSessions
        self.lastObservedAt = lastObservedAt
        self.tokenRateRetentionSeconds = tokenRateRetentionSeconds
        self.localTokenMetrics = localTokenMetrics
        self.localTokenMetricsLastObservedAt = localTokenMetricsLastObservedAt
        self.accountQuotaSnapshot = accountQuotaSnapshot
    }

    static let initial = CodexUsageProjectionSnapshot(
        availability: .checking,
        trackedSessions: [],
        lastObservedAt: nil,
        tokenRateRetentionSeconds: Int(CodexTokenUsageRateWindow.retentionSeconds)
    )
}

/// A physical local usage-observation root selected by the donor's existing
/// settings UI. Profile attribution is retained so managed roots cannot be
/// merged into the default Codex home namespace.
@_spi(CodexUsageStatusPlanLoopIntegration)
public struct CodexUsageObservationRootConfiguration: Equatable, Sendable {
    public let profileID: UUID?
    public let codexHomeURL: URL

    public init(profileID: UUID?, codexHomeURL: URL) {
        self.profileID = profileID
        self.codexHomeURL = codexHomeURL
    }
}

/// Read-only presentation projection backed by CodexUsageStatus's canonical
/// local observer. This provider never starts UsageViewModel, account clients,
/// login items, or network refreshes.
@MainActor
public final class CodexUsageProjectionProvider: ObservableObject {
    @Published public private(set) var snapshot = CodexUsageProjectionSnapshot.initial

    private var observer: CodexLocalUsageObserver?
    private var projectionTimer: Timer?
    private var observationRoots: [CodexLocalUsageObservationRoot] = []
    private var trackingState = CodexChatTrackingState()
    private var durationSamples: [CodexExecutionDurationSample] = []
    private var durationHistoryScanGeneration: UInt64 = 0
    private var lastObservedAt: Date?
    private let localTokenUsageLedgerStore: LocalTokenUsageLedgerStore
    private var localTokenLedgerModificationDate: Date?
    private var localTokenLedgerFileWasPresent = false
    private var localTokenLedgerLoaded = false
    private var localTokenMetrics: [CodexUsageLocalMetricProjection]?
    private var localTokenMetricsLastObservedAt: Date?
    private var accountQuotaSource: (any CodexUsageAccountQuotaProjectionSource)?
    private var planLoopTurnActivityHandler: ((CodexLocalTurnActivityEvent) -> Void)?
    private var planLoopTurnCompletionHandler: ((UUID?, CodexLocalTurnCompletionRecord) -> Void)?
    private var isStopped = false
    private var hasStarted = false

    /// The donor HUD can render its existing Chat cards from the canonical
    /// observer state without routing preview events through the account
    /// model's notification or persistence handlers.
    var readOnlyPreviewHUDChatExecutions: [CodexChatExecutionTracking] {
        trackingState.cards
    }

    @_spi(CodexUsageStatusPlanLoopIntegration)
    public init(
        observationRoots configuredObservationRoots: [CodexUsageObservationRootConfiguration]? = nil,
        rootURL: URL? = nil,
        cursorURL: URL,
        localLedgerURL: URL? = nil,
        accountQuotaSource: (any CodexUsageAccountQuotaProjectionSource)? = nil,
        automaticallyStarts: Bool = true
    ) {
        let configuredRoot = rootURL ?? CodexLocalUsageObservationRoot.canonicalDefaultHomeURL()
        let rootConfigurations = configuredObservationRoots ?? [
            CodexUsageObservationRootConfiguration(profileID: nil, codexHomeURL: configuredRoot)
        ]
        let roots = Self.normalizedObservationRoots(rootConfigurations)
        observationRoots = roots

        // Read the donor's existing machine-local ledger. The ledger owns the
        // peak/streak/duration calculations; this projection does not parse
        // Codex files or create a second observer.
        let resolvedLocalLedgerURL: URL
        if let localLedgerURL {
            resolvedLocalLedgerURL = localLedgerURL
        } else {
            let tokenActivityStore = TokenActivityStore(loadOnInit: false)
            resolvedLocalLedgerURL = tokenActivityStore.fileURL.deletingLastPathComponent()
                .appendingPathComponent("local-token-usage-ledger.json", isDirectory: false)
        }
        localTokenUsageLedgerStore = LocalTokenUsageLedgerStore(
            fileURL: resolvedLocalLedgerURL,
            loadOnInit: true,
            asynchronousPersistence: false
        )
        self.accountQuotaSource = accountQuotaSource

        try? FileManager.default.createDirectory(
            at: cursorURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        observer = CodexLocalUsageObserver(
            cursorURL: cursorURL,
            turnCompletionHandler: { [weak self] profileID, record in
                self?.receiveCompletion(profileID: profileID, record: record)
            },
            turnActivityHandler: { [weak self] event in
                self?.receive(event)
            },
            activeExecutionReconciliationHandler: { [weak self] reconciliation in
                guard let self, reconciliation.resetActiveExecutions else { return }
                self.trackingState = CodexChatTrackingState()
                self.refreshSnapshot()
            },
            sourceAvailabilityHandler: { [weak self] availability in
                self?.refreshSnapshot(availability: availability)
            }
        )
        observer?.setRoots(roots)
        if automaticallyStarts { start() }
    }

    /// Starts the single local observer after its integration event sink has
    /// been attached. Existing standalone callers keep the previous eager
    /// startup behavior through `automaticallyStarts: true`.
    public func start() {
        guard !isStopped, !hasStarted else { return }
        hasStarted = true
        observer?.start()
        startDurationHistoryScan(for: observationRoots)
        startProjectionTimer()
        refreshSnapshot()
    }

    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        projectionTimer?.invalidate()
        projectionTimer = nil
        observer?.stop()
        observer = nil
        planLoopTurnActivityHandler = nil
        planLoopTurnCompletionHandler = nil
        (accountQuotaSource as? any CodexUsageAccountQuotaProjectionLifecycle)?.stop()
        accountQuotaSource = nil
    }

    func setPlanLoopTurnActivityHandler(_ handler: ((CodexLocalTurnActivityEvent) -> Void)?) {
        guard !isStopped else { return }
        planLoopTurnActivityHandler = handler
    }

    func setPlanLoopTurnCompletionHandler(_ handler: ((UUID?, CodexLocalTurnCompletionRecord) -> Void)?) {
        guard !isStopped else { return }
        planLoopTurnCompletionHandler = handler
    }

    @_spi(CodexUsageStatusPlanLoopIntegration)
    public func setObservationRoots(_ roots: [CodexUsageObservationRootConfiguration]) {
        guard !isStopped else { return }
        let normalizedRoots = Self.normalizedObservationRoots(roots)
        guard normalizedRoots != observationRoots else { return }
        observationRoots = normalizedRoots
        observer?.setRoots(normalizedRoots)
        guard hasStarted else { return }
        startDurationHistoryScan(for: normalizedRoots)
        refreshSnapshot()
    }

    /// Dismisses one tracked card through the donor's existing projection-only
    /// policy. It never changes Codex files, history, or execution state.
    public func dismissTrackedSession(id: String) {
        guard let execution = trackingState.cards.first(where: { Self.sessionID(for: $0) == id }) else { return }
        trackingState = CodexChatExecutionTrackingPolicy.dismissing(execution.key, in: trackingState)
        refreshSnapshot()
    }

    public static func resolvedObservationRoot(
        customRootURL: URL? = nil,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let configuredRoot = customRootURL
            ?? CodexLocalUsageObservationRoot.canonicalDefaultHomeURL(
                fileManager: fileManager,
                environment: environment
            )
        return CodexLocalTurnActivityAuthority.normalizedRoot(configuredRoot)
    }

    private func receive(_ event: CodexLocalTurnActivityEvent) {
        guard !isStopped else { return }
        if lastObservedAt.map({ event.observedAt > $0 }) ?? true {
            lastObservedAt = event.observedAt
        }
        trackingState = CodexChatExecutionTrackingPolicy.applying(event, to: trackingState)
        planLoopTurnActivityHandler?(event)
        refreshSnapshot()
    }

    private func receiveCompletion(
        profileID: UUID?,
        record: CodexLocalTurnCompletionRecord
    ) {
        guard !isStopped else { return }

        // Completion accounting belongs to the donor model just as it does
        // in standalone mode. Forward the observer's profile/thread/turn
        // identity verbatim before applying the separate HUD duration-sample
        // admission check; a valid completion can still update the local
        // aggregate when its presentation card has already been retired.
        planLoopTurnCompletionHandler?(profileID, record)

        guard let execution = trackingState.cards.first(where: {
            $0.key.profileID == profileID
                && $0.key.threadID == record.threadID
                && $0.turnID == record.turnID
        }) else { return }

        let sample = CodexExecutionDurationSample(
            profileID: profileID,
            physicalRootURL: URL(fileURLWithPath: execution.key.normalizedPhysicalRootPath),
            threadID: record.threadID,
            turnID: record.turnID,
            repositoryDisplayName: execution.repositoryDisplayName,
            repositoryIdentityDigest: execution.key.repositoryIdentityDigest,
            workspaceDisplayName: execution.workspaceDisplayName,
            chatName: execution.chatName,
            durationSeconds: record.durationSeconds,
            completedAt: record.completedAt
        )
        durationSamples.removeAll {
            $0.profileID == sample.profileID
                && $0.normalizedPhysicalRootPath == sample.normalizedPhysicalRootPath
                && $0.threadID == sample.threadID
                && $0.turnID == sample.turnID
        }
        durationSamples.append(sample)
        if durationSamples.count > 200 {
            durationSamples.removeFirst(durationSamples.count - 200)
        }
        refreshSnapshot()
    }

    private func startDurationHistoryScan(for roots: [CodexLocalUsageObservationRoot]) {
        durationHistoryScanGeneration &+= 1
        let generation = durationHistoryScanGeneration
        Task { @MainActor [weak self] in
            let samples = await Task.detached(priority: .utility) {
                CodexExecutionDurationHistoryScanner.scan(roots: roots)
            }.value
            guard let self,
                  !self.isStopped,
                  self.durationHistoryScanGeneration == generation else { return }
            self.durationSamples = samples
            self.refreshSnapshot()
        }
    }

    private func startProjectionTimer() {
        projectionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSnapshot()
            }
        }
        if let projectionTimer {
            RunLoop.main.add(projectionTimer, forMode: .common)
        }
    }

    private func refreshSnapshot(availability incomingAvailability: CodexLocalUsageSourceAvailability? = nil) {
        guard !isStopped else { return }
        let availability = incomingAvailability ?? observer?.sourceAvailability ?? .checking
        let trackedExecutions = trackingState.cards
            .sorted {
                if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
                return $0.key.threadID < $1.key.threadID
            }
        let now = Date()
        refreshLocalTokenMetrics(availability: availability, now: now)
        let sessionProjections = trackedExecutions.map { execution in
            let observationTime = execution.state.isTerminal ? (execution.completedAt ?? now) : now
            let rate = execution.tokenRateWindow.rate(at: observationTime)
            let estimate = execution.state.isTerminal ? nil : CodexExecutionEstimationPolicy.estimate(
                for: execution.executionProjection,
                now: now,
                samples: durationSamples
            )
            return CodexUsageSessionProjection(
                id: Self.sessionID(for: execution),
                displayName: execution.chatName,
                workspaceName: execution.repositoryDisplayName ?? execution.workspaceDisplayName,
                state: execution.state.displayName,
                model: execution.model.confidence == .observed ? execution.model.displayText : nil,
                startedAt: execution.startedAt,
                completedAt: execution.completedAt,
                lastObservedAt: execution.lastObservedAt,
                currentTurnTokens: execution.tokenTotal,
                tokenRate: rate == .unavailable ? nil : rate.displayText,
                eta: estimate?.accessibilityText,
                etaConfidence: estimate?.confidenceText,
                modelOutputSpeed: CodexModelOutputRate.notObservable.displayText
            )
        }
        let latestObservedAt = ([lastObservedAt] + trackedExecutions.map(\.lastObservedAt))
            .compactMap { $0 }
            .max()

        snapshot = CodexUsageProjectionSnapshot(
            availability: Self.projectedAvailability(availability),
            trackedSessions: sessionProjections,
            lastObservedAt: latestObservedAt,
            tokenRateRetentionSeconds: Int(CodexTokenUsageRateWindow.retentionSeconds),
            localTokenMetrics: localTokenMetrics,
            localTokenMetricsLastObservedAt: localTokenMetricsLastObservedAt,
            accountQuotaSnapshot: accountQuotaSource?.accountQuotaSnapshot ?? .notProven
        )
    }

    private func refreshLocalTokenMetrics(
        availability: CodexLocalUsageSourceAvailability,
        now: Date
    ) {
        let ledgerURL = localTokenUsageLedgerStore.fileURL
        let exists = FileManager.default.fileExists(atPath: ledgerURL.path)
        if exists {
            let modificationDate = (try? FileManager.default.attributesOfItem(atPath: ledgerURL.path))?[.modificationDate] as? Date
            if !localTokenLedgerLoaded || !localTokenLedgerFileWasPresent
                || modificationDate != localTokenLedgerModificationDate {
                localTokenUsageLedgerStore.load()
                localTokenLedgerLoaded = true
                localTokenLedgerModificationDate = modificationDate
            }
            localTokenLedgerFileWasPresent = true
            guard localTokenUsageLedgerStore.errorMessage == nil else { return }
            localTokenMetrics = LocalTokenUsageLedgerPresentation.metrics(
                snapshot: localTokenUsageLedgerStore.snapshot,
                now: now,
                sourceAvailability: availability
            ).map { CodexUsageLocalMetricProjection(label: $0.label, value: $0.value) }
            localTokenMetricsLastObservedAt = localTokenUsageLedgerStore.snapshot.lastObservedAt
        } else {
            // Keep the last successfully loaded ledger projection during a
            // temporary file disappearance. No file has never meant zero.
            localTokenLedgerFileWasPresent = false
        }
    }

    private static func sessionID(for execution: CodexChatExecutionTracking) -> String {
        "\(execution.key.profileID?.uuidString ?? "default")|\(execution.key.threadID)|\(execution.turnID)"
    }

    private static func normalizedObservationRoots(
        _ roots: [CodexUsageObservationRootConfiguration]
    ) -> [CodexLocalUsageObservationRoot] {
        var seenPaths = Set<String>()
        return roots.compactMap { configuration in
            let physicalRoot = CodexLocalTurnActivityAuthority.normalizedRoot(configuration.codexHomeURL)
            guard seenPaths.insert(physicalRoot.path).inserted else { return nil }
            return CodexLocalUsageObservationRoot(
                profileID: configuration.profileID,
                codexHomeURL: physicalRoot
            )
        }
    }

    private static func projectedAvailability(
        _ availability: CodexLocalUsageSourceAvailability
    ) -> CodexUsageProjectionAvailability {
        switch availability {
        case .checking: return .checking
        case .available: return .available
        case .unavailable: return .unavailable
        }
    }
}

import Foundation
import Combine
import SwiftUI
import UserNotifications
import AppKit

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot? {
        didSet { refreshStatusItemPresentation() }
    }
    @Published private(set) var connectionState: ConnectionState = .disconnected {
        didSet { refreshStatusItemPresentation() }
    }
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date? {
        didSet { refreshStatusItemPresentation() }
    }
    @Published private(set) var currentDate = Date() {
        didSet { refreshStatusItemPresentation() }
    }
    @Published private(set) var historySamples: [HistorySample] = []
    @Published private(set) var historyErrorMessage: String?
    @Published private(set) var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var accessibilityPermissionState: AccessibilityPermissionState = .unavailable
    @Published private(set) var notificationsEnabled: Bool
    @Published private(set) var separateWindowNotifications: Bool
    @Published private(set) var notificationSoundEnabled: Bool
    @Published private(set) var tokenReelSoundEnabled: Bool
    @Published private(set) var notificationThresholds: [Int]
    @Published private(set) var tokenActivity: TokenActivitySnapshot?
    /// Range-independent five-field projection used by the HUD. Keeping only
    /// the visible metrics published (rather than the raw fetched timestamp or
    /// daily buckets) prevents chart-range changes and timestamp churn from
    /// redrawing the compact summary.
    @Published private(set) var hudTokenActivityMetrics: [TokenActivityMetric]?
    @Published private(set) var hudTokenActivityFeedback: TokenHeroUpdateFeedback?
    @Published private(set) var tokenActivityState: TokenActivityState = .idle
    @Published private(set) var tokenActivityErrorMessage: String?
    @Published private(set) var resetCredits: RateLimitResetCredits?
    @Published private(set) var selectedResetCreditID: String?
    @Published private(set) var resetCreditOperationState: ResetCreditOperationState = .idle
    @Published private(set) var resetCreditMessage: String?
    @Published private(set) var accountHealth: AccountHealthSnapshot?
    @Published private(set) var accountHealthState: AccountHealthState = .idle
    @Published private(set) var accountHealthErrorMessage: String?
    @Published private(set) var accountProfiles: [AccountProfile] = []
    @Published private(set) var profileStoreErrorMessage: String?
    @Published private(set) var currentProfileID: UUID?
    @Published private(set) var workerStates: [UUID: ConnectionState] = [:]
    @Published private(set) var workerErrors: [UUID: String] = [:]
    @Published private(set) var localProfileActivityVersion: UInt64 = 0
    @Published private(set) var loginStates: [UUID: String] = [:]
    @Published private(set) var quotaRefreshIntervalSeconds: Int = RefreshCadenceDefaults.quotaSeconds
    @Published private(set) var globalSyncIntervalSeconds: Int = RefreshCadenceDefaults.accountSeconds
    @Published private(set) var tokenActivityRefreshIntervalSeconds: Int = RefreshCadenceDefaults.tokenActivitySeconds
    @Published private(set) var credentialWatchIntervalSeconds: Int = 15
    @Published private(set) var activeTurn: TurnActivitySnapshot = .idle {
        didSet { refreshStatusItemPresentation() }
    }
    /// Rollout/session observation is the single user-visible Turn authority.
    /// These capabilities are factual limits of the metadata-only source, not
    /// user preferences and not a second polling subsystem.
    var localTurnObservationCapabilities: CodexLocalTurnObservationCapabilities {
        CodexLocalTurnObservationCapabilities.current
    }
    var turnFailureNotificationSupported: Bool { localTurnObservationCapabilities.failed }
    var turnInterruptedNotificationSupported: Bool { localTurnObservationCapabilities.interrupted }
    var turnContentNotificationSupported: Bool { localTurnObservationCapabilities.content }
    @Published private(set) var notifyOnTurnSuccess: Bool
    @Published private(set) var notifyOnTurnFailure: Bool
    @Published private(set) var notifyOnTurnInterrupted: Bool
    @Published private(set) var notifyOnLongRunningTurn: Bool
    @Published private(set) var longRunningThresholdMinutes: Int
    @Published private(set) var showTurnContentInNotifications: Bool
    @Published private(set) var notifyOnAccountSwitch: Bool
    @Published private(set) var floatingHUDEnabled: Bool
    @Published private(set) var updateState: AppUpdateState = .idle
    @Published var historyRange: HistoryRange = .week
    @Published var tokenActivityRange: TokenActivityRange = .week
    @Published var accountScope: AccountScope = .current
    @Published private(set) var statusItemPresentation = StatusItemPresentation.placeholder
    /// Transient Rapid Drain events are deliberately a non-replaying stream;
    /// the canonical status presentation remains state, while this subject is
    /// consumed once by the AppDelegate animator.
    let rapidDrainEvents = PassthroughSubject<ObservedRapidDrainEvent, Never>()

    let loginItemManager = LoginItemManager()

    private let client = CodexAppServerClient()
    private var managedWorkers: [UUID: ManagedAccountWorker] = [:]
    private var managedSnapshots: [UUID: UsageSnapshot] = [:]
    private var managedTokenActivities: [UUID: TokenActivitySnapshot] = [:]
    private var managedAccountHealth: [UUID: AccountHealthSnapshot] = [:]
    private var workerGenerations: [UUID: UUID] = [:]
    private let accountManagementService = AccountManagementService()
    private var historyStore: HistoryStore
    private var tokenActivityStore: TokenActivityStore
    private var localTokenUsageLedgerStore: LocalTokenUsageLedgerStore
    private var localUsageObserver: CodexLocalUsageObserver?
    private var activeTurnSourceKey: String?
    private let profileStore: AccountProfileStore
    private let legacyHistoryURL: URL
    private let legacyTokenActivityURL: URL
    private let notificationService = UsageNotificationService()
    private let turnNotificationService = TurnNotificationService()
    private let updateService = AppUpdateService()
    private let updateNotificationService = AppUpdateNotificationService()
    private let defaults = UserDefaults.standard
    private var displayTimer: Timer?
    private var hudTokenActivityFetchedAt: Date?
    /// Latest successful fetch timestamps are kept separate from semantic
    /// snapshots so freshness can move forward without publishing unchanged
    /// quota/token payloads.
    private var tokenActivityLastFetchedAt: Date?
    private var managedTokenActivityLastFetchedAt: [UUID: Date] = [:]
    /// A delta is shown only while this process can tie it to a factual
    /// ledger callback. Persisted thread timestamps remain the authority for
    /// activity age after restart.
    private var latestLocalObservedDeltas: [String: Int64] = [:]
    private var latestLocalObservedDeltaDates: [String: Date] = [:]
    private var hudTokenActivitySummary: TokenActivitySnapshot?
    private var hudTokenActivityFeedbackGeneration: UInt64 = 0
    private var tokenActivitySoundGate = TokenActivitySoundGate()
    private let tokenReelAudioPlayer = TokenReelAudioFeedbackPlayer()
    private var rapidDrainDetector = RapidDrainDetector()
    private var updateCheckTimer: Timer?
    private var pendingUnidentifiedProfileBoundary = false
    private var defaultClientEnabled = true
    private let maxConcurrentWorkers = ManagedWorkerAdmissionPolicy.maxActiveAppServers
    private var isSchedulingWorkers = false
    private var workerReplacementTasks: [UUID: Task<Void, Never>] = [:]
    private var isStopping = false
    private var localStoresLoaded = false
    private var startupTask: Task<Void, Never>?
    private var defaultClientStopTask: Task<Void, Never>?

    private enum PreferenceKey {
        static let notificationsEnabled = "usage.notifications.enabled"
        static let separateWindows = "usage.notifications.separateWindows"
        static let soundEnabled = "usage.notifications.soundEnabled"
        static let tokenReelSoundEnabled = TokenReelSoundPreference.key
        static let thresholds = "usage.notifications.thresholds"
        static let turnSuccess = "turn.notifications.success"
        static let turnFailure = "turn.notifications.failure"
        static let turnInterrupted = "turn.notifications.interrupted"
        static let turnLongRunning = "turn.notifications.longRunning"
        static let turnLongRunningMinutes = "turn.notifications.longRunningMinutes"
        static let turnContent = "turn.notifications.content"
        static let accountSwitch = "account.notifications.switch"
        static let activeProfile = "accounts.activeProfile"
        static let quotaRefreshInterval = "sync.quota.interval"
        static let tokenActivityRefreshInterval = "sync.tokenActivity.interval"
        static let credentialWatchInterval = "sync.credentialWatch.interval"
        static let accountRefreshInterval = "accounts.sync.interval"
        static let floatingHUDEnabled = "ui.floatingHUD.enabled"
    }

    init() {
        RetiredFeatureCleanup.run()
        let store = HistoryStore(loadOnInit: false, asynchronousPersistence: true)
        historyStore = store
        legacyHistoryURL = store.fileURL
        historySamples = store.samples
        historyErrorMessage = store.errorMessage
        let activityStore = TokenActivityStore(loadOnInit: false, asynchronousPersistence: true)
        tokenActivityStore = activityStore
        localTokenUsageLedgerStore = LocalTokenUsageLedgerStore(
            fileURL: activityStore.fileURL.deletingLastPathComponent()
                .appendingPathComponent("local-token-usage-ledger.json"),
            loadOnInit: false,
            asynchronousPersistence: true
        )
        localUsageObserver = nil
        legacyTokenActivityURL = activityStore.fileURL
        tokenActivity = activityStore.snapshot
        tokenActivityLastFetchedAt = activityStore.snapshot?.fetchedAt
        tokenActivityState = activityStore.snapshot == nil ? .idle : .loaded
        tokenActivityErrorMessage = activityStore.errorMessage
        notificationsEnabled = defaults.object(forKey: PreferenceKey.notificationsEnabled) as? Bool ?? true
        separateWindowNotifications = defaults.object(forKey: PreferenceKey.separateWindows) as? Bool ?? true
        notificationSoundEnabled = defaults.object(forKey: PreferenceKey.soundEnabled) as? Bool ?? false
        tokenReelSoundEnabled = TokenReelSoundPreference.load(from: defaults)
        accessibilityPermissionState = AccessibilityPermissionPolicy.current()
        notificationThresholds = Self.loadThresholds(from: defaults)
        notifyOnTurnSuccess = defaults.object(forKey: PreferenceKey.turnSuccess) as? Bool ?? false
        notifyOnTurnFailure = defaults.object(forKey: PreferenceKey.turnFailure) as? Bool ?? true
        notifyOnTurnInterrupted = defaults.object(forKey: PreferenceKey.turnInterrupted) as? Bool ?? true
        notifyOnLongRunningTurn = defaults.object(forKey: PreferenceKey.turnLongRunning) as? Bool ?? false
        longRunningThresholdMinutes = max(1, defaults.object(forKey: PreferenceKey.turnLongRunningMinutes) as? Int ?? 10)
        // Turn content is intentionally opt-in: prompts and code can contain secrets.
        showTurnContentInNotifications = defaults.object(forKey: PreferenceKey.turnContent) as? Bool ?? false
        notifyOnAccountSwitch = defaults.object(forKey: PreferenceKey.accountSwitch) as? Bool ?? false
        floatingHUDEnabled = defaults.object(forKey: PreferenceKey.floatingHUDEnabled) as? Bool ?? true
        profileStore = AccountProfileStore(loadOnInit: false, asynchronousPersistence: true)
        accountProfiles = []
        profileStoreErrorMessage = profileStore.errorMessage
        quotaRefreshIntervalSeconds = Self.clampQuotaInterval(
            defaults.object(forKey: PreferenceKey.quotaRefreshInterval) as? Int ?? RefreshCadenceDefaults.quotaSeconds
        )
        globalSyncIntervalSeconds = Self.clampAccountInterval(
            defaults.object(forKey: PreferenceKey.accountRefreshInterval) as? Int ?? RefreshCadenceDefaults.accountSeconds
        )
        tokenActivityRefreshIntervalSeconds = Self.clampTokenInterval(
            defaults.object(forKey: PreferenceKey.tokenActivityRefreshInterval) as? Int ?? RefreshCadenceDefaults.tokenActivitySeconds
        )
        credentialWatchIntervalSeconds = Self.clampCredentialWatchInterval(defaults.object(forKey: PreferenceKey.credentialWatchInterval) as? Int ?? 15)
        client.updateIntervals(
            quota: quotaRefreshIntervalSeconds,
            usage: tokenActivityRefreshIntervalSeconds,
            account: globalSyncIntervalSeconds,
            credentialWatch: credentialWatchIntervalSeconds
        )
        accountManagementService.onLoginOutput = { [weak self] profileID, output in
            self?.loginStates[profileID] = output
        }
        updateService.onStateChange = { [weak self] state in
            self?.updateState = state
        }
        client.onStateChange = { [weak self] state, message in
            guard let self else { return }
            guard self.defaultClientEnabled else { return }
            if self.connectionState != state { self.connectionState = state }
            if state == .offline, self.accountHealthState != .offline { self.accountHealthState = .offline }
            if state == .offline || state == .error || state == .stopped {
                self.rapidDrainDetector.reset()
            }
            if let message, !message.isEmpty {
                if self.errorMessage != message { self.errorMessage = message }
            } else if state == .connected, self.errorMessage != nil {
                self.errorMessage = nil
            }

            if (state == .offline || state == .error), let snapshot = self.snapshot {
                self.historyStore.record(snapshot: snapshot, connectionState: state, now: Date())
                self.syncHistoryState()
            }
        }
        client.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            guard self.defaultClientEnabled else { return }
            guard !self.pendingUnidentifiedProfileBoundary else { return }
            let rapidDrainEvent = self.observeRapidDrain(snapshot: snapshot, profileID: self.currentProfileID)
            let semanticChange = self.snapshot.map { !$0.hasSameContent(as: snapshot) } ?? true
            // Freshness metadata remains published so stale badges and HUD
            // visibility stay correct; the semantic quota projections,
            // history persistence, and notifications below are change-gated.
            self.lastUpdated = snapshot.receivedAt
            self.currentDate = Date()
            self.errorMessage = nil
            guard semanticChange else { return }
            self.snapshot = snapshot
            self.resetCredits = snapshot.rateLimitResetCredits
            if let selected = self.selectedResetCreditID,
               !(snapshot.rateLimitResetCredits?.availableCredits.contains(where: { $0.id == selected }) ?? false) {
                self.selectedResetCreditID = nil
            }
            // A valid snapshot callback is live even though the client publishes
            // .connected immediately after invoking this callback.  History is
            // written only after the semantic quota payload changes.
            self.historyStore.record(snapshot: snapshot, connectionState: .connected, now: snapshot.receivedAt)
            self.syncHistoryState()
            self.evaluateLiveNotifications(
                snapshot: snapshot,
                profileID: self.currentProfileID,
                rapidDrainEvent: rapidDrainEvent
            )
        }
        client.onTokenActivityState = { [weak self] state, message in
            guard let self else { return }
            guard self.defaultClientEnabled else { return }
            if self.tokenActivityState != state { self.tokenActivityState = state }
            if self.tokenActivityErrorMessage != message { self.tokenActivityErrorMessage = message }
        }
        client.onTokenActivity = { [weak self] activity in
            guard let self else { return }
            guard self.defaultClientEnabled else { return }
            self.tokenActivityLastFetchedAt = activity.fetchedAt
            self.refreshHUDTokenActivityFetchedAt()
            let merged = self.tokenActivityStore.update(incoming: activity)
            guard self.tokenActivityStore.lastUpdateChanged else {
                if self.tokenActivityState != .loaded { self.tokenActivityState = .loaded }
                self.tokenActivityErrorMessage = self.tokenActivityStore.errorMessage
                return
            }
            self.tokenActivity = merged
            self.refreshHUDTokenActivitySummary()
            self.tokenActivityState = .loaded
            self.tokenActivityErrorMessage = self.tokenActivityStore.errorMessage
        }
        client.onAccountHealthState = { [weak self] state, message in
            guard let self else { return }
            guard self.defaultClientEnabled else { return }
            if self.accountHealthState != state { self.accountHealthState = state }
            if self.accountHealthErrorMessage != message { self.accountHealthErrorMessage = message }
        }
        client.onAccountHealth = { [weak self] health in
            guard let self else { return }
            guard self.defaultClientEnabled else { return }
            self.handleAccountHealth(health)
        }
        client.onAccountBoundary = { [weak self] in
            guard let self else { return }
            guard self.defaultClientEnabled else { return }
            self.rapidDrainDetector.reset()
            self.pendingUnidentifiedProfileBoundary = true
            self.snapshot = nil
            self.lastUpdated = nil
            self.tokenActivity = nil
            self.tokenActivityLastFetchedAt = nil
            self.refreshHUDTokenActivitySummary()
            self.tokenActivityState = .idle
            self.resetCredits = nil
            self.selectedResetCreditID = nil
            self.resetCreditOperationState = .idle
            self.activeTurn = .unknownSnapshot()
            self.activeTurnSourceKey = nil
            self.accountHealthState = .loading
        }
        // App Server remains the quota/account transport, but its Turn events
        // are deliberately not projected into the user-visible Turn card.
        // Codex Desktop rollout/session metadata is the single activity
        // authority, which avoids two competing timelines.
        client.onTurnEvent = nil
        client.onTurnTokenUsage = nil
        client.onResetCreditResult = { [weak self] outcome in
            guard let self else { return }
            guard self.defaultClientEnabled else { return }
            self.resetCreditMessage = outcome.displayText
            switch outcome {
            case .reset: self.resetCreditOperationState = .succeeded
            case .alreadyRedeemed: self.resetCreditOperationState = .alreadyRedeemed
            case .nothingToReset: self.resetCreditOperationState = .nothingToReset
            case .noCredit: self.resetCreditOperationState = .noCredit
            case .unknown: self.resetCreditOperationState = .unknown
            case .error: self.resetCreditOperationState = .error
            }
            if outcome.succeeded { self.selectedResetCreditID = nil }
        }

        notificationService.refreshAuthorization { [weak self] status in
            self?.notificationAuthorizationStatus = status
        }
        refreshHUDTokenActivitySummary()
        refreshStatusItemPresentation()

        localUsageObserver = CodexLocalUsageObserver(
            cursorURL: profileStore.containerURL.appendingPathComponent("codex-local-usage-cursors.json"),
            handler: { [weak self] profileID, record in
                self?.handleLocalUsageRecord(profileID: profileID, record: record)
            },
            turnCompletionHandler: { [weak self] profileID, record in
                self?.handleLocalTurnCompletion(profileID: profileID, record: record)
            },
            turnActivityHandler: { [weak self] event in
                self?.handleLocalTurnActivity(event)
            }
        )
    }

    deinit {
        displayTimer?.invalidate()
        updateCheckTimer?.invalidate()
        startupTask?.cancel()
    }

    func start() {
        isStopping = false
        updateService.start()
        loginItemManager.refresh()
        loginItemManager.registerIfNeeded()
        startDisplayTimer()
        // Update checks are deliberately deferred; they are network work and
        // must never delay the first interactive status-item frame.
        startupTask?.cancel()
        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.historyStore.loadAsynchronously { [weak self] in
                guard let self else { return }
                self.syncHistoryState()
            }
            self.tokenActivityStore.loadAsynchronously { [weak self] in
                guard let self else { return }
                self.tokenActivity = self.tokenActivityStore.snapshot
                self.tokenActivityLastFetchedAt = self.tokenActivityStore.snapshot?.fetchedAt
                self.refreshHUDTokenActivitySummary()
                self.tokenActivityErrorMessage = self.tokenActivityStore.errorMessage
            }
            // The machine ledger is authoritative for live Token feedback. Finish
            // hydrating it before any App Server can publish a new observation,
            // otherwise a late disk read could overwrite an event accepted during
            // startup.
            await withCheckedContinuation { continuation in
                self.localTokenUsageLedgerStore.loadAsynchronously {
                    self.localProfileActivityVersion &+= 1
                    continuation.resume()
                }
            }
            self.refreshHUDTokenActivitySummary()
            await withCheckedContinuation { continuation in
                self.profileStore.loadAsynchronously { continuation.resume() }
            }
            guard !self.isStopping else { return }
            self.finishStartupAfterLocalStores()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, !self.isStopping else { return }
            self.checkForUpdates()
        }
    }

    private func finishStartupAfterLocalStores() {
        guard !localStoresLoaded else { return }
        localStoresLoaded = true
        defaultClientEnabled = true
        accountProfiles = profileStore.accountProfiles()
        refreshHUDTokenActivitySummary()
        if let savedID = defaults.string(forKey: PreferenceKey.activeProfile),
           let id = UUID(uuidString: savedID),
           let profile = profileStore.profile(for: id) {
            currentProfileID = id
            switchToProfile(profile)
            defaultClientEnabled = !profile.isManaged
        }
        startUpdateCheckTimer()
        if let profile = currentProfile, profile.isManaged {
            defaultClientEnabled = false
            ensureManagedWorker(for: profile)
        } else {
            client.start()
        }
        refreshLocalUsageObserverRoots()
        localUsageObserver?.start()
        startManagedWorkers()
    }

    func stop() {
        isStopping = true
        defaultClientEnabled = false
        rapidDrainDetector.reset()
        displayTimer?.invalidate()
        displayTimer = nil
        updateCheckTimer?.invalidate()
        updateCheckTimer = nil
        localUsageObserver?.stop()
        client.stop()
        accountManagementService.stopAllLogins()
        for worker in managedWorkers.values { worker.stop() }
        workerReplacementTasks.values.forEach { $0.cancel() }
        workerReplacementTasks.removeAll()
        managedWorkers.removeAll()
        startupTask?.cancel()
        startupTask = nil
        tokenReelAudioPlayer.cancel()
        defaultClientStopTask?.cancel()
        defaultClientStopTask = nil
        Task { [historyStore, tokenActivityStore] in
            await historyStore.flushPendingWrites()
            await tokenActivityStore.flushPendingWrites()
            await PersistenceWriteCoordinator.shared.flush()
        }
    }

    /// Bounded termination hook used by AppDelegate's terminate-later reply.
    /// All disk work happens off the main actor and is capped by the shared
    /// coordinator timeout so shutdown cannot hang indefinitely.
    func prepareForTermination() async {
        stop()
        await PersistenceWriteCoordinator.shared.flush(timeoutNanoseconds: TerminationFlushPolicy.timeoutNanoseconds)
    }

    func refresh() {
        currentDate = Date()
        refreshHUDTokenActivitySummary()
        refreshAccessibilityPermissionState()
        activeClient.refresh()
    }

    func refreshAccessibilityPermissionState() {
        accessibilityPermissionState = AccessibilityPermissionPolicy.current()
    }

    func openAccessibilitySettings() {
        AccessibilityPermissionPolicy.openSettings()
    }

    func refreshTokenActivity() {
        activeClient.refreshTokenActivity()
    }

    func refreshAccount() {
        activeClient.refreshAccount()
    }

    func checkForUpdates() {
        updateService.check { [weak self] state in
            guard let self else { return }
            self.updateState = state
            if case .available(let release) = state {
                self.updateNotificationService.notifyIfNeeded(for: release, soundEnabled: self.notificationSoundEnabled)
            }
        }
        // Publish the service's immediate state as well.  This keeps every
        // entry point (startup, HUD, context menu, and details panel) in sync
        // even when a previous request is being invalidated and restarted.
        updateState = updateService.state
    }

    func openUpdateReleasePage() {
        updateService.openReleasePage()
    }

    func setAccountScope(_ scope: AccountScope) {
        guard accountScope != scope else { return }
        accountScope = scope
        hudTokenActivityFeedback = nil
        refreshHUDTokenActivitySummary()
        currentDate = Date()
    }

    func selectProfile(id: UUID) {
        guard let profile = profileStore.profile(for: id), currentProfileID != id else { return }
        switchToProfile(profile)
        rapidDrainDetector.reset()
        currentProfileID = id
        defaults.set(id.uuidString, forKey: PreferenceKey.activeProfile)
        accountProfiles = profileStore.accountProfiles()
        refreshLocalUsageObserverRoots()
        activeTurn = .unknownSnapshot()
        activeTurnSourceKey = nil
        selectedResetCreditID = nil
        resetCreditOperationState = .idle
        resetCreditMessage = "已切換到 \(profile.displayName)"
        defaultClientEnabled = !profile.isManaged
        if profile.isManaged {
            defaultClientEnabled = false
            defaultClientStopTask?.cancel()
            defaultClientStopTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.client.stopAndWait()
                guard !self.isStopping, self.currentProfileID == id else { return }
                self.defaultClientStopTask = nil
                self.ensureManagedWorker(for: profile)
                self.scheduleManagedWorkers(preferredID: id)
            }
        }
        if profile.isManaged { ensureManagedWorker(for: profile) }
        if let worker = managedWorkers[id] {
            applyManagedCachedData(for: id)
            if profileStore.hasCredentials(for: profile) {
                if defaultClientStopTask == nil {
                    scheduleManagedWorkers(preferredID: id)
                    if worker.isRunning { worker.refresh() }
                }
            }
        } else {
            client.refreshRateLimits()
            client.refreshTokenActivity()
            client.refreshAccount()
        }
    }

    @discardableResult
    func createManualProfile() -> AccountProfile? {
        let profile = profileStore.createManagedProfile()
        ensureManagedWorker(for: profile)
        switchToProfile(profile)
        currentProfileID = profile.id
        accountProfiles = profileStore.accountProfiles()
        refreshLocalUsageObserverRoots()
        activeTurn = .unknownSnapshot()
        activeTurnSourceKey = nil
        selectedResetCreditID = nil
        resetCreditOperationState = .idle
        resetCreditMessage = "已建立 \(profile.displayName)"
        if profileStore.hasCredentials(for: profile) {
            scheduleManagedWorkers(preferredID: profile.id)
            if managedWorkers[profile.id]?.isRunning == true { managedWorkers[profile.id]?.refresh() }
        }
        return profile
    }

    func createManagedProfile(displayName: String? = nil) -> AccountProfile? {
        let profile = profileStore.createManagedProfile(displayName: displayName)
        ensureManagedWorker(for: profile)
        selectProfile(id: profile.id)
        return profile
    }

    func startOfficialLogin(for profileID: UUID) {
        guard let profile = profileStore.profile(for: profileID) else { return }
        loginStates[profileID] = "正在啟動官方登入…"
        accountManagementService.startOfficialLogin(profile: profile, codexHomeURL: profileStore.codexHomeURL(for: profile)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.loginStates[profileID] = "登入完成，正在同步…"
                self.profileStore.setWorkerEnabled(true, for: profileID)
                self.ensureManagedWorker(for: profile)
                self.scheduleManagedWorkers(preferredID: profileID)
                if self.managedWorkers[profileID]?.isRunning == true { self.managedWorkers[profileID]?.refresh() }
            case .failure(let error):
                self.loginStates[profileID] = error.localizedDescription
            }
        }
    }

    func importProfileForCurrentAccount() {
        let profile: AccountProfile
        if let current = currentProfile, current.isManaged {
            profile = current
        } else {
            guard let created = createManagedProfile() else { return }
            profile = created
        }
        profileStore.setManaged(true, for: profile.id)
        guard let source = accountManagementService.chooseCodexHome() else { return }
        do {
            try profileStore.importCodexHome(from: source, into: profile)
            loginStates[profile.id] = "已匯入 profile，正在同步…"
            ensureManagedWorker(for: profile)
            scheduleManagedWorkers(preferredID: profile.id)
            if managedWorkers[profile.id]?.isRunning == true { managedWorkers[profile.id]?.refresh() }
        } catch {
            loginStates[profile.id] = error.localizedDescription
        }
    }

    func setGlobalSyncInterval(_ seconds: Int) {
        globalSyncIntervalSeconds = Self.clampAccountInterval(seconds)
        defaults.set(globalSyncIntervalSeconds, forKey: PreferenceKey.accountRefreshInterval)
        client.updateIntervals(account: globalSyncIntervalSeconds)
        for profile in profileStore.accountProfiles() where profile.isManaged {
            profileStore.setSyncInterval(globalSyncIntervalSeconds, for: profile.id)
        }
        updateManagedWorkerIntervalsAndSchedule()
    }

    func setQuotaRefreshInterval(_ seconds: Int) {
        quotaRefreshIntervalSeconds = Self.clampQuotaInterval(seconds)
        defaults.set(quotaRefreshIntervalSeconds, forKey: PreferenceKey.quotaRefreshInterval)
        client.updateIntervals(quota: quotaRefreshIntervalSeconds)
        updateManagedWorkerIntervalsAndSchedule()
    }

    func setTokenActivityRefreshInterval(_ seconds: Int) {
        tokenActivityRefreshIntervalSeconds = Self.clampTokenInterval(seconds)
        defaults.set(tokenActivityRefreshIntervalSeconds, forKey: PreferenceKey.tokenActivityRefreshInterval)
        client.updateIntervals(usage: tokenActivityRefreshIntervalSeconds)
        updateManagedWorkerIntervalsAndSchedule()
    }

    func setCredentialWatchInterval(_ seconds: Int) {
        credentialWatchIntervalSeconds = Self.clampCredentialWatchInterval(seconds)
        defaults.set(credentialWatchIntervalSeconds, forKey: PreferenceKey.credentialWatchInterval)
        client.updateIntervals(credentialWatch: credentialWatchIntervalSeconds)
        updateManagedWorkerIntervalsAndSchedule()
    }

    func removeProfile(id: UUID) {
        accountManagementService.stopLogin(profileID: id)
        // Invalidate the callback generation before stopping the worker. The
        // stop transition is synchronous; clearing it first prevents the
        // scheduler from recreating a profile that is in the middle of being
        // deleted.
        workerGenerations[id] = nil
        managedWorkers[id]?.stop()
        managedWorkers[id] = nil
        managedSnapshots[id] = nil
        managedTokenActivities[id] = nil
        managedTokenActivityLastFetchedAt[id] = nil
        managedAccountHealth[id] = nil
        guard profileStore.deleteProfile(id: id) else { return }
        accountProfiles = profileStore.accountProfiles()
        refreshHUDTokenActivitySummary()
        if currentProfileID == id {
            currentProfileID = nil
            defaults.removeObject(forKey: PreferenceKey.activeProfile)
            if let next = accountProfiles.first {
                selectProfile(id: next.id)
            } else {
                snapshot = nil
                tokenActivity = nil
                refreshHUDTokenActivitySummary()
                accountHealth = nil
            }
        }
        scheduleManagedWorkers(preferredID: currentProfileID)
    }

    func setTurnSuccessNotifications(_ enabled: Bool) { notifyOnTurnSuccess = enabled; defaults.set(enabled, forKey: PreferenceKey.turnSuccess) }
    func setTurnFailureNotifications(_ enabled: Bool) { notifyOnTurnFailure = enabled; defaults.set(enabled, forKey: PreferenceKey.turnFailure) }
    func setTurnInterruptedNotifications(_ enabled: Bool) { notifyOnTurnInterrupted = enabled; defaults.set(enabled, forKey: PreferenceKey.turnInterrupted) }
    func setLongRunningTurnNotifications(_ enabled: Bool) { notifyOnLongRunningTurn = enabled; defaults.set(enabled, forKey: PreferenceKey.turnLongRunning) }
    func setLongRunningThresholdMinutes(_ minutes: Int) { longRunningThresholdMinutes = max(1, min(240, minutes)); defaults.set(longRunningThresholdMinutes, forKey: PreferenceKey.turnLongRunningMinutes) }
    func setTurnContentInNotifications(_ enabled: Bool) { showTurnContentInNotifications = enabled; defaults.set(enabled, forKey: PreferenceKey.turnContent) }
    func setAccountSwitchNotifications(_ enabled: Bool) { notifyOnAccountSwitch = enabled; defaults.set(enabled, forKey: PreferenceKey.accountSwitch) }
    func setFloatingHUDEnabled(_ enabled: Bool) { floatingHUDEnabled = enabled; defaults.set(enabled, forKey: PreferenceKey.floatingHUDEnabled) }

    func selectResetCredit(id: String?) {
        guard let id,
              resetCredits?.availableCredits.contains(where: { $0.id == id }) == true else {
            selectedResetCreditID = nil
            return
        }
        selectedResetCreditID = id
        resetCreditMessage = nil
        if resetCreditOperationState != .consuming { resetCreditOperationState = .idle }
    }

    func consumeSelectedResetCredit() {
        guard accountScope == .current else {
            resetCreditMessage = "請切回目前帳號後再使用 Reset credit。"
            resetCreditOperationState = .idle
            return
        }
        guard let id = selectedResetCreditID,
              resetCredits?.availableCredits.contains(where: { $0.id == id }) == true,
              resetCreditOperationState != .consuming else { return }
        resetCreditOperationState = .consuming
        resetCreditMessage = "正在使用 Reset credit…"
        activeClient.consumeResetCredit(creditID: id)
    }

    func cancelResetCredit() {
        guard resetCreditOperationState != .consuming else { return }
        resetCreditMessage = nil
        resetCreditOperationState = .idle
    }

    func clearHistory() {
        historyStore.clear()
        syncHistoryState()
    }

    func requestNotificationPermission() {
        notificationService.requestAuthorization { [weak self] status in
            guard let self else { return }
            self.notificationAuthorizationStatus = status
            if status == .authorized || status == .provisional {
                self.evaluateCurrentSnapshot()
            }
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        notificationsEnabled = enabled
        defaults.set(enabled, forKey: PreferenceKey.notificationsEnabled)
        if enabled && notificationAuthorizationStatus == .notDetermined {
            requestNotificationPermission()
        }
    }

    func setSeparateWindowNotifications(_ enabled: Bool) {
        separateWindowNotifications = enabled
        defaults.set(enabled, forKey: PreferenceKey.separateWindows)
    }

    func setNotificationSoundEnabled(_ enabled: Bool) {
        notificationSoundEnabled = enabled
        defaults.set(enabled, forKey: PreferenceKey.soundEnabled)
    }

    func setTokenReelSoundEnabled(_ enabled: Bool) {
        tokenReelSoundEnabled = enabled
        defaults.set(enabled, forKey: PreferenceKey.tokenReelSoundEnabled)
        if !enabled {
            tokenReelAudioPlayer.cancel()
        }
    }

    func previewTokenReelSound() {
        guard tokenReelSoundEnabled else { return }
        tokenReelAudioPlayer.preview(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    func setThreshold(_ threshold: Int, enabled: Bool) {
        var values = Set(notificationThresholds)
        if enabled {
            values.insert(max(1, min(99, threshold)))
        } else {
            values.remove(threshold)
        }
        notificationThresholds = values.sorted(by: >)
        defaults.set(notificationThresholds, forKey: PreferenceKey.thresholds)
        if let snapshot {
            historyStore.record(
                snapshot: snapshot,
                connectionState: connectionState,
                now: currentDate,
                force: true
            )
            syncHistoryState()
        }
    }

    private var activeClient: CodexAppServerClient {
        if let id = currentProfileID, let worker = managedWorkers[id] {
            return worker.client
        }
        return client
    }

    private func startManagedWorkers() {
        scheduleManagedWorkers(preferredID: currentProfileID)
    }

    /// Updates existing App Server polling schedules in place and then lets
    /// the central scheduler fill at most two process slots. Changing an
    /// interval must never recreate every worker (or briefly start all
    /// profiles) on the main actor.
    private func updateManagedWorkerIntervalsAndSchedule() {
        for profile in profileStore.accountProfiles() where profile.isManaged {
            ensureManagedWorker(for: profile)
            managedWorkers[profile.id]?.updateIntervals(
                quota: quotaRefreshIntervalSeconds,
                usage: tokenActivityRefreshIntervalSeconds,
                account: globalSyncIntervalSeconds,
                credentialWatch: credentialWatchIntervalSeconds
            )
        }
        scheduleManagedWorkers(preferredID: currentProfileID)
    }

    /// The sole admission point for managed workers.  It prioritizes the
    /// selected account, starts no more than `maxConcurrentWorkers`, and
    /// leaves the remaining profiles explicitly queued; at most one managed
    /// App Server process belongs to the selected account at any time.
    private func scheduleManagedWorkers(preferredID: UUID? = nil) {
        guard !isSchedulingWorkers, !isStopping else { return }
        isSchedulingWorkers = true
        defer { isSchedulingWorkers = false }

        let eligible = profileStore.accountProfiles().filter {
            $0.isManaged && $0.id == currentProfileID
                && $0.workerEnabled && profileStore.hasCredentials(for: $0)
        }
        let eligibleIDs = Set(eligible.map(\.id))
        for profile in eligible { ensureManagedWorker(for: profile) }

        // Stop workers that are no longer eligible before allocating slots.
        // Their child processes may still be handling SIGTERM, so defer new
        // admission until each stopAndWait task has completed.
        var waitingForWorkerExit = false
        for (id, worker) in managedWorkers where !eligibleIDs.contains(id) {
            guard worker.isRunning else { continue }
            if workerReplacementTasks[id] == nil {
                workerReplacementTasks[id] = Task { @MainActor [weak self, weak worker] in
                    await worker?.stopAndWait()
                    guard let self, !self.isStopping else { return }
                    self.workerReplacementTasks[id] = nil
                    self.scheduleManagedWorkers(preferredID: self.currentProfileID)
                }
            }
            waitingForWorkerExit = true
        }
        guard !waitingForWorkerExit else { return }

        let ordered = eligible.sorted { lhs, rhs in
            if lhs.id == preferredID { return true }
            if rhs.id == preferredID { return false }
            return lhs.lastSeen > rhs.lastSeen
        }
        var runningIDs = Set(managedWorkers.compactMap { id, worker in
            eligibleIDs.contains(id) && worker.isRunning ? id : nil
        })

        // Selecting an account is an explicit priority request. Reclaim one
        // non-selected slot rather than allowing a third process to start.
        if let preferredID, !runningIDs.contains(preferredID), runningIDs.count >= maxConcurrentWorkers {
            if let evictedID = runningIDs.first(where: { $0 != preferredID }),
               let worker = managedWorkers[evictedID] {
                guard workerReplacementTasks[evictedID] == nil else { return }
                runningIDs.remove(evictedID)
                workerStates[evictedID] = .disconnected
                workerErrors[evictedID] = "等待同步槽位"
                workerReplacementTasks[evictedID] = Task { @MainActor [weak self, weak worker] in
                    await worker?.stopAndWait()
                    guard let self, !self.isStopping else { return }
                    self.workerReplacementTasks[evictedID] = nil
                    self.scheduleManagedWorkers(preferredID: preferredID)
                }
                return
            }
        }

        for profile in ordered {
            guard let worker = managedWorkers[profile.id] else { continue }
            guard workerReplacementTasks[profile.id] == nil else { continue }
            if worker.isRunning {
                runningIDs.insert(profile.id)
                continue
            }
            guard ManagedWorkerAdmissionPolicy.admits(
                isCurrentAccount: profile.id == currentProfileID,
                activeCount: runningIDs.count,
                replacementInFlight: workerReplacementTasks[profile.id] != nil
            ) else {
                workerStates[profile.id] = .disconnected
                workerErrors[profile.id] = "等待同步槽位"
                continue
            }
            workerErrors[profile.id] = nil
            worker.start()
            runningIDs.insert(profile.id)
        }
    }

    private func ensureManagedWorker(for profile: AccountProfile) {
        guard managedWorkers[profile.id] == nil else { return }
        let worker = ManagedAccountWorker(
            profile: profile,
            codexHomeURL: profileStore.codexHomeURL(for: profile),
            quotaRefreshIntervalSeconds: quotaRefreshIntervalSeconds,
            usageRefreshIntervalSeconds: tokenActivityRefreshIntervalSeconds,
            accountRefreshIntervalSeconds: globalSyncIntervalSeconds,
            credentialWatchIntervalSeconds: credentialWatchIntervalSeconds
        )
        let generation = UUID()
        workerGenerations[profile.id] = generation
        bind(worker, generation: generation)
        managedWorkers[profile.id] = worker
        workerStates[profile.id] = .disconnected
    }

    private func bind(_ worker: ManagedAccountWorker, generation: UUID) {
        let id = worker.profile.id
        let profile = worker.profile
        worker.onStateChange = { [weak self] _, state, message in
            guard let self else { return }
            guard self.workerGenerations[id] == generation else { return }
            if self.workerStates[id] != state { self.workerStates[id] = state }
            if let message, !message.isEmpty {
                if self.workerErrors[id] != message { self.workerErrors[id] = message }
            } else if state == .connected, self.workerErrors[id] != nil {
                self.workerErrors[id] = nil
            }
            // A background profile can release a slot just as readily as the
            // selected profile. Re-run the central scheduler before the
            // current-profile projection guard so another queued worker can
            // claim that slot immediately.
            if state == .stopped || state == .offline || state == .error {
                if RapidDrainDetectorBoundaryPolicy.shouldResetForWorkerState(
                    profileID: id,
                    currentProfileID: self.currentProfileID
                ) {
                    self.rapidDrainDetector.reset()
                }
                self.scheduleManagedWorkers(preferredID: self.currentProfileID)
            }
            guard self.currentProfileID == id else { return }
            if self.connectionState != state { self.connectionState = state }
            if let message, !message.isEmpty, self.errorMessage != message { self.errorMessage = message }
            if (state == .offline || state == .error), self.accountHealthState != .offline {
                self.accountHealthState = .offline
            }
        }
        worker.onSnapshot = { [weak self] _, snapshot in
            guard let self else { return }
            guard self.workerGenerations[id] == generation else { return }
            let rapidDrainEvent: ObservedRapidDrainEvent?
            if self.currentProfileID == id {
                rapidDrainEvent = self.observeRapidDrain(snapshot: snapshot, profileID: id)
            } else {
                rapidDrainEvent = nil
            }
            let semanticChange = self.managedSnapshots[id].map { !$0.hasSameContent(as: snapshot) } ?? true
            self.managedSnapshots[id] = snapshot
            if semanticChange {
                let store = HistoryStore(fileURL: self.profileStore.historyURL(for: profile))
                _ = store.record(snapshot: snapshot, connectionState: .connected, now: snapshot.receivedAt)
            }
            if self.currentProfileID == id {
                guard self.applySnapshot(snapshot, to: self) else { return }
                self.evaluateLiveNotifications(
                    snapshot: snapshot,
                    profileID: id,
                    rapidDrainEvent: rapidDrainEvent
                )
            }
        }
        worker.onTokenActivityState = { [weak self] _, state, message in
            guard let self else { return }
            guard self.workerGenerations[id] == generation else { return }
            guard self.currentProfileID == id else { return }
            if self.tokenActivityState != state { self.tokenActivityState = state }
            if self.tokenActivityErrorMessage != message { self.tokenActivityErrorMessage = message }
        }
        worker.onTokenActivity = { [weak self] _, activity in
            guard let self else { return }
            guard self.workerGenerations[id] == generation else { return }
            let store = TokenActivityStore(fileURL: self.profileStore.tokenActivityURL(for: profile))
            self.managedTokenActivityLastFetchedAt[id] = activity.fetchedAt
            self.refreshHUDTokenActivityFetchedAt()
            let merged = store.update(incoming: activity)
            guard store.lastUpdateChanged else {
                if self.currentProfileID == id, self.tokenActivityState != .loaded {
                    self.tokenActivityState = .loaded
                }
                return
            }
            self.managedTokenActivities[id] = merged
            if self.currentProfileID == id {
                self.tokenActivity = merged
                self.tokenActivityState = .loaded
                self.tokenActivityErrorMessage = store.errorMessage
            }
            self.refreshHUDTokenActivitySummary()
        }
        worker.onAccountHealthState = { [weak self] _, state, message in
            guard let self else { return }
            guard self.workerGenerations[id] == generation else { return }
            guard self.currentProfileID == id else { return }
            if self.accountHealthState != state { self.accountHealthState = state }
            if self.accountHealthErrorMessage != message { self.accountHealthErrorMessage = message }
        }
        worker.onAccountHealth = { [weak self] _, health in
            guard let self else { return }
            guard self.workerGenerations[id] == generation else { return }
            let semanticChange = self.managedAccountHealth[id].map { !$0.hasSameContent(as: health) } ?? true
            self.managedAccountHealth[id] = health
            guard semanticChange else {
                if self.currentProfileID == id {
                    if self.accountHealthState != .loaded { self.accountHealthState = .loaded }
                    self.accountHealthErrorMessage = nil
                }
                return
            }
            self.profileStore.updateProfile(id, authMode: health.identity.authMode, accountType: health.identity.accountType)
            self.accountProfiles = self.profileStore.accountProfiles()
            if self.currentProfileID == id {
                self.accountHealth = health
                self.accountHealthState = .loaded
                self.accountHealthErrorMessage = nil
            }
        }
        worker.onAccountBoundary = { [weak self] _ in
            guard let self else { return }
            guard self.workerGenerations[id] == generation else { return }
            // A managed CODEX_HOME can be re-authenticated in place.  Drop
            // every profile-scoped cache at that boundary so switching away
            // and back cannot resurrect the previous identity's payload.
            self.managedSnapshots[id] = nil
            if self.currentProfileID == id { self.rapidDrainDetector.reset() }
            self.managedTokenActivities[id] = nil
            self.managedTokenActivityLastFetchedAt[id] = nil
            self.managedAccountHealth[id] = nil
            guard self.currentProfileID == id else { return }
            self.snapshot = nil
            self.lastUpdated = nil
            self.tokenActivity = nil
            self.tokenActivityLastFetchedAt = nil
            self.refreshHUDTokenActivitySummary()
            self.tokenActivityState = .idle
            self.resetCredits = nil
            self.selectedResetCreditID = nil
            self.activeTurn = .unknownSnapshot()
            self.activeTurnSourceKey = nil
            self.accountHealthState = .loading
        }
        // Managed workers retain App Server transport for quota/account data;
        // their Turn callbacks are not a second visible activity authority.
        worker.onTurnEvent = nil
        worker.onTurnTokenUsage = nil
        worker.onResetCreditResult = { [weak self] _, outcome in
            guard let self, self.currentProfileID == id else { return }
            guard self.workerGenerations[id] == generation else { return }
            self.resetCreditMessage = outcome.displayText
            switch outcome {
            case .reset: self.resetCreditOperationState = .succeeded
            case .alreadyRedeemed: self.resetCreditOperationState = .alreadyRedeemed
            case .nothingToReset: self.resetCreditOperationState = .nothingToReset
            case .noCredit: self.resetCreditOperationState = .noCredit
            case .unknown: self.resetCreditOperationState = .unknown
            case .error: self.resetCreditOperationState = .error
            }
            if outcome.succeeded { self.selectedResetCreditID = nil }
        }
    }

    private func applyManagedCachedData(for id: UUID) {
        if let snapshot = managedSnapshots[id] { applySnapshot(snapshot, to: self) }
        if let activity = managedTokenActivities[id] {
            tokenActivity = activity
            tokenActivityLastFetchedAt = managedTokenActivityLastFetchedAt[id] ?? activity.fetchedAt
            refreshHUDTokenActivitySummary()
            tokenActivityState = .loaded
        }
        if let health = managedAccountHealth[id] {
            accountHealth = health
            accountHealthState = .loaded
        }
        connectionState = workerStates[id] ?? .disconnected
    }

    @discardableResult
    private func applySnapshot(_ snapshot: UsageSnapshot, to _: UsageViewModel) -> Bool {
        guard let profile = currentProfile else { return false }
        let semanticChange = self.snapshot.map { !$0.hasSameContent(as: snapshot) } ?? true
        lastUpdated = snapshot.receivedAt
        currentDate = Date()
        errorMessage = nil
        guard semanticChange else { return false }
        self.snapshot = snapshot
        resetCredits = snapshot.rateLimitResetCredits
        historyStore = HistoryStore(fileURL: profileStore.historyURL(for: profile))
        _ = historyStore.record(snapshot: snapshot, connectionState: .connected, now: snapshot.receivedAt)
        syncHistoryState()
        return true
    }

    func visibleHistorySamples() -> [HistorySample] {
        historyStore.samples(for: historyRange, now: currentDate)
    }

    func profileQuotaSummaries() -> [ProfileQuotaSummary] {
        profileStore.accountProfiles().map { profile in
            let store = HistoryStore(fileURL: profileStore.historyURL(for: profile))
            return ProfileQuotaSummary(profile: profile, latestSample: store.samples.last)
        }
    }

    var accountScopeSummary: AccountScopeSummary {
        let profiles = profileStore.accountProfiles()
        return AccountScopeSummary.make(profiles: profiles, quotaSummaries: profileQuotaSummaries())
    }

    func profileQuotaPoints() -> [ProfileQuotaPoint] {
        profileStore.accountProfiles().flatMap { profile in
            let store = HistoryStore(fileURL: profileStore.historyURL(for: profile))
            return store.samples(for: historyRange, now: currentDate).compactMap { (sample: HistorySample) -> ProfileQuotaPoint? in
                guard sample.connectionState == .connected else { return nil }
                guard let used = sample.primaryUsedPercent else { return nil }
                return ProfileQuotaPoint(profileID: profile.id, profileName: profile.displayName, date: sample.receivedAt, usedPercent: max(0, min(100, used)))
            }
        }
    }

    func visibleAggregateTokenBuckets() -> [DailyTokenUsage] {
        var totals: [String: Int64] = [:]
        for profile in profileStore.accountProfiles() {
            let store = TokenActivityStore(fileURL: profileStore.tokenActivityURL(for: profile))
            for bucket in store.buckets(for: tokenActivityRange, now: currentDate) {
                totals[bucket.startDate, default: 0] += bucket.tokens
            }
        }
        return totals.map { DailyTokenUsage(startDate: $0.key, tokens: $0.value) }.sorted { $0.startDate < $1.startDate }
    }

    var displayedTokenActivity: TokenActivitySnapshot? {
        LocalTokenUsageLedgerPresentation.snapshotForHistory(
            localTokenUsageLedgerStore.snapshot,
            fetchedAt: currentDate
        )
    }

    /// The latest successful fetch is intentionally separate from the
    /// semantic Token Activity payload.  This keeps the stale indicator honest
    /// without making an unchanged 15-minute response redraw the whole page.
    var tokenActivityFetchedAt: Date? {
        accountScope == .all ? hudTokenActivityFetchedAt : (tokenActivityLastFetchedAt ?? tokenActivity?.fetchedAt)
    }

    private func refreshHUDTokenActivitySummary() {
        let summary: TokenActivitySnapshot?
        if accountScope == .current {
            summary = tokenActivity.map(Self.rangeIndependentTokenSummary)
        } else {
            let snapshots = profileStore.accountProfiles().compactMap { profile -> TokenActivitySnapshot? in
                if profile.id == currentProfileID, let tokenActivity { return tokenActivity }
                if let cached = managedTokenActivities[profile.id] { return cached }
                return TokenActivityStore(fileURL: profileStore.tokenActivityURL(for: profile)).snapshot
            }
            let aggregate = TokenActivityPresentation.aggregate(
                snapshots: snapshots,
                dailyBuckets: [],
                fetchedAt: snapshots.map(\.fetchedAt).max() ?? currentDate
            )
            summary = aggregate.map(Self.rangeIndependentTokenSummary)
        }
        let nextMetrics = LocalTokenUsageLedgerPresentation.metrics(
            snapshot: localTokenUsageLedgerStore.snapshot,
            now: currentDate
        )
        hudTokenActivitySummary = summary
        refreshHUDTokenActivityFetchedAt(fallback: summary?.fetchedAt)
        if hudTokenActivityMetrics != nextMetrics {
            hudTokenActivityMetrics = nextMetrics
            // A persisted feedback event is only valid for the daily value
            // that produced it. This clears yesterday's reel at local
            // midnight (and any superseded event before a new one is set),
            // while the production callback below immediately installs a
            // fresh event for the newly observed value.
            let todayTokens = LocalTokenUsageLedgerPresentation.todayObservedTokens(
                snapshot: localTokenUsageLedgerStore.snapshot,
                now: currentDate
            )
            if hudTokenActivityFeedback?.tokens != todayTokens {
                hudTokenActivityFeedback = nil
            }
        }

    }

    private func handleLocalUsageRecord(
        profileID: UUID?,
        record: CodexLocalTokenUsageRecord
    ) {
        // The observer passes the physical source identity unchanged: the
        // default CODEX_HOME uses the stable nil namespace, while managed
        // homes carry their profile attribution. No account lifetime data is
        // consulted here.
        let previousHeroTokens = LocalTokenUsageLedgerPresentation.todayObservedTokens(
            snapshot: localTokenUsageLedgerStore.snapshot,
            now: record.observedAt
        )
        guard let update = localTokenUsageLedgerStore.record(
            profileID: profileID,
            threadID: record.threadID,
            turnID: record.turnID,
            cumulativeTokenTotal: record.cumulativeTokenTotal,
            lastCallTokenTotal: record.lastCallTokenTotal,
            at: record.observedAt
        ) else { return }

        let activityKey = localActivityKey(for: profileID)
        latestLocalObservedDeltas[activityKey] = update.delta
        latestLocalObservedDeltaDates[activityKey] = record.observedAt
        localProfileActivityVersion &+= 1

        refreshHUDTokenActivitySummary()
        hudTokenActivityFeedbackGeneration &+= 1
        let feedback = LocalTokenUsageLedgerPresentation.feedback(
            for: update,
            generation: hudTokenActivityFeedbackGeneration,
            previousHeroTokens: previousHeroTokens,
            heroTokens: LocalTokenUsageLedgerPresentation.todayObservedTokens(
                snapshot: localTokenUsageLedgerStore.snapshot,
                now: record.observedAt
            )
        )
        hudTokenActivityFeedback = feedback
        if tokenActivitySoundGate.consume(feedback: feedback, enabled: tokenReelSoundEnabled) {
            tokenReelAudioPlayer.play(
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )
        }
    }

    private func handleLocalTurnActivity(_ event: CodexLocalTurnActivityEvent) {
        // Only the physical root selected by the current account context may
        // drive the visible Turn card. Other roots still feed their own local
        // ledger, but can never overwrite the current account's activity.
        let selectedProfile = currentProfile
        var managedHomeURL: URL?
        if let selectedProfile, selectedProfile.isManaged {
            managedHomeURL = profileStore.codexHomeURL(for: selectedProfile)
        }
        let defaultHomeURL = CodexLocalUsageObservationRoot.canonicalDefaultHomeURL()
        guard CodexLocalTurnActivityAuthority.acceptsCurrentRoot(
            event: event,
            currentProfileID: currentProfileID,
            currentProfileIsManaged: selectedProfile?.isManaged == true,
            managedHomeURL: managedHomeURL,
            defaultHomeURL: defaultHomeURL
        ) else { return }
        let sourceKey = CodexLocalTurnActivityAuthority.sourceKey(
            profileID: event.profileID,
            physicalRootURL: event.physicalRootURL
        )

        switch event.kind {
        case .started:
            activeTurnSourceKey = sourceKey
            activeTurn = TurnActivitySnapshot(
                state: .active,
                threadID: event.threadID,
                turnID: event.turnID,
                startedAt: event.startedAt ?? event.observedAt,
                completedAt: nil,
                elapsedSeconds: 0,
                tokenTotal: nil,
                content: nil,
                errorMessage: nil,
                receivedAt: event.observedAt,
                programName: event.programName
            )

        case .tokenUpdated:
            guard CodexLocalTurnActivityAuthority.matchesActiveTurn(
                      event: event,
                      activeTurn: activeTurn,
                      activeTurnSourceKey: activeTurnSourceKey,
                      sourceKey: sourceKey
                  ),
                  let tokenTotal = event.turnTokenTotal else { return }
            activeTurn.tokenTotal = tokenTotal
            activeTurn.receivedAt = event.observedAt
            if activeTurn.programName == nil, let programName = event.programName {
                activeTurn.programName = programName
            }

        case .completed, .failed, .interrupted:
            guard CodexLocalTurnActivityAuthority.acceptsTerminal(
                event: event,
                activeTurn: activeTurn,
                activeTurnSourceKey: activeTurnSourceKey,
                sourceKey: sourceKey
            ) else { return }
            let state: TurnActivityState
            let message: String?
            switch event.kind {
            case .completed:
                state = .completed
                message = nil
            case .failed:
                state = .failed
                message = "Codex Turn 發生錯誤"
            case .interrupted:
                state = .interrupted
                message = "Codex Turn 已中斷"
            default:
                return
            }
            activeTurnSourceKey = sourceKey
            activeTurn = TurnActivitySnapshot(
                state: state,
                threadID: event.threadID,
                turnID: event.turnID,
                startedAt: event.startedAt ?? activeTurn.startedAt,
                completedAt: event.completedAt ?? event.observedAt,
                elapsedSeconds: event.durationSeconds ?? activeTurn.elapsedSeconds,
                tokenTotal: activeTurn.tokenTotal,
                content: nil,
                errorMessage: message,
                receivedAt: event.observedAt,
                programName: event.programName ?? activeTurn.programName
            )
            // Rollouts intentionally expose metadata only. Never pass the
            // opt-in content preference into this source's notification path.
            evaluateTurnNotification(activeTurn, contentEnabled: false)
        }
    }

    private func handleLocalTurnCompletion(
        profileID: UUID?,
        record: CodexLocalTurnCompletionRecord
    ) {
        guard localTokenUsageLedgerStore.recordCompletedTurn(
            profileID: profileID,
            threadID: record.threadID,
            turnID: record.turnID,
            durationSeconds: record.durationSeconds,
            at: record.completedAt
        ) else { return }
        refreshHUDTokenActivitySummary()
    }

    private func refreshLocalUsageObserverRoots() {
        guard let localUsageObserver else { return }
        let defaultHome = CodexLocalUsageObservationRoot.canonicalDefaultHomeURL()
        // The physical default CODEX_HOME is a stable machine observation
        // source. It must not change high-water namespace when the selected
        // UsageStatus account changes; managed homes carry their own profile.
        var roots = [CodexLocalUsageObservationRoot(profileID: nil, codexHomeURL: defaultHome)]
        roots.append(contentsOf: profileStore.accountProfiles().map {
            CodexLocalUsageObservationRoot(
                profileID: $0.id,
                codexHomeURL: profileStore.codexHomeURL(for: $0)
            )
        })
        localUsageObserver.setRoots(roots)
    }

    private func refreshHUDTokenActivityFetchedAt(fallback: Date? = nil) {
        if accountScope == .current {
            hudTokenActivityFetchedAt = tokenActivityLastFetchedAt ?? fallback ?? tokenActivity?.fetchedAt
            return
        }
        let fetchedDates = profileStore.accountProfiles().compactMap { profile in
            managedTokenActivityLastFetchedAt[profile.id]
                ?? managedTokenActivities[profile.id]?.fetchedAt
        }
        hudTokenActivityFetchedAt = fetchedDates.max() ?? fallback
    }

    private static func rangeIndependentTokenSummary(_ snapshot: TokenActivitySnapshot) -> TokenActivitySnapshot {
        TokenActivitySnapshot(
            fetchedAt: snapshot.fetchedAt,
            lifetimeTokens: snapshot.lifetimeTokens,
            peakDailyTokens: snapshot.peakDailyTokens,
            longestRunningTurnSec: snapshot.longestRunningTurnSec,
            currentStreakDays: snapshot.currentStreakDays,
            longestStreakDays: snapshot.longestStreakDays,
            dailyUsageBuckets: nil
        )
    }

    var currentProfile: AccountProfile? {
        guard let id = currentProfileID else { return nil }
        return profileStore.profile(for: id)
    }

    var accountDisplayName: String {
        guard let profile = currentProfile else { return "未識別帳號 1" }
        return accountProfileDisplay(for: profile).title
    }

    /// The active account's full email is intentionally exposed only as an
    /// in-memory presentation value for the HUD. It is never part of a
    /// profile, history, UserDefaults value, notification, or log payload.
    var currentAccountEmail: String? {
        let health = accountHealth ?? currentProfileID.flatMap { managedAccountHealth[$0] }
        guard let email = health?.identity.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return nil }
        return email
    }

    /// Returns only safe, presentation-ready account metadata. Raw email is
    /// never exposed outside the in-memory formatter and is never persisted.
    func accountProfileDisplay(for profile: AccountProfile) -> AccountProfileDisplay {
        let health = profile.id == currentProfileID
            ? (accountHealth ?? managedAccountHealth[profile.id])
            : managedAccountHealth[profile.id]
        return AccountProfileDisplay.make(profile: profile, among: accountProfiles, health: health)
    }

    func profileStatusText(_ profile: AccountProfile) -> String {
        let auth = profile.authMode ?? (profile.isUnidentified ? "未識別登入" : "待同步")
        let state = workerStates[profile.id]?.displayName ?? (profile.isManaged ? "尚未啟動" : "目前預設連線")
        let credential = profile.isManaged && !profileStore.hasCredentials(for: profile) ? " · 需要登入" : ""
        return "\(auth) · \(state)\(credential)"
    }

    var menuBarRemainingPercent: Int? {
        snapshot?.primaryRemainingPercent ?? snapshot?.fallbackRemainingPercent
    }

    /// The HUD follows the same effective quota value as the menu bar.  The
    /// primary window remains preferred; a server response that temporarily
    /// omits primary but still contains a valid fallback window must not make
    /// the HUD disappear while the menu bar continues to show a percentage.
    var hudRemainingPercent: Int? {
        menuBarRemainingPercent
    }

    var hudResetTimestamp: Int64? {
        snapshot?.primary?.resetsAt ?? snapshot?.secondary?.resetsAt
    }

    var menuBarTitle: String {
        guard let percent = menuBarRemainingPercent else { return "Codex —" }
        return "Codex \(percent)%"
    }

    /// The status item uses a compact two-line layout, while the one-line
    /// title above remains the canonical text for tooltips and accessibility.
    var menuBarStackedTitle: String {
        guard let percent = menuBarRemainingPercent else { return "Codex\n—" }
        return "Codex\n\(percent)%"
    }

    var menuBarColor: Color {
        switch statusItemColor {
        case .secondary: return .secondary
        case .red: return .red
        case .orange: return .orange
        case .green: return .green
        }
    }

    private var statusItemColor: StatusItemColor {
        guard let percent = menuBarRemainingPercent else { return .secondary }
        if isStale { return .secondary }
        if percent < 20 { return .red }
        if percent < 50 { return .orange }
        return .green
    }

    private func refreshStatusItemPresentation() {
        let source = StatusItemPresentationSource(
            stackedTitle: menuBarStackedTitle,
            tooltip: statusTooltip,
            color: statusItemColor
        )
        let next = StatusItemPresentationPolicy.make(from: source)
        guard next != statusItemPresentation else { return }
        statusItemPresentation = next
    }

    var lastUpdatedText: String {
        guard let lastUpdated else { return "尚未取得資料" }
        return lastUpdated.formatted(date: .abbreviated, time: .shortened)
    }

    var dataAgeText: String {
        guard let lastUpdated else { return "尚未取得資料" }
        let seconds = max(0, Int(currentDate.timeIntervalSince(lastUpdated)))
        if seconds < 60 { return "剛剛更新" }
        if seconds < 3600 { return "最後更新於 \(seconds / 60) 分鐘前" }
        return "最後更新於 \(seconds / 3600) 小時前"
    }

    var isStale: Bool {
        guard connectionState == .connected, let lastUpdated else { return true }
        return currentDate.timeIntervalSince(lastUpdated) > 2 * 60
    }

    var shouldShowOfflineBadge: Bool {
        connectionState == .offline || connectionState == .error || isStale
    }

    var visibleTokenBuckets: [DailyTokenUsage] {
        LocalTokenUsageLedgerPresentation.buckets(
            from: localTokenUsageLedgerStore.snapshot,
            range: tokenActivityRange,
            now: currentDate
        )
    }

    var tokenActivityIsStale: Bool {
        let fetchedAt = tokenActivityFetchedAt
        guard let fetchedAt else { return false }
        return currentDate.timeIntervalSince(fetchedAt) > 15 * 60
    }

    var hudTokenActivityIsStale: Bool {
        false
    }

    var localTokenUsageLastObservedAt: Date? {
        localTokenUsageLedgerStore.snapshot.lastObservedAt
    }

    /// Profile-scoped activity evidence comes only from the existing local
    /// ledger. The default CODEX_HOME namespace (`nil`) is attributed to the
    /// selected unmanaged UI profile for display; managed roots retain their
    /// UUID attribution.
    var localProfileActivityByID: [UUID: LocalTokenProfileObservation] {
        var result: [UUID: LocalTokenProfileObservation] = [:]
        for observation in localTokenUsageLedgerStore.snapshot.profileObservations() {
            if let profileID = observation.profileID {
                result[profileID] = observation
            } else if let currentProfileID,
                      let currentProfile,
                      !currentProfile.isManaged {
                result[currentProfileID] = LocalTokenProfileObservation(
                    profileID: currentProfileID,
                    lastObservedAt: observation.lastObservedAt,
                    observedThreadCount: observation.observedThreadCount
                )
            }
        }
        return result
    }

    func localProfileActivity(for profile: AccountProfile) -> LocalTokenProfileObservation? {
        localProfileActivityByID[profile.id]
    }

    func localObservedTokenDelta(for profile: AccountProfile) -> Int64? {
        guard let activity = localProfileActivity(for: profile) else { return nil }
        let key = localActivityStorageKey(for: profile)
        guard latestLocalObservedDeltaDates[key] == activity.lastObservedAt else { return nil }
        return latestLocalObservedDeltas[key]
    }

    var localActivityScopeText: String {
        accountScope == .current
            ? "目前帳號 · 本機觀測"
            : "全部帳號 · 本機觀測（非同時 Live）"
    }

    var localMachineScopeText: String {
        "這台 Mac · 所有已觀測 Codex 總量"
    }

    var localProfileActivitySummaryText: String {
        let observations = localProfileActivityByID
        guard let latest = observations.values.map(\.lastObservedAt).max() else {
            return "尚無本機帳號活動資料"
        }
        return "已觀測 \(observations.count) 個帳號 · 最新 \(localAgeText(since: latest))"
    }

    private func localActivityKey(for profileID: UUID?) -> String {
        profileID?.uuidString ?? "default"
    }

    private func localActivityStorageKey(for profile: AccountProfile) -> String {
        if localTokenUsageLedgerStore.snapshot.threads.contains(where: { $0.profileID == profile.id }) {
            return localActivityKey(for: profile.id)
        }
        if profile.id == currentProfileID,
           !profile.isManaged,
           localTokenUsageLedgerStore.snapshot.threads.contains(where: { $0.profileID == nil }) {
            return localActivityKey(for: nil)
        }
        return localActivityKey(for: profile.id)
    }

    private func localAgeText(since date: Date) -> String {
        let seconds = max(0, Int(currentDate.timeIntervalSince(date)))
        if seconds < 60 { return "剛剛" }
        if seconds < 3600 { return "\(max(1, seconds / 60)) 分鐘前" }
        if seconds < 86400 { return "\(max(1, seconds / 3600)) 小時前" }
        return "\(max(1, seconds / 86400)) 天前"
    }

    var selectedResetCredit: RateLimitResetCredit? {
        guard let id = selectedResetCreditID else { return nil }
        return resetCredits?.availableCredits.first { $0.id == id }
    }

    var statusTooltip: String {
        let reset = resetDescription(snapshot?.primary?.resetsAt)
        var value = "\(menuBarTitle) · \(reset) · \(connectionState.displayName) · \(dataAgeText)"
        if activeTurn.state != .idle, activeTurn.state != .unknown {
            value += " · Turn：\(activeTurn.state.displayName)"
        }
        return value
    }

    var notificationAuthorizationText: String {
        switch notificationAuthorizationStatus {
        case .authorized, .provisional, .ephemeral: return "已允許"
        case .denied: return "已拒絕"
        case .notDetermined: return "尚未設定"
        @unknown default: return "未知"
        }
    }

    func resetDescription(_ timestamp: Int64?) -> String {
        guard let timestamp else { return "重置時間未知" }
        let seconds = Int(Date(timeIntervalSince1970: TimeInterval(timestamp)).timeIntervalSince(currentDate))
        guard seconds > 0 else {
            return isStale ? "重置時間已到，等待連線確認" : "已重置"
        }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = max(1, (seconds % 3_600) / 60)
        if days > 0 { return "\(days) 天 \(hours) 小時後重置" }
        if hours > 0 { return "\(hours) 小時 \(minutes) 分後重置" }
        return "\(minutes) 分後重置"
    }

    private func startDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentDate = Date()
                // Re-select the existing local-day ledger bucket on the same
                // 60-second display cadence. This makes the Hero roll to zero
                // at local midnight without adding another timer or poll.
                self.refreshHUDTokenActivitySummary()
                if self.activeTurn.state == .active, let started = self.activeTurn.startedAt {
                    self.activeTurn.elapsedSeconds = max(0, Int64(self.currentDate.timeIntervalSince(started)))
                    self.activeTurn.receivedAt = self.currentDate
                }
                self.evaluateTurnNotification(self.activeTurn)
            }
        }
    }

    private func startUpdateCheckTimer() {
        updateCheckTimer?.invalidate()
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForUpdates()
            }
        }
    }

    private func evaluateTurnNotification(_ event: TurnActivitySnapshot, contentEnabled: Bool? = nil) {
        turnNotificationService.evaluate(
            event: event,
            profileID: currentProfileID,
            preferences: TurnNotificationPreferences(
                notifyOnSuccess: notifyOnTurnSuccess,
                notifyOnFailure: notifyOnTurnFailure,
                notifyOnInterrupted: notifyOnTurnInterrupted,
                notifyOnLongRunning: notifyOnLongRunningTurn,
                longRunningThresholdMinutes: longRunningThresholdMinutes,
                showContentInNotifications: contentEnabled ?? (showTurnContentInNotifications && turnContentNotificationSupported),
                soundEnabled: notificationSoundEnabled
            )
        )
    }

    private func handleAccountHealth(_ health: AccountHealthSnapshot) {
        if !pendingUnidentifiedProfileBoundary,
           let existing = accountHealth,
           existing.hasSameContent(as: health),
           currentProfileID != nil {
            if accountHealthState != .loaded { accountHealthState = .loaded }
            if accountHealthErrorMessage != nil { accountHealthErrorMessage = nil }
            return
        }
        let forceNewUnidentified = pendingUnidentifiedProfileBoundary && health.identity.email == nil
        pendingUnidentifiedProfileBoundary = false
        let selection = profileStore.select(identity: health.identity, forceNewUnidentified: forceNewUnidentified)
        profileStore.updateProfile(selection.profile.id, authMode: health.identity.authMode, accountType: health.identity.accountType)
        let needsProfileLoad = currentProfileID != selection.profile.id
        let didSwitch = currentProfileID != nil && needsProfileLoad
        profileStoreErrorMessage = profileStore.errorMessage
        if needsProfileLoad {
            switchToProfile(selection.profile)
            activeTurn = .unknownSnapshot()
            activeTurnSourceKey = nil
            selectedResetCreditID = nil
            resetCreditMessage = "已切換到 \(selection.profile.displayName)"
            resetCreditOperationState = .idle
            if notifyOnAccountSwitch && didSwitch {
                turnNotificationService.notifyAccountSwitch(profileID: selection.profile.id, displayName: selection.profile.displayName, soundEnabled: notificationSoundEnabled)
            }
        }
        currentProfileID = selection.profile.id
        accountProfiles = profileStore.accountProfiles()
        refreshLocalUsageObserverRoots()
        accountHealth = health
        accountHealthState = .loaded
        accountHealthErrorMessage = nil

        // An external account switch can make the legacy/default client report
        // an identity that already has a managed profile. Never keep the
        // default worker publishing into that managed profile: stop it first,
        // then let the profile-scoped worker reload its own CODEX_HOME.
        if selection.profile.isManaged {
            defaultClientEnabled = false
            ensureManagedWorker(for: selection.profile)
            defaultClientStopTask?.cancel()
            let targetID = selection.profile.id
            defaultClientStopTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.client.stopAndWait()
                guard !self.isStopping, self.currentProfileID == targetID else { return }
                self.defaultClientStopTask = nil
                if self.profileStore.hasCredentials(for: selection.profile) {
                    self.scheduleManagedWorkers(preferredID: selection.profile.id)
                    if self.managedWorkers[selection.profile.id]?.isRunning == true {
                        self.managedWorkers[selection.profile.id]?.refresh()
                    }
                }
            }
        } else {
            defaultClientEnabled = true
            let workersToStop = managedWorkers.values.filter(\.isRunning)
            if !workersToStop.isEmpty {
                defaultClientStopTask?.cancel()
                let targetID = selection.profile.id
                defaultClientStopTask = Task { @MainActor [weak self] in
                    for worker in workersToStop { await worker.stopAndWait() }
                    guard let self, !self.isStopping, self.currentProfileID == targetID else { return }
                    self.defaultClientStopTask = nil
                    self.client.refresh()
                }
            } else if needsProfileLoad {
                // Account/read can race the initial quota/activity responses.
                // Re-read after switching so the new profile is never left
                // blank until the next periodic refresh.
                client.refreshRateLimits()
                client.refreshTokenActivity()
            }
        }
    }

    private func switchToProfile(_ profile: AccountProfile) {
        rapidDrainDetector.reset()
        migrateLegacyIfNeeded(to: profile)
        historyStore = HistoryStore(
            fileURL: profileStore.historyURL(for: profile),
            loadOnInit: false,
            asynchronousPersistence: true
        )
        tokenActivityStore = TokenActivityStore(
            fileURL: profileStore.tokenActivityURL(for: profile),
            loadOnInit: false,
            asynchronousPersistence: true
        )
        historySamples = historyStore.samples
        historyErrorMessage = historyStore.errorMessage
        tokenActivity = nil
        tokenActivityLastFetchedAt = nil
        hudTokenActivityFeedback = nil
        refreshHUDTokenActivitySummary()
        tokenActivityState = .idle
        tokenActivityErrorMessage = nil
        accountHealth = nil
        accountHealthState = .loading
        accountHealthErrorMessage = nil
        snapshot = nil
        lastUpdated = nil
        resetCredits = nil
        profileStoreErrorMessage = profileStore.errorMessage ?? profileStoreErrorMessage

        historyStore.loadAsynchronously { [weak self] in
            guard let self, self.currentProfileID == profile.id else { return }
            self.syncHistoryState()
        }
        tokenActivityStore.loadAsynchronously { [weak self] in
            guard let self, self.currentProfileID == profile.id else { return }
            self.tokenActivity = self.tokenActivityStore.snapshot
            self.tokenActivityLastFetchedAt = self.tokenActivityStore.snapshot?.fetchedAt
            self.refreshHUDTokenActivitySummary()
            self.tokenActivityState = self.tokenActivity == nil ? .idle : .loaded
            self.tokenActivityErrorMessage = self.tokenActivityStore.errorMessage
        }
    }

    private func migrateLegacyIfNeeded(to profile: AccountProfile) {
        let destinationHistory = profileStore.historyURL(for: profile)
        let destinationToken = profileStore.tokenActivityURL(for: profile)
        let manager = FileManager.default
        let marker = profileStore.containerURL.appendingPathComponent("legacy-migration-v1.3")
        var migrationError: String?
        if manager.fileExists(atPath: legacyHistoryURL.path), !manager.fileExists(atPath: destinationHistory.path) {
            do {
                try manager.createDirectory(at: destinationHistory.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try manager.copyItem(at: legacyHistoryURL, to: destinationHistory)
                guard HistoryStore(fileURL: destinationHistory).errorMessage == nil else {
                    throw NSError(domain: "CodexUsageStatus.Migration", code: 1, userInfo: [NSLocalizedDescriptionKey: "history.json 驗證失敗"])
                }
                try manager.removeItem(at: legacyHistoryURL)
            } catch {
                migrationError = "舊版 quota 歷史遷移失敗：\(error.localizedDescription)"
            }
        }
        if manager.fileExists(atPath: legacyTokenActivityURL.path), !manager.fileExists(atPath: destinationToken.path) {
            do {
                try manager.createDirectory(at: destinationToken.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try manager.copyItem(at: legacyTokenActivityURL, to: destinationToken)
                guard TokenActivityStore(fileURL: destinationToken).errorMessage == nil else {
                    throw NSError(domain: "CodexUsageStatus.Migration", code: 2, userInfo: [NSLocalizedDescriptionKey: "token-activity.json 驗證失敗"])
                }
                try manager.removeItem(at: legacyTokenActivityURL)
            } catch {
                migrationError = "舊版 Token Activity 遷移失敗：\(error.localizedDescription)"
            }
        }
        if migrationError == nil, !manager.fileExists(atPath: legacyHistoryURL.path), !manager.fileExists(atPath: legacyTokenActivityURL.path) {
            try? Data("1.3".utf8).write(to: marker, options: [.atomic])
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        }
        profileStoreErrorMessage = migrationError ?? profileStore.errorMessage
    }

    private func syncHistoryState() {
        historySamples = historyStore.samples
        historyErrorMessage = historyStore.errorMessage
    }

    private func evaluateCurrentSnapshot() {
        guard notificationsEnabled, let snapshot, connectionState == .connected, !isStale else { return }
        notificationService.evaluate(
            snapshot: snapshot,
            now: Date(),
            thresholds: notificationThresholds,
            separateWindows: separateWindowNotifications,
            soundEnabled: notificationSoundEnabled,
            profileID: currentProfileID
        )
    }

    private func observeRapidDrain(snapshot: UsageSnapshot, profileID: UUID?) -> ObservedRapidDrainEvent? {
        guard let event = rapidDrainDetector.observe(snapshot: snapshot, profileID: profileID, at: snapshot.receivedAt) else {
            return nil
        }
        rapidDrainEvents.send(event)
        return event
    }

    private func evaluateLiveNotifications(
        snapshot: UsageSnapshot,
        profileID: UUID?,
        rapidDrainEvent: ObservedRapidDrainEvent?
    ) {
        guard notificationsEnabled,
              (notificationAuthorizationStatus == .authorized || notificationAuthorizationStatus == .provisional),
              connectionState != .offline,
              connectionState != .error,
              connectionState != .stopped else { return }

        let trustedCodexForeground = NSWorkspace.shared.frontmostApplication.map(CodexApplicationPolicy.isCodexApplication) ?? false
        let decision = RapidDrainPresentationPolicy.decide(
            trustedCodexForeground: trustedCodexForeground,
            notificationsEnabled: notificationsEnabled,
            notificationAuthorized: true
        )

        guard let rapidDrainEvent, decision.sendRapidDrainBanner else {
            notificationService.evaluate(
                snapshot: snapshot,
                now: Date(),
                thresholds: notificationThresholds,
                separateWindows: separateWindowNotifications,
                soundEnabled: notificationSoundEnabled,
                profileID: profileID
            )
            return
        }

        notificationService.notifyRapidDrain(event: rapidDrainEvent, soundEnabled: notificationSoundEnabled) { [weak self] succeeded in
            guard let self else { return }
            self.notificationService.evaluate(
                snapshot: snapshot,
                now: Date(),
                thresholds: self.notificationThresholds,
                separateWindows: self.separateWindowNotifications,
                soundEnabled: self.notificationSoundEnabled,
                profileID: profileID,
                coveredRapidDrainWindow: succeeded
                    ? RapidDrainCoveredWindow(
                        limitID: rapidDrainEvent.limitID,
                        durationMins: 300,
                        resetAt: rapidDrainEvent.resetAt
                    )
                    : nil
            )
        }
    }

    private static func loadThresholds(from defaults: UserDefaults) -> [Int] {
        guard let saved = defaults.array(forKey: PreferenceKey.thresholds) as? [Int], !saved.isEmpty else {
            return [20, 10]
        }
        return saved.map { max(1, min(99, $0)) }.sorted(by: >)
    }

    private static func clampQuotaInterval(_ seconds: Int) -> Int {
        max(30, min(3600, seconds))
    }

    private static func clampAccountInterval(_ seconds: Int) -> Int {
        max(60, min(3600, seconds))
    }

    private static func clampTokenInterval(_ seconds: Int) -> Int {
        max(60, min(7200, seconds))
    }

    private static func clampCredentialWatchInterval(_ seconds: Int) -> Int {
        max(5, min(120, seconds))
    }
}

import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var currentDate = Date()
    @Published private(set) var historySamples: [HistorySample] = []
    @Published private(set) var historyErrorMessage: String?
    @Published private(set) var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var notificationsEnabled: Bool
    @Published private(set) var separateWindowNotifications: Bool
    @Published private(set) var notificationSoundEnabled: Bool
    @Published private(set) var notificationThresholds: [Int]
    @Published private(set) var tokenActivity: TokenActivitySnapshot?
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
    @Published private(set) var loginStates: [UUID: String] = [:]
    @Published private(set) var quotaRefreshIntervalSeconds: Int = 60
    @Published private(set) var globalSyncIntervalSeconds: Int = 300
    @Published private(set) var tokenActivityRefreshIntervalSeconds: Int = 900
    @Published private(set) var credentialWatchIntervalSeconds: Int = 15
    @Published private(set) var activeTurn: TurnActivitySnapshot = .idle
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
    private let profileStore: AccountProfileStore
    private let legacyHistoryURL: URL
    private let legacyTokenActivityURL: URL
    private let notificationService = UsageNotificationService()
    private let turnNotificationService = TurnNotificationService()
    private let updateService = AppUpdateService()
    private let updateNotificationService = AppUpdateNotificationService()
    private let defaults = UserDefaults.standard
    private var displayTimer: Timer?
    private var updateCheckTimer: Timer?
    private var pendingUnidentifiedProfileBoundary = false
    private var defaultClientEnabled = true
    private let maxConcurrentWorkers = 2

    private enum PreferenceKey {
        static let notificationsEnabled = "usage.notifications.enabled"
        static let separateWindows = "usage.notifications.separateWindows"
        static let soundEnabled = "usage.notifications.soundEnabled"
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
        let store = HistoryStore()
        historyStore = store
        legacyHistoryURL = store.fileURL
        historySamples = store.samples
        historyErrorMessage = store.errorMessage
        let activityStore = TokenActivityStore()
        tokenActivityStore = activityStore
        legacyTokenActivityURL = activityStore.fileURL
        tokenActivity = activityStore.snapshot
        tokenActivityState = activityStore.snapshot == nil ? .idle : .loaded
        tokenActivityErrorMessage = activityStore.errorMessage
        notificationsEnabled = defaults.object(forKey: PreferenceKey.notificationsEnabled) as? Bool ?? true
        separateWindowNotifications = defaults.object(forKey: PreferenceKey.separateWindows) as? Bool ?? true
        notificationSoundEnabled = defaults.object(forKey: PreferenceKey.soundEnabled) as? Bool ?? false
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
        profileStore = AccountProfileStore()
        accountProfiles = profileStore.accountProfiles()
        profileStoreErrorMessage = profileStore.errorMessage
        quotaRefreshIntervalSeconds = Self.clampQuotaInterval(defaults.object(forKey: PreferenceKey.quotaRefreshInterval) as? Int ?? 60)
        globalSyncIntervalSeconds = Self.clampAccountInterval(defaults.object(forKey: PreferenceKey.accountRefreshInterval) as? Int ?? 300)
        tokenActivityRefreshIntervalSeconds = Self.clampTokenInterval(defaults.object(forKey: PreferenceKey.tokenActivityRefreshInterval) as? Int ?? 900)
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
        if let savedID = defaults.string(forKey: PreferenceKey.activeProfile),
           let id = UUID(uuidString: savedID),
           let profile = profileStore.profile(for: id) {
            currentProfileID = id
            switchToProfile(profile)
            defaultClientEnabled = !profile.isManaged
        }

        client.onStateChange = { [weak self] state, message in
            guard let self else { return }
            guard self.defaultClientEnabled else { return }
            self.connectionState = state
            if state == .offline { self.accountHealthState = .offline }
            if let message, !message.isEmpty {
                self.errorMessage = message
            } else if state == .connected {
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
            self.snapshot = snapshot
            self.lastUpdated = snapshot.receivedAt
            self.currentDate = Date()
            self.errorMessage = nil
            self.resetCredits = snapshot.rateLimitResetCredits
            if let selected = self.selectedResetCreditID,
               !(snapshot.rateLimitResetCredits?.availableCredits.contains(where: { $0.id == selected }) ?? false) {
                self.selectedResetCreditID = nil
            }
            // A valid snapshot callback is live even though the client publishes
            // .connected immediately after invoking this callback.
            self.historyStore.record(snapshot: snapshot, connectionState: .connected, now: snapshot.receivedAt)
            self.syncHistoryState()
            guard self.notificationsEnabled,
                  (self.notificationAuthorizationStatus == .authorized || self.notificationAuthorizationStatus == .provisional),
                  self.connectionState != .offline,
                  self.connectionState != .error,
                  self.connectionState != .stopped else { return }
            self.notificationService.evaluate(
                snapshot: snapshot,
                now: Date(),
                thresholds: self.notificationThresholds,
                separateWindows: self.separateWindowNotifications,
                soundEnabled: self.notificationSoundEnabled,
                profileID: self.currentProfileID
            )
        }
        client.onTokenActivityState = { [weak self] state, message in
            guard let self else { return }
            guard self.defaultClientEnabled else { return }
            self.tokenActivityState = state
            self.tokenActivityErrorMessage = message
        }
        client.onTokenActivity = { [weak self] activity in
            guard let self else { return }
            guard self.defaultClientEnabled else { return }
            self.tokenActivity = self.tokenActivityStore.update(incoming: activity)
            self.tokenActivityState = .loaded
            self.tokenActivityErrorMessage = self.tokenActivityStore.errorMessage
        }
        client.onAccountHealthState = { [weak self] state, message in
            guard let self else { return }
            guard self.defaultClientEnabled else { return }
            self.accountHealthState = state
            self.accountHealthErrorMessage = message
        }
        client.onAccountHealth = { [weak self] health in
            guard let self else { return }
            guard self.defaultClientEnabled else { return }
            self.handleAccountHealth(health)
        }
        client.onAccountBoundary = { [weak self] in
            guard let self else { return }
            guard self.defaultClientEnabled else { return }
            self.pendingUnidentifiedProfileBoundary = true
            self.snapshot = nil
            self.lastUpdated = nil
            self.resetCredits = nil
            self.selectedResetCreditID = nil
            self.resetCreditOperationState = .idle
            self.activeTurn = .unknownSnapshot()
            self.accountHealthState = .loading
        }
        client.onTurnEvent = { [weak self] event in
            guard let self else { return }
            guard self.defaultClientEnabled else { return }
            self.activeTurn = event
            self.evaluateTurnNotification(event)
        }
        client.onTurnTokenUsage = { [weak self] threadID, turnID, tokenTotal in
            guard let self, self.activeTurn.threadID == threadID, self.activeTurn.turnID == turnID else { return }
            guard self.defaultClientEnabled else { return }
            self.activeTurn.tokenTotal = tokenTotal
            self.activeTurn.receivedAt = Date()
        }
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
    }

    deinit {
        displayTimer?.invalidate()
        updateCheckTimer?.invalidate()
    }

    func start() {
        defaultClientEnabled = true
        loginItemManager.refresh()
        loginItemManager.registerIfNeeded()
        historyStore.load()
        syncHistoryState()
        tokenActivityStore.load()
        tokenActivity = tokenActivityStore.snapshot
        tokenActivityErrorMessage = tokenActivityStore.errorMessage
        startDisplayTimer()
        checkForUpdates()
        startUpdateCheckTimer()
        if let profile = currentProfile, profile.isManaged {
            defaultClientEnabled = false
            ensureManagedWorker(for: profile)
            if profileStore.hasCredentials(for: profile) {
                managedWorkers[profile.id]?.start()
            }
        } else {
            client.start()
        }
        startManagedWorkers()
    }

    func stop() {
        defaultClientEnabled = false
        displayTimer?.invalidate()
        displayTimer = nil
        updateCheckTimer?.invalidate()
        updateCheckTimer = nil
        client.stop()
        for worker in managedWorkers.values { worker.stop() }
        managedWorkers.removeAll()
    }

    func refresh() {
        currentDate = Date()
        activeClient.refresh()
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

    func cancelUpdateCheck() {
        guard updateState == .checking || updateService.state == .checking else { return }

        // Publish the terminal state synchronously.  The service callback is
        // also wired below for callers that observe the service directly;
        // assigning here prevents a non-responding URLSession cancellation
        // from leaving the UI's local state stuck on `.checking`.
        updateService.cancelCheck { [weak self] state in
            self?.updateState = state
        }
        updateState = updateService.state
    }

    func downloadAvailableUpdate() {
        updateService.download { [weak self] state in
            self?.updateState = state
        }
    }

    func cancelUpdateDownload() {
        updateService.cancelDownload()
        updateState = updateService.state
    }

    func revealDownloadedUpdate() {
        updateService.revealDownloadedApp()
    }

    func installDownloadedUpdate() {
        updateService.installDownloadedUpdate()
        updateState = updateService.state
    }

    func openUpdateReleasePage() {
        updateService.openReleasePage()
    }

    func setAccountScope(_ scope: AccountScope) {
        accountScope = scope
        currentDate = Date()
    }

    func selectProfile(id: UUID) {
        guard let profile = profileStore.profile(for: id), currentProfileID != id else { return }
        switchToProfile(profile)
        currentProfileID = id
        defaults.set(id.uuidString, forKey: PreferenceKey.activeProfile)
        accountProfiles = profileStore.accountProfiles()
        activeTurn = .unknownSnapshot()
        selectedResetCreditID = nil
        resetCreditOperationState = .idle
        resetCreditMessage = "已切換到 \(profile.displayName)"
        defaultClientEnabled = !profile.isManaged
        if profile.isManaged { client.stop() }
        if profile.isManaged { ensureManagedWorker(for: profile) }
        if let worker = managedWorkers[id] {
            applyManagedCachedData(for: id)
            if profileStore.hasCredentials(for: profile) {
                worker.start()
                worker.refresh()
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
        activeTurn = .unknownSnapshot()
        selectedResetCreditID = nil
        resetCreditOperationState = .idle
        resetCreditMessage = "已建立 \(profile.displayName)"
        if profileStore.hasCredentials(for: profile) {
            managedWorkers[profile.id]?.start()
            managedWorkers[profile.id]?.refresh()
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
                self.managedWorkers[profileID]?.start()
                self.managedWorkers[profileID]?.refresh()
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
            managedWorkers[profile.id]?.start()
            managedWorkers[profile.id]?.refresh()
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
        restartManagedWorkersForScheduleChange()
    }

    func setQuotaRefreshInterval(_ seconds: Int) {
        quotaRefreshIntervalSeconds = Self.clampQuotaInterval(seconds)
        defaults.set(quotaRefreshIntervalSeconds, forKey: PreferenceKey.quotaRefreshInterval)
        client.updateIntervals(quota: quotaRefreshIntervalSeconds)
        restartManagedWorkersForScheduleChange()
    }

    func setTokenActivityRefreshInterval(_ seconds: Int) {
        tokenActivityRefreshIntervalSeconds = Self.clampTokenInterval(seconds)
        defaults.set(tokenActivityRefreshIntervalSeconds, forKey: PreferenceKey.tokenActivityRefreshInterval)
        client.updateIntervals(usage: tokenActivityRefreshIntervalSeconds)
        restartManagedWorkersForScheduleChange()
    }

    func setCredentialWatchInterval(_ seconds: Int) {
        credentialWatchIntervalSeconds = Self.clampCredentialWatchInterval(seconds)
        defaults.set(credentialWatchIntervalSeconds, forKey: PreferenceKey.credentialWatchInterval)
        client.updateIntervals(credentialWatch: credentialWatchIntervalSeconds)
        restartManagedWorkersForScheduleChange()
    }

    func removeProfile(id: UUID) {
        managedWorkers[id]?.stop()
        managedWorkers[id] = nil
        workerGenerations[id] = nil
        managedSnapshots[id] = nil
        managedTokenActivities[id] = nil
        managedAccountHealth[id] = nil
        guard profileStore.deleteProfile(id: id) else { return }
        accountProfiles = profileStore.accountProfiles()
        if currentProfileID == id {
            currentProfileID = nil
            defaults.removeObject(forKey: PreferenceKey.activeProfile)
            if let next = accountProfiles.first {
                selectProfile(id: next.id)
            } else {
                snapshot = nil
                tokenActivity = nil
                accountHealth = nil
            }
        }
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
        let candidates = profileStore.accountProfiles().filter { $0.isManaged && $0.workerEnabled && profileStore.hasCredentials(for: $0) }
        for profile in candidates.prefix(maxConcurrentWorkers) {
            ensureManagedWorker(for: profile)
            managedWorkers[profile.id]?.start()
        }
        for profile in candidates.dropFirst(maxConcurrentWorkers) {
            workerStates[profile.id] = .disconnected
            workerErrors[profile.id] = "等待同步槽位"
        }
    }

    private func restartManagedWorkersForScheduleChange() {
        for profile in profileStore.accountProfiles() where profile.isManaged {
            managedWorkers[profile.id]?.stop()
            workerGenerations[profile.id] = nil
            managedWorkers[profile.id] = nil
            let refreshedProfile = profileStore.profile(for: profile.id) ?? profile
            ensureManagedWorker(for: refreshedProfile)
            if refreshedProfile.workerEnabled, profileStore.hasCredentials(for: refreshedProfile) {
                managedWorkers[profile.id]?.start()
            }
        }
    }

    private func ensureManagedWorker(for profile: AccountProfile) {
        guard managedWorkers[profile.id] == nil else { return }
        let worker = ManagedAccountWorker(
            profile: profile,
            codexHomeURL: profileStore.codexHomeURL(for: profile),
            quotaRefreshIntervalSeconds: quotaRefreshIntervalSeconds,
            usageRefreshIntervalSeconds: tokenActivityRefreshIntervalSeconds,
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
            self.workerStates[id] = state
            if let message, !message.isEmpty { self.workerErrors[id] = message }
            else if state == .connected { self.workerErrors[id] = nil }
            guard self.currentProfileID == id else { return }
            self.connectionState = state
            if let message, !message.isEmpty { self.errorMessage = message }
            if state == .offline || state == .error { self.accountHealthState = .offline }
        }
        worker.onSnapshot = { [weak self] _, snapshot in
            guard let self else { return }
            guard self.workerGenerations[id] == generation else { return }
            self.managedSnapshots[id] = snapshot
            let store = HistoryStore(fileURL: self.profileStore.historyURL(for: profile))
            _ = store.record(snapshot: snapshot, connectionState: .connected, now: snapshot.receivedAt)
            if self.currentProfileID == id {
                self.applySnapshot(snapshot, to: self)
                guard self.notificationsEnabled,
                      self.notificationAuthorizationStatus == .authorized || self.notificationAuthorizationStatus == .provisional,
                      self.connectionState != .offline,
                      self.connectionState != .error,
                      self.connectionState != .stopped else { return }
                self.notificationService.evaluate(
                    snapshot: snapshot,
                    now: Date(),
                    thresholds: self.notificationThresholds,
                    separateWindows: self.separateWindowNotifications,
                    soundEnabled: self.notificationSoundEnabled,
                    profileID: id
                )
            }
        }
        worker.onTokenActivityState = { [weak self] _, state, message in
            guard let self else { return }
            guard self.workerGenerations[id] == generation else { return }
            guard self.currentProfileID == id else { return }
            self.tokenActivityState = state
            self.tokenActivityErrorMessage = message
        }
        worker.onTokenActivity = { [weak self] _, activity in
            guard let self else { return }
            guard self.workerGenerations[id] == generation else { return }
            self.managedTokenActivities[id] = activity
            let store = TokenActivityStore(fileURL: self.profileStore.tokenActivityURL(for: profile))
            _ = store.update(incoming: activity)
            if self.currentProfileID == id {
                self.tokenActivity = activity
                self.tokenActivityState = .loaded
                self.tokenActivityErrorMessage = store.errorMessage
            }
        }
        worker.onAccountHealthState = { [weak self] _, state, message in
            guard let self else { return }
            guard self.workerGenerations[id] == generation else { return }
            guard self.currentProfileID == id else { return }
            self.accountHealthState = state
            self.accountHealthErrorMessage = message
        }
        worker.onAccountHealth = { [weak self] _, health in
            guard let self else { return }
            guard self.workerGenerations[id] == generation else { return }
            self.managedAccountHealth[id] = health
            self.profileStore.updateProfile(id, authMode: health.identity.authMode, accountType: health.identity.accountType)
            self.accountProfiles = self.profileStore.accountProfiles()
            if self.currentProfileID == id {
                self.accountHealth = health
                self.accountHealthState = .loaded
                self.accountHealthErrorMessage = nil
            }
        }
        worker.onAccountBoundary = { [weak self] _ in
            guard let self, self.currentProfileID == id else { return }
            guard self.workerGenerations[id] == generation else { return }
            self.snapshot = nil
            self.lastUpdated = nil
            self.resetCredits = nil
            self.selectedResetCreditID = nil
            self.activeTurn = .unknownSnapshot()
            self.accountHealthState = .loading
        }
        worker.onTurnEvent = { [weak self] _, event in
            guard let self, self.currentProfileID == id else { return }
            guard self.workerGenerations[id] == generation else { return }
            self.activeTurn = event
            self.evaluateTurnNotification(event)
        }
        worker.onTurnTokenUsage = { [weak self] _, threadID, turnID, total in
            guard let self, self.currentProfileID == id,
                  self.activeTurn.threadID == threadID, self.activeTurn.turnID == turnID else { return }
            guard self.workerGenerations[id] == generation else { return }
            self.activeTurn.tokenTotal = total
            self.activeTurn.receivedAt = Date()
        }
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
            tokenActivityState = .loaded
        }
        if let health = managedAccountHealth[id] {
            accountHealth = health
            accountHealthState = .loaded
        }
        connectionState = workerStates[id] ?? .disconnected
    }

    private func applySnapshot(_ snapshot: UsageSnapshot, to _: UsageViewModel) {
        guard let profile = currentProfile else { return }
        self.snapshot = snapshot
        lastUpdated = snapshot.receivedAt
        currentDate = Date()
        errorMessage = nil
        resetCredits = snapshot.rateLimitResetCredits
        historyStore = HistoryStore(fileURL: profileStore.historyURL(for: profile))
        _ = historyStore.record(snapshot: snapshot, connectionState: .connected, now: snapshot.receivedAt)
        syncHistoryState()
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
        guard accountScope == .all else { return tokenActivity }
        let buckets = visibleAggregateTokenBuckets()
        let profiles = profileStore.accountProfiles()
        let stores = profiles.map { TokenActivityStore(fileURL: profileStore.tokenActivityURL(for: $0)) }
        let snapshots = stores.compactMap(\.snapshot)
        guard !snapshots.isEmpty else { return nil }
        return TokenActivitySnapshot(
            fetchedAt: snapshots.map(\.fetchedAt).max() ?? currentDate,
            lifetimeTokens: snapshots.compactMap(\.lifetimeTokens).reduce(0, +),
            peakDailyTokens: buckets.map(\.tokens).max(),
            longestRunningTurnSec: snapshots.compactMap(\.longestRunningTurnSec).max(),
            currentStreakDays: snapshots.compactMap(\.currentStreakDays).max(),
            longestStreakDays: snapshots.compactMap(\.longestStreakDays).max(),
            dailyUsageBuckets: buckets
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
        guard let percent = menuBarRemainingPercent else { return .secondary }
        if isStale { return .secondary }
        if percent < 20 { return .red }
        if percent < 50 { return .orange }
        return .green
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
        accountScope == .all ? visibleAggregateTokenBuckets() : tokenActivityStore.buckets(for: tokenActivityRange, now: currentDate)
    }

    var tokenActivityIsStale: Bool {
        guard let tokenActivity else { return false }
        return currentDate.timeIntervalSince(tokenActivity.fetchedAt) > 15 * 60
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

    private func evaluateTurnNotification(_ event: TurnActivitySnapshot) {
        turnNotificationService.evaluate(
            event: event,
            profileID: currentProfileID,
            preferences: TurnNotificationPreferences(
                notifyOnSuccess: notifyOnTurnSuccess,
                notifyOnFailure: notifyOnTurnFailure,
                notifyOnInterrupted: notifyOnTurnInterrupted,
                notifyOnLongRunning: notifyOnLongRunningTurn,
                longRunningThresholdMinutes: longRunningThresholdMinutes,
                showContentInNotifications: showTurnContentInNotifications,
                soundEnabled: notificationSoundEnabled
            )
        )
    }

    private func handleAccountHealth(_ health: AccountHealthSnapshot) {
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
            selectedResetCreditID = nil
            resetCreditMessage = "已切換到 \(selection.profile.displayName)"
            resetCreditOperationState = .idle
            if notifyOnAccountSwitch && didSwitch {
                turnNotificationService.notifyAccountSwitch(profileID: selection.profile.id, displayName: selection.profile.displayName, soundEnabled: notificationSoundEnabled)
            }
        }
        currentProfileID = selection.profile.id
        accountProfiles = profileStore.accountProfiles()
        accountHealth = health
        accountHealthState = .loaded
        accountHealthErrorMessage = nil

        // An external account switch can make the legacy/default client report
        // an identity that already has a managed profile. Never keep the
        // default worker publishing into that managed profile: stop it first,
        // then let the profile-scoped worker reload its own CODEX_HOME.
        if selection.profile.isManaged {
            defaultClientEnabled = false
            client.stop()
            ensureManagedWorker(for: selection.profile)
            if profileStore.hasCredentials(for: selection.profile) {
                managedWorkers[selection.profile.id]?.start()
                managedWorkers[selection.profile.id]?.refresh()
            }
        } else {
            defaultClientEnabled = true
            // Account/read can race the initial quota/activity responses. Re-read
            // after switching so the new profile is never left blank until the
            // next periodic refresh.
            if needsProfileLoad {
                client.refreshRateLimits()
                client.refreshTokenActivity()
            }
        }
    }

    private func switchToProfile(_ profile: AccountProfile) {
        migrateLegacyIfNeeded(to: profile)
        historyStore = HistoryStore(fileURL: profileStore.historyURL(for: profile))
        tokenActivityStore = TokenActivityStore(fileURL: profileStore.tokenActivityURL(for: profile))
        historySamples = historyStore.samples
        historyErrorMessage = historyStore.errorMessage
        tokenActivity = tokenActivityStore.snapshot
        tokenActivityState = tokenActivity == nil ? .idle : .loaded
        tokenActivityErrorMessage = tokenActivityStore.errorMessage
        snapshot = nil
        lastUpdated = nil
        resetCredits = nil
        profileStoreErrorMessage = profileStore.errorMessage ?? profileStoreErrorMessage
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

import Foundation

@MainActor
final class ManagedAccountWorker: Identifiable {
    let profile: AccountProfile
    let codexHomeURL: URL
    let client: CodexAppServerClient

    var onStateChange: ((UUID, ConnectionState, String?) -> Void)?
    var onSnapshot: ((UUID, UsageSnapshot) -> Void)?
    var onTokenActivity: ((UUID, TokenActivitySnapshot) -> Void)?
    var onTokenActivityState: ((UUID, TokenActivityState, String?) -> Void)?
    var onResetCreditResult: ((UUID, ResetCreditOutcome) -> Void)?
    var onAccountHealth: ((UUID, AccountHealthSnapshot) -> Void)?
    var onAccountHealthState: ((UUID, AccountHealthState, String?) -> Void)?
    var onAccountBoundary: ((UUID) -> Void)?
    var onTurnEvent: ((UUID, TurnActivitySnapshot) -> Void)?
    var onTurnTokenUsage: ((UUID, String, String, Int64?) -> Void)?

    init(
        profile: AccountProfile,
        codexHomeURL: URL,
        quotaRefreshIntervalSeconds: Int = 60,
        usageRefreshIntervalSeconds: Int = 15 * 60,
        credentialWatchIntervalSeconds: Int = 15
    ) {
        self.profile = profile
        self.codexHomeURL = codexHomeURL
        self.client = CodexAppServerClient(
            codexHomeURL: codexHomeURL,
            quotaRefreshIntervalSeconds: quotaRefreshIntervalSeconds,
            usageRefreshIntervalSeconds: usageRefreshIntervalSeconds,
            accountRefreshIntervalSeconds: profile.syncIntervalSeconds,
            credentialWatchIntervalSeconds: credentialWatchIntervalSeconds
        )
        let id = profile.id

        client.onStateChange = { [weak self] state, message in self?.onStateChange?(id, state, message) }
        client.onSnapshot = { [weak self] snapshot in self?.onSnapshot?(id, snapshot) }
        client.onTokenActivity = { [weak self] activity in self?.onTokenActivity?(id, activity) }
        client.onTokenActivityState = { [weak self] state, message in self?.onTokenActivityState?(id, state, message) }
        client.onResetCreditResult = { [weak self] outcome in self?.onResetCreditResult?(id, outcome) }
        client.onAccountHealth = { [weak self] health in self?.onAccountHealth?(id, health) }
        client.onAccountHealthState = { [weak self] state, message in self?.onAccountHealthState?(id, state, message) }
        client.onAccountBoundary = { [weak self] in self?.onAccountBoundary?(id) }
        client.onTurnEvent = { [weak self] event in self?.onTurnEvent?(id, event) }
        client.onTurnTokenUsage = { [weak self] threadID, turnID, total in self?.onTurnTokenUsage?(id, threadID, turnID, total) }
    }

    var isRunning: Bool { client.isRunning }

    func start() { client.start() }
    func stop() { client.stop() }
    func refresh() { client.refresh() }
    func refreshRateLimits() { client.refreshRateLimits() }
    func refreshTokenActivity() { client.refreshTokenActivity() }
    func refreshAccount() { client.refreshAccount() }
    func updateIntervals(
        quota: Int? = nil,
        usage: Int? = nil,
        account: Int? = nil,
        credentialWatch: Int? = nil
    ) {
        client.updateIntervals(
            quota: quota,
            usage: usage,
            account: account,
            credentialWatch: credentialWatch
        )
    }
    func consumeResetCredit(creditID: String) { client.consumeResetCredit(creditID: creditID) }
}

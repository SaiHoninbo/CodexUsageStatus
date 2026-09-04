import Foundation
import OSLog

enum AppServerRetryPolicy {
    static let initializationWatchdogNanoseconds: UInt64 = 8_000_000_000
    static let automaticRetryDelaysNanoseconds: [UInt64] = [
        1_000_000_000, 2_000_000_000, 4_000_000_000
    ]

    static func delay(for attempt: Int) -> UInt64? {
        guard automaticRetryDelaysNanoseconds.indices.contains(attempt) else { return nil }
        return automaticRetryDelaysNanoseconds[attempt]
    }
}

enum RefreshRequestCoalescer {
    static func shouldSchedule(isScheduled: Bool) -> Bool { !isScheduled }
}

enum AppServerReplacementAdmissionPolicy {
    static func canStartReplacement(oldProcessRunning: Bool, replacementInFlight: Bool) -> Bool {
        !oldProcessRunning && !replacementInFlight
    }
}

enum ManagedWorkerAdmissionPolicy {
    static let maxActiveAppServers = 1

    static func admits(isCurrentAccount: Bool, activeCount: Int, replacementInFlight: Bool) -> Bool {
        isCurrentAccount && !replacementInFlight && activeCount < maxActiveAppServers
    }
}

@MainActor
final class CodexAppServerClient {
    var onStateChange: ((ConnectionState, String?) -> Void)?
    var onSnapshot: ((UsageSnapshot) -> Void)?
    var onTokenActivity: ((TokenActivitySnapshot) -> Void)?
    var onTokenActivityState: ((TokenActivityState, String?) -> Void)?
    var onResetCreditResult: ((ResetCreditOutcome) -> Void)?
    var onAccountHealth: ((AccountHealthSnapshot) -> Void)?
    var onAccountHealthState: ((AccountHealthState, String?) -> Void)?
    var onAccountBoundary: (() -> Void)?
    var onTurnEvent: ((TurnActivitySnapshot) -> Void)?
    var onTurnTokenUsage: ((String, String, Int64?) -> Void)?

    private enum PendingRequest {
        case initialize
        case rateLimitsRead
        case usageRead
        case resetCreditConsume
        case accountRead
    }

    private let fileManager = FileManager.default
    private let codexHomeURL: URL?
    private var quotaRefreshIntervalSeconds: UInt64
    private var usageRefreshIntervalSeconds: UInt64
    private var accountRefreshIntervalSeconds: UInt64
    private var credentialWatchIntervalSeconds: UInt64
    private let logger = Logger(subsystem: "com.openai.codex-usage-status", category: "app-server")
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var lineBuffer = JSONLineBuffer()
    private var nextRequestID = 1
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var reconnectTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var usageRefreshTask: Task<Void, Never>?
    private var accountRefreshTask: Task<Void, Never>?
    private var credentialWatchTask: Task<Void, Never>?
    private var resetTimeoutTask: Task<Void, Never>?
    private var initializeWatchdogTask: Task<Void, Never>?
    private var refreshRequestTask: Task<Void, Never>?
    private var processReplacementTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var automaticRetryExhausted = false
    private var isStopping = false
    /// App Server requests are admitted only after the initialize handshake
    /// completes.  A running process alone is not sufficient: sending reads
    /// while initialize is pending can race account-boundary state and leave
    /// duplicate or stale responses in the UI.
    private var hasCompletedInitialization = false
    private var latestSnapshot: UsageSnapshot?
    private var latestAuthMode: String?
    private var latestAccountIdentityKey: String?
    private var processGeneration = UUID()
    private var observedCredentialSignature: String?
    private var lastCredentialRestartAt: Date?

    var isRunning: Bool { process?.isRunning == true }

    init(
        codexHomeURL: URL? = nil,
        quotaRefreshIntervalSeconds: Int = 60,
        usageRefreshIntervalSeconds: Int = 15 * 60,
        accountRefreshIntervalSeconds: Int = 5 * 60,
        credentialWatchIntervalSeconds: Int = 15
    ) {
        self.codexHomeURL = codexHomeURL
        self.quotaRefreshIntervalSeconds = UInt64(max(30, quotaRefreshIntervalSeconds))
        self.usageRefreshIntervalSeconds = UInt64(max(60, usageRefreshIntervalSeconds))
        self.accountRefreshIntervalSeconds = UInt64(max(60, accountRefreshIntervalSeconds))
        self.credentialWatchIntervalSeconds = UInt64(max(5, credentialWatchIntervalSeconds))
    }

    deinit {
        refreshTask?.cancel()
        usageRefreshTask?.cancel()
        accountRefreshTask?.cancel()
        credentialWatchTask?.cancel()
        resetTimeoutTask?.cancel()
        initializeWatchdogTask?.cancel()
        refreshRequestTask?.cancel()
        processReplacementTask?.cancel()
        reconnectTask?.cancel()
    }

    func start() {
        isStopping = false
        reconnectAttempt = 0
        automaticRetryExhausted = false
        observedCredentialSignature = credentialSignature()
        connect()
        resetTimeoutTask?.cancel()
        resetTimeoutTask = nil
        initializeWatchdogTask?.cancel()
        initializeWatchdogTask = nil
        refreshRequestTask?.cancel()
        refreshRequestTask = nil
        processReplacementTask?.cancel()
        processReplacementTask = nil
        startRefreshTasks()
    }

    /// Updates the polling schedule without replacing the App Server process.
    /// The next polling cycle uses the new values immediately. A running task
    /// is restarted so a previously selected long interval does not delay the
    /// first refresh after the user changes a setting.
    func updateIntervals(
        quota: Int? = nil,
        usage: Int? = nil,
        account: Int? = nil,
        credentialWatch: Int? = nil
    ) {
        if let quota { quotaRefreshIntervalSeconds = UInt64(max(30, min(3600, quota))) }
        if let usage { usageRefreshIntervalSeconds = UInt64(max(60, min(7200, usage))) }
        if let account { accountRefreshIntervalSeconds = UInt64(max(60, min(3600, account))) }
        if let credentialWatch { credentialWatchIntervalSeconds = UInt64(max(5, min(120, credentialWatch))) }
        guard !isStopping, process != nil else { return }
        startRefreshTasks()
    }

    private func startRefreshTasks() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: (self?.quotaRefreshIntervalSeconds ?? 60) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.refreshRateLimits()
            }
        }
        usageRefreshTask?.cancel()
        accountRefreshTask?.cancel()
        usageRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: (self?.usageRefreshIntervalSeconds ?? 15 * 60) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.refreshTokenActivity()
            }
        }
        accountRefreshTask?.cancel()
        accountRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: (self?.accountRefreshIntervalSeconds ?? 5 * 60) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.refreshAccount()
            }
        }
        credentialWatchTask?.cancel()
        credentialWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: (self?.credentialWatchIntervalSeconds ?? 15) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.checkCredentialChange()
            }
        }
    }

    func stop() {
        stopImmediately()
    }

    /// Stops the App Server and waits for the child process to exit off the
    /// main actor. Account switching uses this admission path so a replacement
    /// can never overlap the old process, even while SIGTERM is being handled.
    func stopAndWait() async {
        isStopping = true
        refreshTask?.cancel()
        refreshTask = nil
        usageRefreshTask?.cancel()
        usageRefreshTask = nil
        accountRefreshTask?.cancel()
        accountRefreshTask = nil
        credentialWatchTask?.cancel()
        credentialWatchTask = nil
        resetTimeoutTask?.cancel()
        resetTimeoutTask = nil
        initializeWatchdogTask?.cancel()
        initializeWatchdogTask = nil
        refreshRequestTask?.cancel()
        refreshRequestTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        pendingRequests.removeAll()
        let oldProcess = process
        detachProcess()
        publish(.stopped, nil)
        if let oldProcess {
            await Task.detached(priority: .utility) { oldProcess.waitUntilExit() }.value
        }
    }

    private func stopImmediately() {
        isStopping = true
        refreshTask?.cancel()
        refreshTask = nil
        usageRefreshTask?.cancel()
        usageRefreshTask = nil
        accountRefreshTask?.cancel()
        accountRefreshTask = nil
        credentialWatchTask?.cancel()
        credentialWatchTask = nil
        resetTimeoutTask?.cancel()
        resetTimeoutTask = nil
        initializeWatchdogTask?.cancel()
        initializeWatchdogTask = nil
        refreshRequestTask?.cancel()
        refreshRequestTask = nil
        processReplacementTask?.cancel()
        processReplacementTask = nil
        reconnectTask?.cancel()
        pendingRequests.removeAll()
        detachProcess()
        publish(.stopped, nil)
    }

    func refresh() {
        reconnectAttempt = 0
        automaticRetryExhausted = false
        guard !checkCredentialChange() else { return }
        guard RefreshRequestCoalescer.shouldSchedule(isScheduled: refreshRequestTask != nil) else { return }
        refreshRequestTask = Task { @MainActor [weak self] in
            defer { self?.refreshRequestTask = nil }
            await Task.yield()
            guard let self, !Task.isCancelled, !self.isStopping else { return }
            if self.process?.isRunning != true { self.connect(); return }
            self.refreshRateLimits()
            self.refreshTokenActivity()
            self.refreshAccount()
        }
    }

    func refreshRateLimits() {
        guard !checkCredentialChange() else { return }
        guard hasCompletedInitialization else { return }
        guard process?.isRunning == true else {
            if !isStopping { connect() }
            return
        }
        guard !hasPending(.rateLimitsRead) else { return }
        if sendRequest(method: "account/rateLimits/read", params: nil, kind: .rateLimitsRead) == nil {
            publish(.error, "無法傳送 rate-limit 請求，請重新連線。")
        }
    }

    func refreshTokenActivity() {
        guard !checkCredentialChange() else { return }
        guard hasCompletedInitialization else { return }
        guard process?.isRunning == true else {
            if !isStopping { connect() }
            return
        }
        guard !hasPending(.usageRead) else { return }
        onTokenActivityState?(.loading, nil)
        if sendRequest(method: "account/usage/read", params: nil, kind: .usageRead) == nil {
            onTokenActivityState?(.error, "無法傳送 Token Activity 請求，請重新連線。")
        }
    }

    func refreshAccount() {
        guard !checkCredentialChange() else { return }
        guard hasCompletedInitialization else { return }
        guard process?.isRunning == true else {
            if !isStopping { connect() }
            return
        }
        guard !hasPending(.accountRead) else { return }
        onAccountHealthState?(.loading, nil)
        if sendRequest(method: "account/read", params: ["refreshToken": false], kind: .accountRead) == nil {
            onAccountHealthState?(.error, "無法傳送帳號同步請求，請重新連線。")
        }
    }

    func consumeResetCredit(creditID: String) {
        guard !creditID.isEmpty else {
            onResetCreditResult?(.error("沒有選擇有效的 Reset credit。"))
            return
        }
        guard process?.isRunning == true else {
            onResetCreditResult?(.error("App Server 尚未連線，請先 Refresh。"))
            return
        }
        guard hasCompletedInitialization else {
            onResetCreditResult?(.error("App Server 正在初始化，請稍候再試。"))
            return
        }
        guard !pendingRequests.values.contains(where: {
            if case .resetCreditConsume = $0 { return true }
            return false
        }) else { return }
        let idempotencyKey = UUID().uuidString
        let requestID = sendRequest(
            method: "account/rateLimitResetCredit/consume",
            params: ["idempotencyKey": idempotencyKey, "creditId": creditID],
            kind: .resetCreditConsume
        )
        if requestID == nil {
            onResetCreditResult?(.error("無法傳送 Reset credit 請求，請 Refresh 後再試。"))
        }
    }

    private func connect() {
        guard !isStopping, process?.isRunning != true, processReplacementTask == nil else { return }
        guard let executable = resolveCodexExecutable() else {
            publish(.error, "找不到 Codex CLI。請確認 ChatGPT.app 已安裝，或設定 CODEX_CLI_PATH。")
            onTokenActivityState?(.error, "找不到 Codex CLI。")
            return
        }

        detachProcess()
        hasCompletedInitialization = false
        publish(.connecting, nil)
        lineBuffer = JSONLineBuffer()

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let generation = UUID()
        processGeneration = generation
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        if let codexHomeURL {
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = codexHomeURL.path
            process.environment = environment
        }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, self.processGeneration == generation else { return }
                self.consume(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let message, !message.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, self.processGeneration == generation else { return }
                self.logStderr(message)
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleTermination(generation: generation) }
        }

        do {
            try process.run()
        } catch {
            publish(.error, "無法啟動 Codex App Server：\(error.localizedDescription)")
            scheduleReconnect()
            return
        }

        self.process = process
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        _ = sendRequest(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "codex-usage-status",
                    "title": "Codex Usage Status",
                    "version": "2.1.0"
                ],
                "capabilities": ["experimentalApi": false]
            ],
            kind: .initialize
        )
        initializeWatchdogTask?.cancel()
        initializeWatchdogTask = Task { @MainActor [weak self, weak process] in
            try? await Task.sleep(nanoseconds: AppServerRetryPolicy.initializationWatchdogNanoseconds)
            guard !Task.isCancelled, let self, !self.isStopping,
                  !self.hasCompletedInitialization,
                  self.process === process else { return }
            self.pendingRequests.removeAll()
            self.detachProcess()
            self.publish(.error, "Codex App Server 初始化逾時，正在重試。")
            self.scheduleReconnect()
        }
    }

    private func sendNotification(method: String, params: Any? = nil) {
        guard let stdin = stdinPipe?.fileHandleForWriting else { return }
        do {
            try stdin.write(contentsOf: JSONRPCCodec.encodeNotification(method: method, params: params))
        } catch {
            logger.error("App Server notification write failed")
            publish(.error, "無法傳送 App Server 通知：\(error.localizedDescription)")
        }
    }

    private func consume(_ data: Data) {
        for line in lineBuffer.append(data) {
            do {
                try handle(JSONRPCCodec.decodeLine(line))
            } catch {
                logger.error("App Server JSON-RPC decode failed")
                publish(.error, "App Server 回傳無法解析的資料：\(error.localizedDescription)")
            }
        }
    }

    private func handle(_ message: JSONRPCMessage) throws {
        if let method = message.method {
            if method == "account/rateLimits/updated", let params = message.object["params"] {
                let patch = try UsageDataCodec.decodePatch(from: params)
                if let snapshot = patch.applying(to: latestSnapshot, receivedAt: Date()) {
                    latestSnapshot = snapshot
                    onSnapshot?(snapshot)
                    publish(.connected, nil)
                }
            } else if method == "account/updated" {
                // Do not let a sparse update or a late full response from the
                // previous account carry quota or reset-credit metadata across
                // the identity boundary.
                latestSnapshot = nil
                latestAuthMode = nil
                onAccountBoundary?()
                if let params = message.object["params"] as? [String: Any] {
                    if let authMode = params["authMode"] as? String {
                        latestAuthMode = authMode
                    }
                }
                latestAccountIdentityKey = nil
                invalidatePendingDataReads()
                invalidatePendingAccountRead()
                refreshAccount()
            } else if (method == "turn/started" || method == "turn/completed"),
                      let params = message.object["params"],
                      let event = TurnActivityCodec.decodeEvent(method: method, params: params) {
                onTurnEvent?(event)
            } else if method == "thread/tokenUsage/updated",
                      let params = message.object["params"],
                      let usage = TurnActivityCodec.decodeTokenUsage(params: params) {
                onTurnTokenUsage?(usage.threadID, usage.turnID, usage.tokenTotal)
            }
            return
        }

        guard let id = message.id, let kind = pendingRequests.removeValue(forKey: id) else { return }
        if case .resetCreditConsume = kind { resetTimeoutTask?.cancel(); resetTimeoutTask = nil }
        if let error = message.errorMessage {
            handleError(error, for: kind)
            return
        }

        switch kind {
        case .initialize:
            initializeWatchdogTask?.cancel()
            initializeWatchdogTask = nil
            hasCompletedInitialization = true
            reconnectAttempt = 0
            automaticRetryExhausted = false
            sendNotification(method: "initialized")
            _ = sendRequest(method: "account/rateLimits/read", params: nil, kind: .rateLimitsRead)
            // Quota is the first-paint-critical read. Slower metadata follows
            // on subsequent turns so the shell/popover can become usable first.
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !self.isStopping, self.hasCompletedInitialization else { return }
                _ = self.sendRequest(method: "account/usage/read", params: nil, kind: .usageRead)
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, !self.isStopping, self.hasCompletedInitialization else { return }
                _ = self.sendRequest(method: "account/read", params: ["refreshToken": false], kind: .accountRead)
            }
            publish(.connected, nil)
        case .rateLimitsRead:
            guard let result = message.result else {
                handleError("rate-limit 回應缺少 result", for: kind)
                return
            }
            do {
                var snapshot = try UsageDataCodec.decodeFullSnapshot(from: result, receivedAt: Date())
                if snapshot.rateLimitResetCredits == nil {
                    snapshot.rateLimitResetCredits = latestSnapshot?.rateLimitResetCredits
                }
                latestSnapshot = snapshot
                reconnectAttempt = 0
                onSnapshot?(snapshot)
                publish(.connected, nil)
            } catch {
                logger.error("Rate-limit snapshot decode failed")
                publish(.error, "無法解析 rate-limit snapshot：\(error.localizedDescription)")
            }
        case .usageRead:
            guard let result = message.result else {
                handleError("Token Activity 回應缺少 result", for: kind)
                return
            }
            do {
                let activity = try TokenActivityCodec.decode(from: result, fetchedAt: Date())
                onTokenActivity?(activity)
                onTokenActivityState?(.loaded, nil)
            } catch {
                logger.error("Token Activity decode failed")
                onTokenActivityState?(.error, "Token Activity 回應格式無法解析。")
            }
        case .accountRead:
            guard let result = message.result else {
                handleError("account/read 回應缺少 result", for: kind)
                return
            }
            // A switch notification can race the initial quota/activity reads.
            // Drop those responses and start fresh reads after the account
            // profile has been selected, so old-account data cannot win.
            invalidatePendingDataReads()
            do {
                let account = try AccountDataCodec.decode(from: result, receivedAt: Date()).applying(authMode: latestAuthMode)
                let identityKey = accountIdentityKey(account.identity)
                if let previousKey = latestAccountIdentityKey, previousKey != identityKey {
                    latestSnapshot = nil
                }
                latestAccountIdentityKey = identityKey
                onAccountHealth?(account)
                onAccountHealthState?(.loaded, nil)
                _ = sendRequest(method: "account/rateLimits/read", params: nil, kind: .rateLimitsRead)
                _ = sendRequest(method: "account/usage/read", params: nil, kind: .usageRead)
            } catch {
                logger.error("Account health decode failed")
                onAccountHealthState?(.error, "帳號資料回應格式無法解析。")
            }
        case .resetCreditConsume:
            let outcome = decodeResetOutcome(message.result)
            onResetCreditResult?(outcome)
            _ = sendRequest(method: "account/rateLimits/read", params: nil, kind: .rateLimitsRead)
        }
    }

    private func handleError(_ message: String, for kind: PendingRequest) {
        switch kind {
        case .initialize:
            initializeWatchdogTask?.cancel()
            initializeWatchdogTask = nil
            logger.error("App Server request failed")
            publish(.error, message)
            detachProcess()
            scheduleReconnect()
        case .rateLimitsRead:
            logger.error("App Server request failed")
            publish(.error, message)
        case .usageRead:
            logger.error("Token Activity request failed")
            let lower = message.lowercased()
            if lower.contains("unsupported") || lower.contains("api key") || lower.contains("bedrock") || lower.contains("auth") {
                onTokenActivityState?(.unsupported, "此登入模式不支援 Token Activity。")
            } else {
                onTokenActivityState?(.error, message)
            }
        case .accountRead:
            logger.error("Account request failed")
            let lower = message.lowercased()
            if lower.contains("unsupported") || lower.contains("api key") || lower.contains("bedrock") {
                onAccountHealthState?(.unsupported, "此登入模式不支援完整帳號資料。")
            } else {
                onAccountHealthState?(.error, message)
            }
        case .resetCreditConsume:
            logger.error("Reset credit request failed")
            onResetCreditResult?(.error(message))
            _ = sendRequest(method: "account/rateLimits/read", params: nil, kind: .rateLimitsRead)
        }
    }

    private func decodeResetOutcome(_ result: Any?) -> ResetCreditOutcome {
        let value: String?
        if let string = result as? String {
            value = string
        } else if let object = result as? [String: Any] {
            value = (object["outcome"] as? String)
                ?? (object["status"] as? String)
                ?? (object["result"] as? String)
        } else {
            value = nil
        }
        switch value?.lowercased() {
        case "reset": return .reset
        case "alreadyredeemed", "already_redeemed", "already-redeemed": return .alreadyRedeemed
        case "nothingtoreset", "nothing_to_reset", "nothing-to-reset": return .nothingToReset
        case "nocredit", "no_credit", "no-credit": return .noCredit
        default: return .error("Reset credit 回應無法辨識，請 Refresh 確認目前狀態。")
        }
    }

    private func sendRequest(method: String, params: Any?, kind: PendingRequest) -> Int? {
        guard let stdin = stdinPipe?.fileHandleForWriting else { return nil }
        let id = nextRequestID
        nextRequestID += 1
        do {
            let data = try JSONRPCCodec.encodeRequest(id: id, method: method, params: params)
            pendingRequests[id] = kind
            try stdin.write(contentsOf: data)
            if case .resetCreditConsume = kind {
                resetTimeoutTask?.cancel()
                resetTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    guard let self, self.pendingRequests.removeValue(forKey: id) != nil else { return }
                    self.onResetCreditResult?(.unknown("Reset credit 結果逾時且不明；請 Refresh 確認，未自動重試。"))
                    self.resetTimeoutTask = nil
                }
            }
            return id
        } catch {
            pendingRequests.removeValue(forKey: id)
            logger.error("App Server request write failed")
            if case .usageRead = kind {
                onTokenActivityState?(.error, "無法傳送 Token Activity 請求：\(error.localizedDescription)")
            } else if case .resetCreditConsume = kind {
                onResetCreditResult?(.error("無法傳送 Reset credit 請求：\(error.localizedDescription)"))
            } else if case .accountRead = kind {
                onAccountHealthState?(.error, "無法傳送帳號同步請求：\(error.localizedDescription)")
            } else {
                publish(.error, "無法傳送 App Server 請求：\(error.localizedDescription)")
            }
            return nil
        }
    }

    private func handleTermination(generation: UUID) {
        guard processGeneration == generation else { return }
        guard !isStopping else { return }
        let resetWasPending = pendingRequests.values.contains {
            if case .resetCreditConsume = $0 { return true }
            return false
        }
        pendingRequests.removeAll()
        resetTimeoutTask?.cancel()
        resetTimeoutTask = nil
        detachProcess()
        if resetWasPending {
            onResetCreditResult?(.unknown("App Server 在 Reset credit 完成前中斷；結果不明，請 Refresh 確認。"))
        }
        onTokenActivityState?(.offline, "App Server 離線，保留最後一次有效 Token Activity。")
        onAccountHealthState?(.offline, "App Server 離線，保留最後一次帳號資料。")
        publish(.offline, "Codex App Server 已停止，保留最後一次有效用量。")
        scheduleReconnect()
    }

    /// The ChatGPT desktop app can change the account behind an already-running
    /// app-server process. In that case the server may not emit
    /// account/updated to this separate monitor process, while the shared
    /// auth.json metadata changes on disk. Restarting only this worker makes it
    /// reload the new account without ever reading or persisting token content.
    @discardableResult
    private func checkCredentialChange() -> Bool {
        let signature = credentialSignature()
        guard observedCredentialSignature != signature else { return false }
        observedCredentialSignature = signature
        guard !isStopping else { return false }

        // Avoid a restart storm if the CLI refreshes its auth metadata more
        // than once in a short interval. The next poll will still observe the
        // latest signature and retry the boundary if necessary.
        if let lastCredentialRestartAt,
           Date().timeIntervalSince(lastCredentialRestartAt) < 30 {
            return false
        }
        lastCredentialRestartAt = Date()
        restartAfterCredentialChange()
        return true
    }

    private func restartAfterCredentialChange() {
        guard processReplacementTask == nil else { return }
        latestSnapshot = nil
        latestAuthMode = nil
        latestAccountIdentityKey = nil
        pendingRequests.removeAll()
        resetTimeoutTask?.cancel()
        resetTimeoutTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        onAccountBoundary?()
        onAccountHealthState?(.loading, "偵測到登入帳號變更，正在重新同步…")
        onTokenActivityState?(.loading, "偵測到登入帳號變更，正在重新同步…")
        publish(.connecting, "偵測到登入帳號變更，正在重新同步…")
        let oldProcess = process
        detachProcess()
        guard let oldProcess, oldProcess.isRunning else {
            connect()
            return
        }
        processReplacementTask = Task { @MainActor [weak self] in
            // waitUntilExit is blocking by design, but it runs on a utility
            // task so the main actor remains available for the HUD/popover.
            await Task.detached(priority: .utility) {
                oldProcess.waitUntilExit()
            }.value
            guard let self, !self.isStopping else { return }
            self.processReplacementTask = nil
            self.connect()
        }
    }

    private func scheduleReconnect() {
        guard !isStopping, reconnectTask == nil, !automaticRetryExhausted else { return }
        let attempt = reconnectAttempt
        guard let delay = AppServerRetryPolicy.delay(for: attempt) else {
            automaticRetryExhausted = true
            publish(.error, "App Server 自動重試已停止，請按 Refresh。")
            return
        }
        reconnectAttempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.finishReconnect()
        }
    }

    private func finishReconnect() {
        reconnectTask = nil
        connect()
    }

    private func detachProcess() {
        processGeneration = UUID()
        hasCompletedInitialization = false
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    private func publish(_ state: ConnectionState, _ message: String?) {
        onStateChange?(state, message)
    }

    private func logStderr(_ message: String) {
        // Keep server stderr out of the public unified log. It can contain
        // account or authentication context supplied by the App Server.
        logger.debug("Codex App Server emitted stderr")
    }

    private func hasPending(_ kind: PendingRequest) -> Bool {
        pendingRequests.values.contains { pending in
            switch (pending, kind) {
            case (.initialize, .initialize), (.rateLimitsRead, .rateLimitsRead),
                 (.usageRead, .usageRead), (.resetCreditConsume, .resetCreditConsume),
                 (.accountRead, .accountRead):
                return true
            default:
                return false
            }
        }
    }

    private func invalidatePendingDataReads() {
        pendingRequests = pendingRequests.filter { _, kind in
            switch kind {
            case .rateLimitsRead, .usageRead: return false
            default: return true
            }
        }
    }

    private func invalidatePendingAccountRead() {
        pendingRequests = pendingRequests.filter { _, kind in
            if case .accountRead = kind { return false }
            return true
        }
    }

    private func accountIdentityKey(_ identity: AccountIdentity) -> String {
        if let email = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !email.isEmpty {
            return "email|\(email)"
        }
        return "unknown|\(identity.accountType ?? "")|\(identity.authMode ?? "")"
    }

    private func credentialSignature() -> String {
        let authURL = effectiveCodexHomeURL.appendingPathComponent("auth.json")
        guard let attributes = try? fileManager.attributesOfItem(atPath: authURL.path) else {
            return "missing"
        }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.int64Value ?? -1
        return "\(modified)|\(size)|\(fileNumber)"
    }

    private var effectiveCodexHomeURL: URL {
        if let codexHomeURL { return codexHomeURL }
        if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    private func resolveCodexExecutable() -> String? {
        CodexCLIResolver.resolve(environment: ProcessInfo.processInfo.environment, fileManager: fileManager)
    }
}

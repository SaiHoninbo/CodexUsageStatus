import AppKit
import Charts
import SwiftUI

struct UsagePopoverView: View {
    @ObservedObject var model: UsageViewModel
    @ObservedObject var gitCoordinator: GitWorkspaceCoordinator
    @ObservedObject var detailsRouter: DetailsRouter
    let openCodex: () -> Void
    let resetHUDPosition: () -> Void
    let quit: () -> Void

    @State private var showSettings = false
    @State private var showSyncSettings = false
    @State private var showClearHistoryConfirmation = false
    @State private var showResetCreditConfirmation = false
    @State private var showRemoveProfileConfirmation = false
    @State private var profilePendingRemoval: AccountProfile?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                updateSection
                Divider()
                accountSelector
                accountManagementSection
                gitWorkspaceSection.id("gitWorkspace")
                if model.accountScope == .current {
                    accountHealthSection
                    turnActivitySection
                } else {
                    Text("全部帳號模式：帳號健康、Reset Credit 與即時 Turn 僅適用目前帳號。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.accountScope == .all {
                    aggregateQuotaSection
                } else {
                    windowSection(title: "Primary window", window: model.snapshot?.primary)
                    windowSection(title: "Secondary window", window: model.snapshot?.secondary)
                    if let spend = model.snapshot?.individualLimit {
                        spendControlSection(spend)
                    }
                }
                tokenActivitySection
                resetCreditSection
                historySection
                settingsSection
                syncSettingsSection
                metadataSection
                actions
            }
            .padding(18)
        }
        .frame(width: 410, height: 820)
        .onChange(of: detailsRouter.destination) { _, destination in
            guard destination == .gitWorkspace else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("gitWorkspace", anchor: .top)
            }
        }
        }
        .confirmationDialog("確認 Git 操作", isPresented: Binding(
            get: { gitCoordinator.confirmation != nil },
            set: { if !$0 { gitCoordinator.cancelConfirmation() } }
        ), titleVisibility: .visible) {
            if let confirmation = gitCoordinator.confirmation {
                switch confirmation {
                case .commit, .sensitiveCommit:
                    Button(confirmation == .sensitiveCommit ? "確認提交（含敏感檔案）" : "確認 Commit", role: .destructive) {
                        gitCoordinator.confirmCommit()
                    }
                case .push:
                    Button("確認 Push", role: .destructive) {
                        gitCoordinator.confirmPush()
                    }
                }
            }
            Button("取消", role: .cancel) { gitCoordinator.cancelConfirmation() }
        } message: {
            if let confirmation = gitCoordinator.confirmation {
                switch confirmation {
                case .commit:
                    Text("只會提交目前勾選的路徑，不會帶入其他既有 staged 檔案。")
                case .sensitiveCommit:
                    Text("選取內容包含可能的敏感檔案。仍要提交嗎？敏感檔案不會在此面板顯示 raw diff。")
                case .push:
                    Text("將 Push \(gitCoordinator.branchLabel) 到目前已確認的 upstream。執行前若 repo identity 改變，操作會中止。")
                }
            }
        }
        .alert("清除本機歷史？", isPresented: $showClearHistoryConfirmation) {
            Button("清除", role: .destructive) { model.clearHistory() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("這會刪除最近 30 天的用量時間序列，不會影響 Codex 或登入狀態。")
        }
        .alert("使用 Reset Credit？", isPresented: $showResetCreditConfirmation) {
            Button("使用", role: .destructive) { model.consumeSelectedResetCredit() }
            Button("取消", role: .cancel) { model.cancelResetCredit() }
        } message: {
            if let credit = model.selectedResetCredit {
                Text("Credit：\(credit.title ?? "所選 Reset credit")\nBucket：\(credit.resetType ?? "未知")\n到期：\(creditDate(credit.expiresAt))\n此操作不可自動復原。")
            } else {
                Text("請先選擇一張可用的 Reset credit。")
            }
        }
        .alert("刪除受管帳號？", isPresented: $showRemoveProfileConfirmation) {
            Button("刪除", role: .destructive) {
                if let profilePendingRemoval { model.removeProfile(id: profilePendingRemoval.id) }
                profilePendingRemoval = nil
            }
            Button("取消", role: .cancel) { profilePendingRemoval = nil }
        } message: {
            Text("這會停止該帳號的 App Server，並刪除其受管 credentials、歷史與 Token Activity。系統 ~/.codex 不會被修改。")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Codex 用量")
                    .font(.headline)
                Text(model.accountDisplayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let remaining = model.menuBarRemainingPercent {
                    Text("剩餘 \(remaining)%")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(model.menuBarColor)
                } else {
                    Text("—")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Text(model.dataAgeText)
                    .font(.caption)
                    .foregroundStyle(model.shouldShowOfflineBadge ? .orange : .secondary)
            }
            Spacer()
            Label(model.connectionState.displayName, systemImage: connectionIcon)
                .font(.caption)
                .foregroundStyle(model.shouldShowOfflineBadge ? Color.secondary : Color.green)
        }
    }

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("軟體更新", systemImage: "arrow.down.circle")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                updateStatusLabel
            }

            switch model.updateState {
            case .idle:
                Text("啟動後會檢查 GitHub Release。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在檢查 GitHub 更新…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") { model.cancelUpdateCheck() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            case .upToDate:
                Text("目前已是最新版本。")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .available(let release):
                updateReleaseDetails(release, downloadedURL: nil)
                HStack(spacing: 8) {
                    Button("立即更新並重新啟動") { model.downloadAvailableUpdate() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("開啟 Release") { model.openUpdateReleasePage() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            case .downloading(let release):
                updateReleaseDetails(release, downloadedURL: nil)
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在下載、驗證並安裝…")
                        .font(.caption)
                    Spacer()
                    Button("取消") { model.cancelUpdateDownload() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            case .downloaded(let release, let appURL):
                updateReleaseDetails(release, downloadedURL: appURL)
                Text("更新檔已通過 SHA-256（若 Release 提供）與 strict code signature 驗證，正在由背景安裝器替換同一路徑的 App 並重新啟動。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .error(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("重試") { model.checkForUpdates() }
                        .buttonStyle(.link)
                        .font(.caption)
                    Button("開啟 GitHub") { model.openUpdateReleasePage() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private var updateStatusLabel: some View {
        switch model.updateState {
        case .checking, .downloading:
            Text("處理中").font(.caption2).foregroundStyle(.secondary)
        case .available:
            Text("有新版").font(.caption2).foregroundStyle(.blue)
        case .downloaded:
            Text("已驗證").font(.caption2).foregroundStyle(.green)
        case .upToDate:
            Text("最新").font(.caption2).foregroundStyle(.green)
        case .error:
            Text("檢查失敗").font(.caption2).foregroundStyle(.orange)
        case .idle:
            EmptyView()
        }
    }

    private func updateReleaseDetails(_ release: AppUpdateRelease, downloadedURL: URL?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("版本 \(release.version)")
                .font(.caption.weight(.semibold))
            if let publishedAt = release.publishedAt {
                Text("發布：\(publishedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !release.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(release.notes)
                    .font(.caption2)
                    .lineLimit(3)
                    .foregroundStyle(.secondary)
            }
            if let downloadedURL {
                Text("已驗證：\(downloadedURL.deletingLastPathComponent().lastPathComponent)")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .lineLimit(1)
            }
        }
    }

    private var accountSelector: some View {
        HStack {
            Picker("帳號範圍", selection: $model.accountScope) {
                ForEach(AccountScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            if model.accountScope == .current {
                Menu {
                    ForEach(model.accountProfiles) { profile in
                        Button {
                            model.selectProfile(id: profile.id)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: profile.id == model.currentProfileID ? "checkmark" : (model.accountProfileDisplay(for: profile).isWarning ? "exclamationmark.triangle" : "person"))
                                    .frame(width: 16)
                                accountDisplayStack(profile)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    Divider()
                    Button("新增受管帳號") { _ = model.createManagedProfile() }
                } label: {
                    Image(systemName: "person.crop.circle.badge.plus")
                }
                .help("切換或建立本機 profile")
            }
            Spacer()
            if model.accountScope == .current {
                Text(model.accountHealthState.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if model.accountProfiles.contains(where: \.isUnidentified) {
                Text("未識別帳號不含穩定 Email，可能需要手動分開管理。")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }


    private func accountDisplayStack(_ profile: AccountProfile) -> some View {
        let display = model.accountProfileDisplay(for: profile)
        return VStack(alignment: .leading, spacing: 1) {
            Text(display.title)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(display.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accountManagementSection: some View {
        DisclosureGroup("帳號管理") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.accountProfiles) { profile in
                    HStack(spacing: 8) {
                        Image(systemName: profile.id == model.currentProfileID ? "checkmark.circle.fill" : "person.crop.circle")
                            .foregroundStyle(profile.id == model.currentProfileID ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.accountProfileDisplay(for: profile).title)
                                .font(.caption.weight(.semibold))
                            Text(model.accountProfileDisplay(for: profile).subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(model.profileStatusText(profile))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if profile.isManaged {
                            Button("登入") { model.startOfficialLogin(for: profile.id) }
                                .buttonStyle(.link)
                                .font(.caption2)
                                .disabled(model.loginStates[profile.id]?.hasPrefix("正在") == true)
                            Button(role: .destructive) {
                                profilePendingRemoval = profile
                                showRemoveProfileConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .help("刪除受管帳號")
                        }
                    }
                    if let state = model.loginStates[profile.id] {
                        Text(state)
                            .font(.caption2)
                            .foregroundStyle(state.contains("失敗") || state.contains("找不到") ? .orange : .secondary)
                            .padding(.leading, 26)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        _ = model.createManagedProfile()
                    } label: {
                        Label("新增帳號", systemImage: "person.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        model.importProfileForCurrentAccount()
                    } label: {
                        Label("匯入 Codex profile", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Text("每個帳號使用獨立 CODEX_HOME 與 App Server；切換不會改動系統 ~/.codex。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
    }

    private var gitWorkspaceSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Git 工作區", systemImage: "arrow.triangle.branch")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(action: { gitCoordinator.refreshNow() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("重新整理 Git 狀態")
                .disabled(gitCoordinator.operationState.isBusy)
            }

            if !gitCoordinator.resolution.isKnown {
                Text(gitCoordinator.resolution.reason.isEmpty ? "請先選擇工作區" : gitCoordinator.resolution.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("只使用目前 Codex focused window 的公開 metadata；無法可靠判定時不會猜測路徑。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if let snapshot = gitCoordinator.snapshot {
                HStack {
                    Text(snapshot.isDetached ? "detached" : (snapshot.identity.branch ?? "—"))
                        .font(.caption.weight(.semibold))
                    if snapshot.ahead > 0 || snapshot.behind > 0 {
                        Text("↑\(snapshot.ahead) ↓\(snapshot.behind)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(snapshot.changes.isEmpty ? "clean" : "\(snapshot.changes.count) 個變更")
                        .font(.caption2)
                        .foregroundStyle(snapshot.hasConflicts ? .red : .secondary)
                }
                if snapshot.changes.isEmpty {
                    Text("工作區乾淨，沒有可提交的變更。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.changes) { change in
                        HStack(alignment: .top, spacing: 6) {
                            Toggle(isOn: Binding(
                                get: { gitCoordinator.selectedPaths.contains(change.path) },
                                set: { _ in gitCoordinator.toggleSelection(path: change.path) }
                            )) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(change.path)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Text(change.isSensitive ? "敏感檔案：只顯示路徑，不顯示 raw diff" : change.kind.rawValue)
                                        .font(.caption2)
                                        .foregroundStyle(change.isSensitive ? .orange : .secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                            if !change.isSensitive {
                                Button(action: { gitCoordinator.loadDiff(path: change.path) }) {
                                    Image(systemName: "doc.text.magnifyingglass")
                                }
                                .buttonStyle(.plain)
                                .help("預覽差異")
                            }
                        }
                    }
                }
                TextField("Commit 訊息", text: $gitCoordinator.commitMessage)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    Button("Commit") { gitCoordinator.requestCommitConfirmation() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(gitCoordinator.selectedPaths.isEmpty || gitCoordinator.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || gitCoordinator.operationState.isBusy)
                    Button("Push") { gitCoordinator.requestPushConfirmation() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(snapshot.identity.upstream == nil || snapshot.isDetached || gitCoordinator.operationState.isBusy)
                }
                if let diff = gitCoordinator.diffPreview {
                    Text(diff)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(14)
                        .padding(6)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            switch gitCoordinator.operationState {
            case .success(let message), .error(let message), .unavailable(let message):
                Text(message).font(.caption2).foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
    }

    private var accountHealthSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("帳號健康")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(model.accountHealthState.displayName)
                    .font(.caption)
                    .foregroundStyle(model.accountHealthState == .loaded ? .green : .secondary)
            }
            if let account = model.accountHealth {
                metadataRow("登入模式", account.identity.authMode ?? "—")
                metadataRow("帳號類型", account.identity.accountType ?? "—")
                metadataRow("方案", account.identity.planType ?? "—")
                metadataRow("需要 OpenAI 認證", account.identity.requiresOpenAIAuth ? "是" : "否")
                metadataRow("Email", account.identity.email ?? "未提供")
                metadataRow("同步時間", account.receivedAt.formatted(date: .abbreviated, time: .shortened))
            } else {
                Text(model.accountHealthErrorMessage ?? "尚未取得帳號資料。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var turnActivitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("即時 Turn")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(model.activeTurn.state.displayName)
                    .font(.caption)
                    .foregroundStyle(model.activeTurn.state == .active ? .blue : .secondary)
            }
            if model.activeTurn.state == .idle || model.activeTurn.state == .unknown {
                Text(model.activeTurn.state.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if let threadID = model.activeTurn.threadID { metadataRow("Thread", String(threadID.prefix(12))) }
                if let turnID = model.activeTurn.turnID { metadataRow("Turn", String(turnID.prefix(12))) }
                if let started = model.activeTurn.startedAt {
                    metadataRow("開始", started.formatted(date: .omitted, time: .shortened))
                }
                if let elapsed = model.activeTurn.elapsedSeconds {
                    metadataRow("耗時", durationText(elapsed))
                }
                if let tokens = model.activeTurn.tokenTotal {
                    metadataRow("目前 token", tokens.formatted())
                }
                if let content = model.activeTurn.content, !content.isEmpty {
                    Text(content)
                        .font(.caption)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = model.activeTurn.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var aggregateQuotaSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("全部帳號 Quota")
                .font(.subheadline.weight(.semibold))
            ForEach(model.profileQuotaSummaries()) { summary in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        accountDisplayStack(summary.profile)
                        if summary.profile.isUnidentified {
                            Text("未識別，可能需要手動分帳")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    if let remaining = summary.primaryRemainingPercent {
                        Text("Primary \(remaining)%")
                            .fontWeight(.semibold)
                            .foregroundStyle(color(for: remaining))
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                    if summary.isStale {
                        Image(systemName: "clock.badge.exclamationmark")
                            .foregroundStyle(.orange)
                            .help("離線或資料較舊")
                    }
                }
                .font(.caption)
            }
            if model.profileQuotaSummaries().isEmpty {
                Text("尚未建立帳號 profile")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            let points = model.profileQuotaPoints()
            if !points.isEmpty {
                Chart(points) { point in
                    LineMark(
                        x: .value("時間", point.date),
                        y: .value("已用", point.usedPercent)
                    )
                    .foregroundStyle(by: .value("帳號", point.profileName))
                }
                .chartYScale(domain: 0...100)
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 130)
            }
            Text("Quota 以帳號分列，不計算總剩餘百分比。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func windowSection(title: String, window: RateLimitWindow?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if let window {
                HStack {
                    Text("剩餘")
                    Spacer()
                    Text("\(window.remainingPercent)%")
                        .fontWeight(.semibold)
                }
                ProgressView(value: Double(window.remainingPercent), total: 100)
                    .tint(color(for: window.remainingPercent))
                HStack {
                    Text("已用 \(window.clampedUsedPercent)%")
                    Spacer()
                    Text(model.resetDescription(window.resetsAt))
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                if let timestamp = window.resetsAt {
                    Text(Date(timeIntervalSince1970: TimeInterval(timestamp)).formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("目前沒有資料")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func spendControlSection(_ spend: SpendControlLimit) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Workspace spend control")
                .font(.subheadline.weight(.semibold))
            HStack {
                Text("剩餘")
                Spacer()
                Text("\(spend.remainingPercent)%")
                    .fontWeight(.semibold)
            }
            ProgressView(value: Double(spend.remainingPercent), total: 100)
                .tint(color(for: spend.remainingPercent))
            HStack {
                Text("已用 \(spend.used) / \(spend.limit)")
                Spacer()
                Text(model.resetDescription(spend.resetsAt))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    private var tokenActivitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Token Activity")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(model.tokenActivityState.displayName)
                    .font(.caption)
                    .foregroundStyle(model.tokenActivityState == .loaded ? .green : .secondary)
            }
            if let activity = model.displayedTokenActivity {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                    metric("累計 token", tokenCount(activity.lifetimeTokens))
                    metric("單日峰值", tokenCount(activity.peakDailyTokens))
                    metric("最長執行", durationText(activity.longestRunningTurnSec))
                    metric(model.accountScope == .all ? "單一帳號最長目前連續" : "目前連續", daysText(activity.currentStreakDays))
                    metric(model.accountScope == .all ? "單一帳號最長連續" : "最長連續", daysText(activity.longestStreakDays))
                }
                HStack {
                    Text("每日 token")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Picker("範圍", selection: $model.tokenActivityRange) {
                        ForEach(TokenActivityRange.allCases) { range in Text(range.title).tag(range) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
                let buckets = model.visibleTokenBuckets
                if buckets.isEmpty {
                    Text("目前沒有每日 token bucket")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Chart(buckets) { bucket in
                        BarMark(
                            x: .value("日期", bucket.startDate),
                            y: .value("token", bucket.tokens)
                        )
                        .foregroundStyle(.blue.gradient)
                    }
                    .chartYAxis { AxisMarks(position: .leading) }
                    .frame(height: 130)
                }
                Text("最後抓取：\(activity.fetchedAt.formatted(date: .abbreviated, time: .shortened))\(model.tokenActivityIsStale ? " · 資料較舊" : "")")
                    .font(.caption2)
                    .foregroundStyle(model.tokenActivityIsStale ? .orange : .secondary)
            } else {
                Text(model.tokenActivityErrorMessage ?? "尚未取得 Token Activity。按 Refresh 讀取。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = model.tokenActivityErrorMessage, model.tokenActivity != nil {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }
            if model.tokenActivityState == .loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在更新 Token Activity…").font(.caption)
                }
            } else {
                Button("Refresh Token Activity") { model.refreshTokenActivity() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private var resetCreditSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Reset Credit")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("可用 \(model.resetCredits?.availableCount ?? 0) 張")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.accountScope == .all {
                Text("請切回目前帳號後操作；不會在全部帳號模式消耗 credit。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let credits = model.resetCredits, credits.availableCount > 0 {
                if let details = credits.credits, !details.isEmpty {
                    Picker("選擇 credit", selection: Binding(
                        get: { model.selectedResetCreditID ?? "" },
                        set: { model.selectResetCredit(id: $0.isEmpty ? nil : $0) }
                    )) {
                        Text("請選擇…").tag("")
                        ForEach(Array(details.filter(\.isAvailable).enumerated()), id: \.element.id) { index, credit in
                            Text(credit.title ?? "Reset credit \(index + 1)").tag(credit.id)
                        }
                    }
                    if let credit = model.selectedResetCredit {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(credit.description ?? "沒有額外說明")
                            Text("Bucket：\(credit.resetType ?? "未知") · 到期：\(creditDate(credit.expiresAt))")
                            Text("取得：\(creditDate(credit.grantedAt))")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Button(model.resetCreditOperationState == .consuming ? "使用中…" : "使用所選 Reset Credit") {
                        showResetCreditConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.accountScope == .all || model.selectedResetCredit == nil || model.resetCreditOperationState == .consuming || model.resetCreditOperationState == .unknown)
                } else {
                    Text("服務只回傳可用數量，尚未提供可安全選擇的 credit 詳細資料。請稍後 Refresh。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(model.resetCredits == nil ? "尚未取得 Reset credit 資料。" : "目前沒有可用的 Reset credit。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let message = model.resetCreditMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(model.resetCreditOperationState == .error ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tokenCount(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return value.formatted()
    }

    private func daysText(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return "\(value) 天"
    }

    private func durationText(_ value: Int64?) -> String {
        guard let value else { return "—" }
        if value < 60 { return "\(value) 秒" }
        if value < 3600 { return "\(value / 60) 分 \(value % 60) 秒" }
        return "\(value / 3600) 小時 \((value % 3600) / 60) 分"
    }

    private func creditDate(_ timestamp: Int64?) -> String {
        guard let timestamp else { return "未知" }
        return Date(timeIntervalSince1970: TimeInterval(timestamp)).formatted(date: .abbreviated, time: .shortened)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("用量歷史")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("範圍", selection: $model.historyRange) {
                    ForEach(HistoryRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            let samples = model.visibleHistorySamples()
            let resetDates = Array(Set(samples.flatMap { sample in
                [sample.primaryResetsAt, sample.secondaryResetsAt]
            }.compactMap { timestamp in
                timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            })).sorted()
            if samples.contains(where: { $0.connectionState == .connected && ($0.primaryUsedPercent != nil || $0.secondaryUsedPercent != nil) }) {
                Chart {
                    ForEach(samples) { sample in
                        if sample.connectionState == .connected, let used = sample.primaryUsedPercent {
                            LineMark(
                                x: .value("時間", sample.receivedAt),
                                y: .value("已用", min(100, max(0, used)))
                            )
                            .foregroundStyle(by: .value("窗口", "Primary"))
                        }
                        if sample.connectionState == .connected, let used = sample.secondaryUsedPercent {
                            LineMark(
                                x: .value("時間", sample.receivedAt),
                                y: .value("已用", min(100, max(0, used)))
                            )
                            .foregroundStyle(by: .value("窗口", "Secondary"))
                        }
                    }
                    ForEach(resetDates, id: \.self) { resetDate in
                        RuleMark(x: .value("重置", resetDate))
                            .foregroundStyle(.blue.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    }
                    ForEach(model.notificationThresholds, id: \.self) { threshold in
                        RuleMark(y: .value("剩餘 \(threshold)%", 100 - threshold))
                            .foregroundStyle(.orange.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                    }
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 160)
                Text("圖表顯示已用百分比；灰色／離線區段不納入即時提醒。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("尚未累積足夠的歷史資料")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Text("本機保存最近 30 天")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清除歷史", role: .destructive) {
                    showClearHistoryConfirmation = true
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            if let error = model.historyErrorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if model.accountScope == .all {
                Text("此區塊仍顯示目前帳號歷史；全部帳號的聚合資料請查看上方 Token Activity 與 Quota。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let error = model.profileStoreErrorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var settingsSection: some View {
        DisclosureGroup("通知設定", isExpanded: $showSettings) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("啟用用量通知", isOn: Binding(
                    get: { model.notificationsEnabled },
                    set: { model.setNotificationsEnabled($0) }
                ))
                Toggle("Primary／secondary 分開提醒", isOn: Binding(
                    get: { model.separateWindowNotifications },
                    set: { model.setSeparateWindowNotifications($0) }
                ))
                Toggle("播放提示音", isOn: Binding(
                    get: { model.notificationSoundEnabled },
                    set: { model.setNotificationSoundEnabled($0) }
                ))
                Toggle("Turn 完成通知", isOn: Binding(
                    get: { model.notifyOnTurnSuccess },
                    set: { model.setTurnSuccessNotifications($0) }
                ))
                Toggle("Turn 失敗通知", isOn: Binding(
                    get: { model.notifyOnTurnFailure },
                    set: { model.setTurnFailureNotifications($0) }
                ))
                Toggle("Turn 中斷通知", isOn: Binding(
                    get: { model.notifyOnTurnInterrupted },
                    set: { model.setTurnInterruptedNotifications($0) }
                ))
                Toggle("長時間 Turn 通知", isOn: Binding(
                    get: { model.notifyOnLongRunningTurn },
                    set: { model.setLongRunningTurnNotifications($0) }
                ))
                Toggle("通知顯示 Turn 內容", isOn: Binding(
                    get: { model.showTurnContentInNotifications },
                    set: { model.setTurnContentInNotifications($0) }
                ))
                Toggle("帳號切換通知", isOn: Binding(
                    get: { model.notifyOnAccountSwitch },
                    set: { model.setAccountSwitchNotifications($0) }
                ))
                Toggle("顯示 Codex 浮動用量 HUD", isOn: Binding(
                    get: { model.floatingHUDEnabled },
                    set: { model.setFloatingHUDEnabled($0) }
                ))
                Text("只在 Codex 視窗位於前景時顯示；這是獨立浮動面板，不會修改 Codex 主視窗。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重設 HUD 位置") { resetHUDPosition() }
                    .buttonStyle(.link)
                    .font(.caption)

                Text("提醒門檻")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], spacing: 6) {
                    ForEach([50, 25, 20, 10, 5], id: \.self) { threshold in
                        Toggle("剩餘 \(threshold)%", isOn: Binding(
                            get: { model.notificationThresholds.contains(threshold) },
                            set: { model.setThreshold(threshold, enabled: $0) }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    }
                }

                HStack {
                    Text("通知權限：\(model.notificationAuthorizationText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.notificationAuthorizationStatus == .denied {
                        Button("開啟系統設定") { openNotificationSettings() }
                            .buttonStyle(.link)
                            .font(.caption)
                    } else if model.notificationAuthorizationStatus == .notDetermined {
                        Button("允許通知") { model.requestNotificationPermission() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
            .padding(.top, 6)
        }
        .font(.subheadline.weight(.semibold))
    }

    private var syncSettingsSection: some View {
        DisclosureGroup("同步設定", isExpanded: $showSyncSettings) {
            VStack(alignment: .leading, spacing: 9) {
                syncIntervalPicker(
                    title: "Quota／Primary／Secondary",
                    value: model.quotaRefreshIntervalSeconds,
                    options: [30, 60, 120, 300, 600, 1800, 3600],
                    setter: model.setQuotaRefreshInterval
                )
                syncIntervalPicker(
                    title: "目前帳號身份",
                    value: model.globalSyncIntervalSeconds,
                    options: [60, 300, 600, 900, 1800, 3600],
                    setter: model.setGlobalSyncInterval
                )
                syncIntervalPicker(
                    title: "Token Activity",
                    value: model.tokenActivityRefreshIntervalSeconds,
                    options: [300, 900, 1800, 3600, 7200],
                    setter: model.setTokenActivityRefreshInterval
                )
                syncIntervalPicker(
                    title: "帳號切換偵測",
                    value: model.credentialWatchIntervalSeconds,
                    options: [5, 15, 30, 60, 120],
                    setter: model.setCredentialWatchInterval
                )
                Text("帳號切換偵測只檢查 auth.json 的修改時間、大小與檔案編號，不讀取或保存 token。變更後會重新啟動對應的本機 App Server。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
        .font(.subheadline.weight(.semibold))
    }

    private func syncIntervalPicker(
        title: String,
        value: Int,
        options: [Int],
        setter: @escaping (Int) -> Void
    ) -> some View {
        HStack {
            Text(title)
                .font(.caption)
            Spacer()
            Picker(title, selection: Binding(
                get: { value },
                set: setter
            )) {
                ForEach(options, id: \.self) { option in
                    Text(formatInterval(option)).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 120)
        }
    }

    private func formatInterval(_ seconds: Int) -> String {
        if seconds < 60 { return "(seconds) 秒" }
        let minutes = seconds / 60
        if minutes < 60 { return "(minutes) 分鐘" }
        return "(minutes / 60) 小時"
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            metadataRow("方案", model.snapshot?.planType ?? "—")
            metadataRow("Limit", model.snapshot?.limitName ?? model.snapshot?.limitId ?? "—")
            metadataRow("最後更新", model.lastUpdatedText)
            metadataRow("登入啟動", model.loginItemManager.statusText)
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        HStack {
            Button("Refresh") { model.refresh() }
            Button("Open Codex") { openCodex() }
            Spacer()
            Button("Quit") { quit() }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .lineLimit(1)
        }
        .font(.caption)
    }

    private func color(for percent: Int) -> Color {
        if percent < 20 { return .red }
        if percent < 50 { return .orange }
        return .green
    }

    private var connectionIcon: String {
        switch model.connectionState {
        case .connected: return "checkmark.circle.fill"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .offline: return "wifi.slash"
        case .error: return "exclamationmark.triangle"
        default: return "circle"
        }
    }

    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings") else { return }
        NSWorkspace.shared.open(url)
    }
}

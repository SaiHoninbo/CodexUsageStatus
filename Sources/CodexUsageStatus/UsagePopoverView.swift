import AppKit
import Charts
import SwiftUI

private struct PopoverContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct UsagePopoverView: View {
    @ObservedObject var model: UsageViewModel
    @ObservedObject var selectionController: PopoverSelectionController
    let openCodex: () -> Void
    let resetHUDPosition: () -> Void
    let quit: () -> Void
    let onContentHeightChange: ((CGFloat) -> Void)?

    @State private var showClearHistoryConfirmation = false
    @State private var showResetCreditConfirmation = false
    @State private var showRemoveProfileConfirmation = false
    @State private var profilePendingRemoval: AccountProfile?
    @State private var measuredContentHeight: CGFloat = 0
    private var selectedTab: UsagePopoverTab { selectionController.selectedTab }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                header
                tabBar
                tabContent
            }
            .padding(20)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: PopoverContentHeightPreferenceKey.self, value: proxy.size.height)
                }
            }
        }
        .frame(width: 430)
        .foregroundStyle(HUDColorPalette.primaryText)
        .preferredColorScheme(.light)
        .onAppear { selectionController.select(.overview) }
        .onPreferenceChange(PopoverContentHeightPreferenceKey.self) { height in
            guard height > 0, abs(height - measuredContentHeight) > 0.5 else { return }
            measuredContentHeight = height
            onContentHeightChange?(height)
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

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(UsagePopoverTab.allCases) { tab in
                Button {
                    selectionController.select(tab)
                } label: {
                    Label(tab.title, systemImage: tab.systemImage)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedTab == tab ? Color.white : HUDColorPalette.primaryText)
                .background(
                    selectedTab == tab ? Color.accentColor : Color.black.opacity(0.08),
                    in: Capsule()
                )
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.secondary.opacity(0.08), in: Capsule())
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .overview:
            overviewTab
        case .history:
            historyTab
        case .settings:
            settingsTab
        }
    }

    private var overviewTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            accountSelector
            quotaSummarySection
            overviewTurnActivity
            resetCreditSection
            quickActions
        }
    }

    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            historySection
            tokenActivitySection
        }
    }

    private var settingsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            accountManagementSection
            settingsSection
            syncSettingsSection
            updateSection
            metadataSection
            actions
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Codex 用量")
                        .font(.title3.weight(.semibold))
                    Text(AppVersion.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(model.accountDisplayName)
                    .font(.body)
                    .foregroundStyle(.secondary)
                if let remaining = model.menuBarRemainingPercent {
                    Text("剩餘 \(remaining)%")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(model.menuBarColor)
                } else {
                    Text("—")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Text(model.dataAgeText)
                    .font(.subheadline)
                    .foregroundStyle(model.shouldShowOfflineBadge ? .orange : .secondary)
            }
            Spacer()
            Label(model.connectionState.displayName, systemImage: connectionIcon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(model.shouldShowOfflineBadge ? Color.secondary : Color.green)
        }
    }

    private var quotaSummarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("目前用量", systemImage: "chart.bar.fill")
                    .font(.headline)
                Spacer()
                Text(model.accountScope == .current ? "目前帳號" : "全部帳號")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if model.accountScope == .current {
                let presentation = HUDQuotaPresentationPolicy.make(
                    snapshot: model.snapshot,
                    profileID: model.currentProfileID
                )
                quotaSummaryRow(kind: .fiveHour, presentation: presentation?.fiveHour, accent: .orange)
                quotaSummaryRow(kind: .sevenDay, presentation: presentation?.sevenDay, accent: .blue)
                if let reserve = presentation?.gptReserveWeekly {
                    quotaSummaryRow(kind: .gptReserveWeekly, presentation: reserve, accent: .purple)
                }
            } else {
                let summary = model.accountScopeSummary
                if summary.totalAccounts == 0 {
                    Text("尚未取得帳號用量。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        accountScopeMetric("帳號總數", summary.totalAccounts, color: .blue)
                        accountScopeMetric("可用／活躍", summary.availableOrActiveAccounts, color: .green)
                        accountScopeMetric("資料較舊", summary.staleAccounts, color: .orange)
                        accountScopeMetric("未識別", summary.unidentifiedAccounts, color: .secondary)
                    }
                    Button {
                        selectionController.select(.settings)
                    } label: {
                        Label("前往帳號管理", systemImage: "arrow.right")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .buttonStyle(.link)
                    .font(.caption.weight(.semibold))
                    .accessibilityHint("前往設定中的帳號管理")
                }
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func accountScopeMetric(_ label: String, _ value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.title3.weight(.bold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.white.opacity(0.48), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func quotaSummaryRow(kind: HUDQuotaWindowKind, presentation: HUDQuotaWindowPresentation?, accent: Color) -> some View {
        if let presentation {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(presentation.label)
                        .font(.body.weight(.semibold))
                    Text("已用 \(100 - presentation.remainingPercent)%")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("剩餘 \(presentation.remainingPercent)%")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)
                }
                ProgressView(value: Double(presentation.remainingPercent), total: 100)
                    .tint(accent)
                Text(presentation.resetDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack {
                Text(kind.label).font(.body.weight(.semibold))
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var overviewTurnActivity: some View {
        if model.accountScope != .current {
            EmptyView()
        } else {
            switch model.activeTurn.state {
            case .active, .completed, .failed, .interrupted:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Label("目前 Turn", systemImage: "bolt.horizontal.circle")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(model.activeTurn.state.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(model.activeTurn.state == .active ? .blue : (model.activeTurn.state == .failed ? .orange : .secondary))
                    }
                    HStack(spacing: 12) {
                        if let elapsed = model.activeTurn.elapsedSeconds {
                            Text(durationText(elapsed))
                        }
                        if let tokens = model.activeTurn.tokenTotal {
                            Text("\(TokenActivityPresentation.tokenCount(tokens)) token")
                        }
                        if let error = model.activeTurn.errorMessage, !error.isEmpty {
                            Text(error)
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .padding(12)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            case .idle, .unknown:
                EmptyView()
            }
        }
    }

    private var quickActions: some View {
        HStack(spacing: 10) {
            Button {
                model.refresh()
            } label: {
                Label("重新整理", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Button {
                openCodex()
            } label: {
                Label("開啟 Codex", systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("軟體更新", systemImage: "arrow.down.circle")
                    .font(.headline)
                Spacer()
                updateStatusLabel
            }

            switch model.updateState {
            case .idle:
                Text("啟動後會檢查 GitHub Release。")
                    .font(.body)
                    .foregroundStyle(.secondary)
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在檢查 GitHub 更新…")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") { model.cancelUpdateCheck() }
                        .buttonStyle(.link)
                        .font(.subheadline)
                }
            case .upToDate:
                Text("目前已是最新版本。")
                    .font(.body)
                    .foregroundStyle(.green)
            case .available(let release):
                updateReleaseDetails(release)
                HStack(spacing: 8) {
                    Button("開啟 Release") { model.openUpdateReleasePage() }
                        .buttonStyle(.link)
                        .font(.subheadline)
                }
            case .error(let message):
                Text(message)
                    .font(.body)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("重試") { model.checkForUpdates() }
                        .buttonStyle(.link)
                        .font(.subheadline)
                    Button("開啟 GitHub") { model.openUpdateReleasePage() }
                        .buttonStyle(.link)
                        .font(.subheadline)
                }
            }
        }
    }

    @ViewBuilder
    private var updateStatusLabel: some View {
        switch model.updateState {
        case .checking:
            Text("處理中").font(.subheadline).foregroundStyle(.secondary)
        case .available:
            Text("有新版").font(.subheadline).foregroundStyle(.blue)
        case .upToDate:
            Text("最新").font(.subheadline).foregroundStyle(.green)
        case .error:
            Text("檢查失敗").font(.subheadline).foregroundStyle(.orange)
        case .idle:
            EmptyView()
        }
    }

    private func updateReleaseDetails(_ release: AppUpdateRelease) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("版本 \(release.version)")
                .font(.body.weight(.semibold))
            if let publishedAt = release.publishedAt {
                Text("發布：\(publishedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !release.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(release.notes)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var accountSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 3) {
                    ForEach(AccountScope.allCases) { scope in
                        Button {
                            guard model.accountScope != scope else { return }
                            model.setAccountScope(scope)
                        } label: {
                            Text(scope.title)
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 32)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(model.accountScope == scope ? Color.white : Color.primary)
                        .background(
                            model.accountScope == scope ? Color.accentColor : Color.clear,
                            in: Capsule()
                        )
                        .accessibilityAddTraits(model.accountScope == scope ? .isSelected : [])
                    }
                }
                .padding(3)
                .background(Color.secondary.opacity(0.12), in: Capsule())
                .frame(maxWidth: .infinity)
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
                            .font(.title3)
                            .frame(width: 32, height: 32)
                    }
                    .help("切換或建立本機 profile")
                }
                if model.accountScope == .current {
                    Text(model.accountHealthState.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if model.accountProfiles.contains(where: \.isUnidentified) {
                Text("未識別帳號不含穩定 Email，可能需要手動分開管理。")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
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
        VStack(alignment: .leading, spacing: 8) {
            Label("帳號管理", systemImage: "person.2")
                .font(.subheadline.weight(.semibold))
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

    private var tokenActivitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Token 歷史摘要")
                    .font(.headline)
                Spacer()
                Text(model.tokenActivityState.displayName)
                    .font(.caption)
                    .foregroundStyle(model.tokenActivityState == .loaded ? .green : .secondary)
            }
            if let activity = model.displayedTokenActivity {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                    metric(TokenActivityPresentation.lifetimeLabel, tokenCount(activity.lifetimeTokens))
                    metric(TokenActivityPresentation.peakLabel, tokenCount(activity.peakDailyTokens))
                    metric(TokenActivityPresentation.longestTurnLabel, durationText(activity.longestRunningTurnSec))
                    metric(TokenActivityPresentation.currentStreakLabel, daysText(activity.currentStreakDays))
                    metric(TokenActivityPresentation.longestStreakLabel, daysText(activity.longestStreakDays))
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
                Text("最後抓取：\(model.tokenActivityFetchedAt?.formatted(date: .abbreviated, time: .shortened) ?? "未知")\(model.tokenActivityIsStale ? " · 資料較舊" : "")")
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
        TokenActivityPresentation.tokenCount(value)
    }

    private func daysText(_ value: Int64?) -> String {
        TokenActivityPresentation.daysText(value)
    }

    private func durationText(_ value: Int64?) -> String {
        TokenActivityPresentation.durationText(value)
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
                Text("此區塊仍顯示目前帳號歷史；全部帳號的聚合摘要與每日 token 請查看本頁的帳號歷史摘要。")
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
        VStack(alignment: .leading, spacing: 8) {
            Label("通知設定", systemImage: "bell.badge")
                .font(.subheadline.weight(.semibold))
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
    }

    private var syncSettingsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("同步設定", systemImage: "arrow.triangle.2.circlepath")
                .font(.subheadline.weight(.semibold))
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
        if seconds < 60 { return "\(seconds) 秒" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) 分鐘" }
        return "\(minutes / 60) 小時"
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

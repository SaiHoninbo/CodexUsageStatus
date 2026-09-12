import SwiftUI

/// Overview owns the current-state composition and its account/quota helpers.
/// Historical Token detail remains isolated in History.
extension UsagePopoverView {
    private struct ExecutionGroup: Identifiable {
        let id: CodexExecutionScopeKey
        let title: String
        let isRepository: Bool
        let executions: [CodexExecutionProjection]
    }

    private var executionGroups: [ExecutionGroup] {
        let candidates = Dictionary(grouping: model.activeExecutions, by: \.scopeKey).map { key, rawExecutions in
            let executions = CodexExecutionProjectionPolicy.sorted(rawExecutions)
            return (key: key, title: executions.first?.groupName ?? "工作區身份未證明", isRepository: executions.first?.isRepository == true, executions: executions)
        }
        let titleCounts = Dictionary(grouping: candidates, by: { $0.title }).mapValues(\.count)
        var duplicateOrdinals: [String: Int] = [:]
        return candidates.sorted { lhs, rhs in
            if lhs.title != rhs.title {
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            let leftKey = scopeSortKey(lhs.key)
            let rightKey = scopeSortKey(rhs.key)
            return leftKey.localizedStandardCompare(rightKey) == .orderedAscending
        }.map { candidate in
            guard titleCounts[candidate.title, default: 0] > 1 else {
                return ExecutionGroup(id: candidate.key, title: candidate.title, isRepository: candidate.isRepository, executions: candidate.executions)
            }

            let ordinal = (duplicateOrdinals[candidate.title] ?? 0) + 1
            duplicateOrdinals[candidate.title] = ordinal
            let suffix: String
            if let workspace = candidate.executions.first?.workspaceDisplayName,
               !workspace.isEmpty,
               workspace != candidate.title {
                suffix = workspace
            } else if let digest = candidate.key.repositoryIdentityDigest,
                      !digest.isEmpty {
                suffix = String(digest.prefix(8))
            } else {
                suffix = "工作區 \(ordinal)"
            }
            return ExecutionGroup(
                id: candidate.key,
                title: "\(candidate.title) · \(suffix)",
                isRepository: candidate.isRepository,
                executions: candidate.executions
            )
        }
    }

    /// Sorting uses the opaque scope identity only for deterministic ordering;
    /// raw roots never reach the rendered title.
    private func scopeSortKey(_ key: CodexExecutionScopeKey) -> String {
        "\(key.profileID?.uuidString ?? "default")|\(key.normalizedPhysicalRootPath)|\(key.repositoryIdentityDigest ?? "")"
    }

    var overviewTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            overviewActionableAlertSummary
            overviewUpdateCard
            quotaSummarySection
            activeExecutionsSection
            overviewTurnActivity

            if model.resetCredits != nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Label("Reset Credit", systemImage: "ticket")
                            .font(.caption.weight(.semibold))
                        Spacer(minLength: 8)
                        Text("可用 \(model.resetCredits?.availableCount ?? 0) 張")
                            .font(.caption2)
                            .foregroundStyle(HUDColorPalette.secondaryText)
                    }
                    resetCreditSection
                }
                .padding(8)
                .background(HUDColorPalette.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(HUDColorPalette.border, lineWidth: 0.7) }
            }

            quickActions
        }
    }

    @ViewBuilder
    private var activeExecutionsSection: some View {
        if !model.activeExecutions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("執行中的 Codex", systemImage: "bolt.horizontal.circle")
                    .font(.subheadline.weight(.semibold))
                ForEach(executionGroups) { group in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Image(systemName: group.isRepository ? "folder.fill" : "rectangle.3.group")
                                .foregroundStyle(HUDColorPalette.sevenDay)
                            Text(group.title)
                                .font(.caption.weight(.semibold))
                            if group.executions.count > 1 {
                                Text("(\(group.executions.count))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(HUDColorPalette.tertiaryText)
                            }
                        }
                        ForEach(group.executions) { execution in
                            executionRow(execution)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(10)
            .background(HUDColorPalette.controlSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(HUDColorPalette.border, lineWidth: 0.7) }
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func executionRow(_ execution: CodexExecutionProjection) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            executionRowContent(execution, now: timeline.date)
        }
    }

    @ViewBuilder
    private func executionRowContent(_ execution: CodexExecutionProjection, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundStyle(HUDColorPalette.secondaryText)
                Text(execution.chatName ?? "Chat 名稱未取得")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("執行中")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(HUDColorPalette.sevenDay)
            }
            if let plan = execution.plan {
                let progress = TurnPlanProgressPolicy.make(from: plan)
                ProgressView(value: Double(progress.completedCount), total: Double(max(1, progress.totalCount)))
                    .tint(HUDColorPalette.sevenDay)
                Text(progress.compactText ?? "進度未知")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(HUDColorPalette.sevenDay)
                if let step = TurnPlanCodec.normalizedStepText(progress.currentStepText, maxLength: 96) {
                    Text("目前：\(step)")
                        .font(.caption2)
                        .foregroundStyle(HUDColorPalette.secondaryText)
                        .lineLimit(2)
                } else if progress.hasMultipleInProgress {
                    Text("目前：多個步驟進行中")
                        .font(.caption2)
                        .foregroundStyle(HUDColorPalette.secondaryText)
                }
                if progress.remainingStepCount == 1 {
                    Text("目前計畫剩 1 步")
                        .font(.caption2)
                        .foregroundStyle(HUDColorPalette.tertiaryText)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("進度未知")
                    .font(.caption2)
                    .foregroundStyle(HUDColorPalette.secondaryText)
            }
            if let estimate = model.estimatedExecution(for: execution, now: now) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(estimate.progressText)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(HUDColorPalette.warning)
                    if let uncertaintyText = estimate.uncertaintyText {
                        Text(uncertaintyText)
                            .font(.caption2)
                            .foregroundStyle(HUDColorPalette.tertiaryText)
                    }
                    HStack(spacing: 7) {
                        if let remainingText = estimate.remainingText {
                            Text(remainingText)
                        }
                        Text(estimate.confidenceText)
                    }
                    .font(.caption2)
                    .foregroundStyle(HUDColorPalette.tertiaryText)
                }
            } else {
                Text(model.executionEstimationHistoryReady
                    ? "本機耗時推估：估算建立中 · 資料不足"
                    : "本機耗時推估：估算建立中")
                    .font(.caption2)
                    .foregroundStyle(HUDColorPalette.tertiaryText)
            }
            HStack(spacing: 8) {
                Text(durationText(CodexExecutionProjectionPolicy.elapsedSeconds(startedAt: execution.startedAt, now: now)))
                if let tokens = execution.tokenTotal {
                    Text("\(TokenActivityPresentation.tokenCount(tokens)) token")
                }
            }
            .font(.caption2)
            .foregroundStyle(HUDColorPalette.tertiaryText)
        }
        .padding(.leading, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(execution.chatName ?? "Chat 名稱未取得")，執行中")
        .accessibilityValue(model.estimatedExecution(for: execution, now: now)?.accessibilityText ?? "本機耗時推估資料不足")
    }

    @ViewBuilder
    private var overviewActionableAlertSummary: some View {
        let alerts = model.currentSettingsAlerts
        if let primary = alerts.first {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: primary.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(primary.severity == .error ? HUDColorPalette.error : HUDColorPalette.warning)
                    Text("需要處理")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    if alerts.count > 1 {
                        Text("另有 " + String(alerts.count - 1) + " 項")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(HUDColorPalette.secondaryText)
                    }
                }
                Text(primary.title)
                    .font(.caption.weight(.semibold))
                Text(primary.message)
                    .font(.caption2)
                    .foregroundStyle(HUDColorPalette.secondaryText)
                    .lineLimit(2)
                HStack(spacing: 10) {
                    Button(primary.actionTitle ?? "開啟設定") {
                        handleOverviewAlert(primary)
                    }
                    .buttonStyle(PopoverImmediateButtonStyle())
                    .foregroundStyle(HUDColorPalette.sevenDay)
                    .font(.caption.weight(.semibold))
                    if alerts.count > 1 {
                        Text("設定頁可查看全部")
                            .font(.caption2)
                            .foregroundStyle(HUDColorPalette.tertiaryText)
                    }
                }
            }
            .padding(9)
            .background(HUDColorPalette.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(primary.severity == .error ? HUDColorPalette.error.opacity(0.45) : HUDColorPalette.warning.opacity(0.45), lineWidth: 0.8)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("需要處理")
            .accessibilityValue(primary.title + "，" + primary.message)
        }
    }

    private func handleOverviewAlert(_ alert: SettingsAlertPresentation) {
        guard let action = alert.action else { return }
        acknowledgeAction("已接受：" + alert.title, control: "overview.alert." + alert.id)
        PopoverInteractionTrace.started("overview.alert." + alert.id)
        switch action {
        case .accounts:
            selectionController.select(.accounts)
        case .accessibility:
            selectionController.selectSettings(section: .hud)
        case .notifications:
            selectionController.selectSettings(section: .notifications)
        case .update:
            selectionController.selectSettings(section: .update)
        case .refresh:
            model.refresh()
        }
    }

    @ViewBuilder
    private var overviewUpdateCard: some View {
        switch model.updateState {
        case .available(let release):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(HUDColorPalette.sevenDay)
                    Text("Codex Usage Status \(release.version) 可用")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                }
                if !release.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(release.notes)
                        .font(.caption2)
                        .foregroundStyle(HUDColorPalette.secondaryText)
                        .lineLimit(2)
                }
                HStack(spacing: 10) {
                    Button(AppUpdatePresentationPolicy.installButtonTitle) {
                        acknowledgeAction("正在下載並覆蓋更新", control: "overview.installUpdate")
                        PopoverInteractionTrace.started("overview.installUpdate")
                        model.installUpdate(release)
                    }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button(AppUpdatePresentationPolicy.releaseButtonTitle) {
                        acknowledgeAction("正在開啟更新內容", control: "overview.release")
                        PopoverInteractionTrace.started("overview.release")
                        model.openUpdateReleasePage()
                    }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .padding(9)
            .background(HUDColorPalette.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(HUDColorPalette.sevenDay.opacity(0.45), lineWidth: 0.8) }
        case .downloading(let release):
            updateInFlightCard(release: release, message: "正在下載官方 GitHub Release…")
        case .installing(let release):
            updateInFlightCard(release: release, message: "正在準備覆蓋並重新啟動…")
        case .error(let message):
            let alert = SettingsAlertPresentation.updateFailure(message: message)
            VStack(alignment: .leading, spacing: 6) {
                Label(alert.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HUDColorPalette.warning)
                Text(alert.message)
                    .font(.caption2)
                    .foregroundStyle(HUDColorPalette.secondaryText)
                    .lineLimit(2)
                HStack(spacing: 10) {
                    Button(alert.actionTitle ?? "重試") {
                        acknowledgeAction("已接受：重新檢查更新", control: "overview.retryUpdate")
                        PopoverInteractionTrace.started("overview.retryUpdate")
                        model.checkForUpdates()
                    }
                        .buttonStyle(.link)
                        .font(.caption)
                    Button("開啟 Release") {
                        acknowledgeAction("正在開啟 Release", control: "overview.release")
                        PopoverInteractionTrace.started("overview.release")
                        model.openUpdateReleasePage()
                    }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .padding(9)
            .background(HUDColorPalette.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(HUDColorPalette.warning.opacity(0.4), lineWidth: 0.8) }
        case .idle, .checking, .upToDate:
            EmptyView()
        }
    }

    private func updateInFlightCard(release: AppUpdateRelease, message: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Codex Usage Status \(release.version)")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(HUDColorPalette.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(HUDColorPalette.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(HUDColorPalette.sevenDay.opacity(0.45), lineWidth: 0.8) }
    }

    var overviewAccountControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Picker("檢視", selection: Binding(
                    get: { model.accountScope },
                    set: { model.setAccountScope($0) }
                )) {
                    ForEach(AccountScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("帳號範圍")
                .accessibilityHint("切換目前帳號或全部帳號")

                if model.accountScope == .current {
                    Menu {
                        ForEach(model.accountProfiles) { profile in
                            Button {
                                acknowledgeAction("正在切換帳號", control: "overview.switchAccount")
                                PopoverInteractionTrace.started("overview.switchAccount")
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
                        Button("新增受管帳號") {
                            acknowledgeAction("新增帳號已接受", control: "overview.createAccount")
                            PopoverInteractionTrace.started("overview.createAccount")
                            _ = model.createManagedProfile()
                        }
                    } label: {
                        Label("切換帳號", systemImage: "person.crop.circle.badge.plus")
                            .font(.caption.weight(.semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .help("切換或建立本機 profile")
                }

                if model.accountScope == .current {
                    Text(model.accountHealthState.displayName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(HUDColorPalette.secondaryText)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(HUDColorPalette.controlSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(HUDColorPalette.border, lineWidth: 0.7) }
            if model.accountProfiles.contains(where: \.isUnidentified) {
                Text("未識別帳號不含穩定 Email，可能需要手動分開管理。")
                    .font(.caption2)
                    .foregroundStyle(HUDColorPalette.warning)
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
                .foregroundStyle(HUDColorPalette.tertiaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var quotaSummarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("目前用量", systemImage: "chart.bar.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(model.accountScope == .current ? "目前帳號" : "全部帳號")
                    .font(.caption)
                    .foregroundStyle(HUDColorPalette.tertiaryText)
            }

            if model.accountScope == .current {
                let presentation = HUDQuotaPresentationPolicy.make(
                    snapshot: model.snapshot,
                    profileID: model.currentProfileID
                )
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    quotaSummaryRow(kind: .fiveHour, presentation: presentation?.fiveHour, accent: HUDColorPalette.fiveHour)
                    quotaSummaryRow(kind: .sevenDay, presentation: presentation?.sevenDay, accent: HUDColorPalette.sevenDay)
                    if let thirtyDay = presentation?.thirtyDay {
                        quotaSummaryRow(kind: .thirtyDay, presentation: thirtyDay, accent: HUDColorPalette.sevenDay)
                    }
                    if let reserve = presentation?.gptReserveWeekly {
                        quotaSummaryRow(kind: .gptReserveWeekly, presentation: reserve, accent: HUDColorPalette.gptReserveWeekly)
                    }
                }
            } else {
                let summary = model.accountScopeSummary
                if summary.totalAccounts == 0 {
                    compactEmptyState("尚未取得帳號用量。")
                } else {
                    HStack(spacing: 8) {
                        accountScopeMetric("帳號", summary.totalAccounts, color: HUDColorPalette.sevenDay)
                        accountScopeMetric("活躍", summary.availableOrActiveAccounts, color: HUDColorPalette.continueAction)
                        accountScopeMetric("較舊", summary.staleAccounts, color: HUDColorPalette.warning)
                        accountScopeMetric("未識別", summary.unidentifiedAccounts, color: HUDColorPalette.secondaryText)
                    }
                    allAccountsUsageRows
                    Button {
                        selectionController.select(.accounts)
                    } label: {
                        Label("前往帳號管理", systemImage: "arrow.right")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .buttonStyle(.link)
                    .font(.caption.weight(.semibold))
                    .accessibilityHint("前往帳號頁面的完整帳號管理")
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var allAccountsUsageRows: some View {
        let rows = allAccountsUsageRowPresentations
        return VStack(alignment: .leading, spacing: 6) {
            Text("帳號用量")
                .font(.caption.weight(.semibold))
                .foregroundStyle(HUDColorPalette.secondaryText)

            if rows.isEmpty {
                compactEmptyState("尚未取得各帳號的用量資料。")
            } else {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        allAccountsUsageRow(row)
                        if row.id != rows.last?.id {
                            Divider()
                                .overlay(HUDColorPalette.divider)
                        }
                    }
                }
                .padding(.horizontal, 9)
                .background(HUDColorPalette.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(HUDColorPalette.border, lineWidth: 0.7) }
            }
        }
    }

    private var allAccountsUsageRowPresentations: [AllAccountsUsageRowPresentation] {
        let summaries = Dictionary(uniqueKeysWithValues: model.profileQuotaSummaries().map { ($0.profile.id, $0) })
        return AllAccountsUsageRowPresentation.orderedProfiles(model.accountProfiles, currentProfileID: model.currentProfileID).map { profile in
            AllAccountsUsageRowPresentation.make(
                profile: profile,
                display: model.accountProfileDisplay(for: profile),
                summary: summaries[profile.id],
                currentProfileID: model.currentProfileID,
                currentConnectionState: model.connectionState,
                currentSnapshotAvailable: model.snapshot != nil,
                currentSnapshotIsStale: model.isStale,
                currentRemainingPercent: model.menuBarRemainingPercent,
                now: model.currentDate,
                localActivity: model.localProfileActivity(for: profile),
                observedTokenDelta: model.localObservedTokenDelta(for: profile)
            )
        }
    }

    private func allAccountsUsageRow(_ row: AllAccountsUsageRowPresentation) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: row.isCurrent ? "checkmark.circle.fill" : (row.isWarning ? "exclamationmark.triangle.fill" : "person.crop.circle"))
                .foregroundStyle(allAccountsUsageRowColor(row))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(row.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if row.isCurrent {
                        Text("目前")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(HUDColorPalette.continueAction)
                    }
                }
                Text(row.subtitle.isEmpty ? row.freshnessText : "\(row.subtitle) · \(row.freshnessText)")
                    .font(.caption2)
                    .foregroundStyle(HUDColorPalette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(row.activityText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(allAccountsActivityColor(row.activityState))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(1)

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 3) {
                Text(row.remainingPercent.map { "\($0)%" } ?? "—")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(allAccountsUsageRowColor(row))
                if !row.isCurrent {
                    Button("切換並刷新") {
                        acknowledgeAction("正在切換並刷新", control: "overview.switchAndRefresh")
                        PopoverInteractionTrace.started("overview.switchAndRefresh")
                        model.selectProfile(id: row.profileID)
                        model.setAccountScope(.current)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(HUDColorPalette.sevenDay)
                    .fixedSize()
                    .accessibilityLabel("切換到 \(row.title) 並刷新")
                }
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .contain)
    }

    private func allAccountsUsageRowColor(_ row: AllAccountsUsageRowPresentation) -> Color {
        switch row.state {
        case .currentLive: return HUDColorPalette.continueAction
        case .cached: return HUDColorPalette.sevenDay
        case .stale: return HUDColorPalette.warning
        case .unavailable: return HUDColorPalette.tertiaryText
        }
    }

    private func allAccountsActivityColor(_ state: AllAccountsLocalActivityState) -> Color {
        switch state {
        case .currentLive: return HUDColorPalette.continueAction
        case .cached: return HUDColorPalette.sevenDay
        case .stale: return HUDColorPalette.warning
        case .noData: return HUDColorPalette.tertiaryText
        }
    }

    private func accountScopeMetric(_ label: String, _ value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(HUDColorPalette.tertiaryText)
            Text("\(value)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func compactEmptyState(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(HUDColorPalette.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }

    @ViewBuilder
    private func quotaSummaryRow(kind: HUDQuotaWindowKind, presentation: HUDQuotaWindowPresentation?, accent: Color) -> some View {
        if let presentation {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(presentation.label)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(presentation.remainingPercent)%")
                        .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(accent)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(HUDColorPalette.controlSurface)
                        Capsule(style: .continuous)
                            .fill(accent.opacity(0.78))
                            .frame(width: max(4, proxy.size.width * CGFloat(presentation.remainingPercent) / 100))
                    }
                }
                .frame(height: 3)
                Text("重置 \(presentation.resetDescription)")
                    .font(.caption2)
                    .foregroundStyle(HUDColorPalette.tertiaryText)
            }
            .padding(9)
            .background(HUDColorPalette.controlSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(accent.opacity(0.34), lineWidth: 0.7) }
        } else {
            HStack {
                Text(kind.label).font(.caption.weight(.semibold))
                Spacer()
            }
            .padding(9)
            .background(HUDColorPalette.controlSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    @ViewBuilder
    var overviewTurnActivity: some View {
        if model.accountScope != .current || !model.activeExecutions.isEmpty {
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
                            .foregroundStyle(model.activeTurn.state == .active ? HUDColorPalette.sevenDay : (model.activeTurn.state == .failed ? HUDColorPalette.warning : HUDColorPalette.secondaryText))
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
                                .foregroundStyle(HUDColorPalette.warning)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    .foregroundStyle(HUDColorPalette.secondaryText)
                    .lineLimit(1)
                    if let planText = model.activeTurnPlanProgress.compactText {
                        Text(planText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HUDColorPalette.sevenDay)
                        if let currentStep = model.activeTurnPlanProgress.currentStepText,
                           let normalized = TurnPlanCodec.normalizedStepText(currentStep) {
                            Text("目前：\(normalized)")
                                .font(.caption2)
                                .foregroundStyle(HUDColorPalette.secondaryText)
                                .lineLimit(1)
                        } else if model.activeTurnPlanProgress.hasMultipleInProgress {
                            Text("目前：多個步驟進行中")
                                .font(.caption2)
                                .foregroundStyle(HUDColorPalette.secondaryText)
                                .lineLimit(1)
                        }
                        if let remaining = model.activeTurnPlanProgress.remainingStepCount, remaining == 1 {
                            Text("目前計畫剩 1 步")
                                .font(.caption2)
                                .foregroundStyle(HUDColorPalette.tertiaryText)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(10)
                .background(HUDColorPalette.controlSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(HUDColorPalette.border, lineWidth: 0.7) }
            case .idle, .unknown:
                EmptyView()
            }
        }
    }

    var quickActions: some View {
        HStack(spacing: 8) {
            Button {
                acknowledgeAction("重新整理已接受", control: "overview.refresh")
                PopoverInteractionTrace.started("overview.refresh")
                model.refresh()
            } label: {
                Label("重新整理", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                acknowledgeAction("正在開啟 Codex", control: "overview.openCodex")
                PopoverInteractionTrace.started("overview.openCodex")
                openCodex()
            } label: {
                Label("開啟 Codex", systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    var resetCreditSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.accountScope == .all {
                Text("請切回目前帳號後操作；不會在全部帳號模式消耗 credit。")
                    .font(.caption)
                    .foregroundStyle(HUDColorPalette.tertiaryText)
            }
            if let credits = model.resetCredits, credits.availableCount > 0 {
                let details = HUDResetCreditSelectionPolicy.ordered(
                    credits.availableCredits,
                    now: model.currentDate
                )
                let fastestID = HUDResetCreditSelectionPolicy.fastestExpiryID(
                    in: details,
                    now: model.currentDate
                )
                if !details.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(details.enumerated()), id: \.element.id) { index, credit in
                            Button {
                                acknowledgeAction("Reset Credit 選擇已接受", control: "resetCredit.selection")
                                PopoverInteractionTrace.started("resetCredit.selection")
                                model.selectResetCredit(id: credit.id)
                            } label: {
                                resetCreditDetailRow(
                                    credit,
                                    index: index,
                                    isFastest: credit.id == fastestID,
                                    isSelected: credit.id == model.selectedResetCreditID
                                )
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            if credit.id != details.last?.id {
                                Divider()
                                    .overlay(HUDColorPalette.divider)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .background(HUDColorPalette.controlSurface.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(HUDColorPalette.border, lineWidth: 0.7)
                    }

                    HStack(spacing: 8) {
                        if let selected = model.selectedResetCredit {
                            Label(
                                "已選：\(selected.title ?? "Reset credit")",
                                systemImage: "checkmark.circle.fill"
                            )
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(HUDColorPalette.secondaryText)
                            .lineLimit(1)
                        } else {
                            Text("請點選一張 Reset credit")
                                .font(.caption2)
                                .foregroundStyle(HUDColorPalette.tertiaryText)
                        }
                        Spacer(minLength: 6)
                        Button(model.resetCreditOperationState == .consuming ? "使用中…" : "使用重置") {
                            acknowledgeAction("已開啟 Reset Credit 確認", control: "resetCredit.confirmation")
                            PopoverInteractionTrace.started("resetCredit.confirmation")
                            showResetCreditConfirmation = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(
                            model.accountScope == .all ||
                            model.selectedResetCredit == nil ||
                            model.resetCreditOperationState == .consuming ||
                            model.resetCreditOperationState == .unknown
                        )
                    }
                    .padding(.top, 4)
                } else {
                    Text("服務只回傳可用數量，尚未提供可安全選擇的 credit 詳細資料。請稍後 Refresh。")
                        .font(.caption)
                        .foregroundStyle(HUDColorPalette.tertiaryText)
                }
            } else {
                Text(model.resetCredits == nil ? "尚未取得 Reset credit 資料。" : "目前沒有可用的 Reset credit。")
                    .font(.caption)
                    .foregroundStyle(HUDColorPalette.tertiaryText)
            }
            if let message = model.resetCreditMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(model.resetCreditOperationState == .error ? HUDColorPalette.warning : HUDColorPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func resetCreditDetailRow(
        _ credit: RateLimitResetCredit,
        index: Int,
        isFastest: Bool,
        isSelected: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 6) {
                    Text(credit.title ?? "Reset credit \(index + 1)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HUDColorPalette.primaryText)
                        .lineLimit(1)
                    if isFastest {
                        Text("最快到期")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(HUDColorPalette.verificationAction)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(HUDColorPalette.verificationAction.opacity(0.14), in: Capsule())
                    }
                }
                Spacer(minLength: 6)
                Text(HUDResetCreditCountdownPolicy.text(
                    expiresAt: credit.expiresAt,
                    now: model.currentDate
                ))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(resetCreditCountdownColor(credit.expiresAt))
                .monospacedDigit()
                .lineLimit(1)
            }
            Text("Bucket：\(credit.resetType ?? "未知") · 到期：\(creditDate(credit.expiresAt))")
                .font(.caption2)
                .foregroundStyle(HUDColorPalette.secondaryText)
            if let description = credit.description, !description.isEmpty {
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(HUDColorPalette.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .overlay(alignment: .leading) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isSelected ? HUDColorPalette.verificationAction : HUDColorPalette.tertiaryText)
        }
        .padding(.leading, 18)
        .padding(.vertical, 7)
        .background(
            isSelected ? HUDColorPalette.verificationAction.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
    }

    private func resetCreditCountdownColor(_ expiresAt: Int64?) -> Color {
        guard let expiresAt else { return HUDColorPalette.tertiaryText }
        return TimeInterval(expiresAt) <= model.currentDate.timeIntervalSince1970
            ? HUDColorPalette.warning
            : HUDColorPalette.verificationAction
    }
}

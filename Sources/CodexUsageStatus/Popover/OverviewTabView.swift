import SwiftUI

private enum PopoverQuotaLayout {
    /// Both available and unavailable quota states occupy the same compact
    /// card contract. Without this shared floor, a missing 5-hour window
    /// collapses to a short label row while the adjacent 7-day card retains
    /// its progress content, leaving an asymmetric blank region in the grid.
    static let cardMinimumHeight: CGFloat = 64
}

/// Overview owns the current-state composition and its account/quota helpers.
/// Historical Token detail remains isolated in History.
extension UsagePopoverView {
    private struct ExecutionGroup: Identifiable {
        let id: CodexExecutionKey
        let title: String
        let isRepository: Bool
        let primary: CodexExecutionProjection
        let children: [CodexExecutionProjection]
    }

    private var executionGroups: [ExecutionGroup] {
        CodexActiveWorkPresentationPolicy.groups(for: model.activeExecutions).map {
            ExecutionGroup(
                id: $0.id,
                title: $0.primary.groupName,
                isRepository: $0.primary.isRepository,
                primary: $0.primary,
                children: $0.children
            )
        }
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
                            if !group.children.isEmpty {
                                Button {
                                    if expandedActiveWorkKeys.contains(group.id) {
                                        expandedActiveWorkKeys.remove(group.id)
                                    } else {
                                        expandedActiveWorkKeys.insert(group.id)
                                    }
                                } label: {
                                    Label("\(group.children.count) 個代理執行中", systemImage: expandedActiveWorkKeys.contains(group.id) ? "chevron.down" : "chevron.right")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(HUDColorPalette.secondaryText)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        executionRow(group.primary)
                        if expandedActiveWorkKeys.contains(group.id) {
                            ForEach(group.children) { execution in
                                executionRow(execution, isChild: true)
                            }
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
        executionRow(execution, isChild: false)
    }

    @ViewBuilder
    private func executionRow(_ execution: CodexExecutionProjection, isChild: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            executionRowContent(execution, now: timeline.date, isChild: isChild)
        }
    }

    @ViewBuilder
    private func executionRowContent(_ execution: CodexExecutionProjection, now: Date, isChild: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: isChild ? "person.2" : "bubble.left.and.bubble.right")
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
        .padding(.leading, isChild ? 26 : 8)
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
            PopoverInteractionTrace.effectDispatched("overview.alert." + alert.id)
            PopoverInteractionTrace.effectCompleted("overview.alert." + alert.id, success: true)
        case .accessibility:
            selectionController.selectSettings(section: .hud)
            PopoverInteractionTrace.effectDispatched("overview.alert." + alert.id)
            PopoverInteractionTrace.effectCompleted("overview.alert." + alert.id, success: true)
        case .notifications:
            selectionController.selectSettings(section: .notifications)
            PopoverInteractionTrace.effectDispatched("overview.alert." + alert.id)
            PopoverInteractionTrace.effectCompleted("overview.alert." + alert.id, success: true)
        case .update:
            selectionController.selectSettings(section: .update)
            PopoverInteractionTrace.effectDispatched("overview.alert." + alert.id)
            PopoverInteractionTrace.effectCompleted("overview.alert." + alert.id, success: true)
        case .refresh:
            PopoverInteractionTrace.effectDispatched("overview.alert." + alert.id)
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
                        PopoverInteractionTrace.effectDispatched("overview.installUpdate")
                        model.installUpdate(release)
                    }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .popoverControlPressProbe("overview.installUpdate")
                    Button(AppUpdatePresentationPolicy.releaseButtonTitle) {
                        acknowledgeAction("正在開啟更新內容", control: "overview.release")
                        PopoverInteractionTrace.started("overview.release")
                        PopoverInteractionTrace.effectDispatched("overview.release")
                        model.openUpdateReleasePage()
                    }
                        .buttonStyle(.link)
                        .font(.caption)
                        .popoverControlPressProbe("overview.release")
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
                        PopoverInteractionTrace.effectDispatched("overview.retryUpdate")
                        model.checkForUpdates { success in
                            PopoverInteractionTrace.effectCompleted("overview.retryUpdate", success: success)
                        }
                    }
                        .buttonStyle(.link)
                        .font(.caption)
                        .popoverControlPressProbe("overview.retryUpdate")
                    Button("開啟 Release") {
                        acknowledgeAction("正在開啟 Release", control: "overview.release")
                        PopoverInteractionTrace.started("overview.release")
                        PopoverInteractionTrace.effectDispatched("overview.release")
                        model.openUpdateReleasePage()
                    }
                        .buttonStyle(.link)
                        .font(.caption)
                        .popoverControlPressProbe("overview.release")
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

    var quotaSummarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("目前用量", systemImage: "chart.bar.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text("目前帳號")
                    .font(.caption)
                    .foregroundStyle(HUDColorPalette.tertiaryText)
            }

            let presentation = HUDQuotaPresentationPolicy.make(
                snapshot: model.snapshot,
                profileID: model.currentProfileID
            )
            if ColdOpenPresentationPolicy.shouldShowLoadingState(hasSnapshot: model.snapshot != nil) {
                quotaLoadingCard
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    quotaSummaryRow(
                        kind: .fiveHour,
                        presentation: presentation?.fiveHour,
                        availability: HUDQuotaPresentationPolicy.availability(
                            for: .fiveHour,
                            snapshot: model.snapshot,
                            presentation: presentation
                        ),
                        accent: HUDColorPalette.fiveHour
                    )
                    quotaSummaryRow(
                        kind: .sevenDay,
                        presentation: presentation?.sevenDay,
                        availability: HUDQuotaPresentationPolicy.availability(
                            for: .sevenDay,
                            snapshot: model.snapshot,
                            presentation: presentation
                        ),
                        accent: HUDColorPalette.sevenDay
                    )
                    if let thirtyDay = presentation?.thirtyDay {
                        quotaSummaryRow(
                            kind: .thirtyDay,
                            presentation: thirtyDay,
                            availability: .available,
                            accent: HUDColorPalette.sevenDay
                        )
                    }
                    if let reserve = presentation?.gptReserveWeekly {
                        quotaSummaryRow(
                            kind: .gptReserveWeekly,
                            presentation: reserve,
                            availability: .available,
                            accent: HUDColorPalette.gptReserveWeekly
                        )
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var quotaLoadingCard: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(HUDColorPalette.sevenDay)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(ColdOpenPresentationPolicy.loadingTitle)
                    .font(.subheadline.weight(.semibold))
                Text(ColdOpenPresentationPolicy.loadingDetail)
                    .font(.caption2)
                    .foregroundStyle(HUDColorPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        // Match the two-card quota grid (two 64pt cards plus its gap) so the
        // fresh snapshot can replace this state without a cold-open jump.
        .frame(
            maxWidth: .infinity,
            minHeight: (PopoverQuotaLayout.cardMinimumHeight * 2) + 8,
            alignment: .leading
        )
        .background(HUDColorPalette.controlSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(HUDColorPalette.sevenDay.opacity(0.34), lineWidth: 0.7)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ColdOpenPresentationPolicy.loadingTitle)
        .accessibilityValue(ColdOpenPresentationPolicy.loadingDetail)
    }

    @ViewBuilder
    private func quotaSummaryRow(
        kind: HUDQuotaWindowKind,
        presentation: HUDQuotaWindowPresentation?,
        availability: HUDQuotaWindowAvailability,
        accent: Color
    ) -> some View {
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
            .frame(
                maxWidth: .infinity,
                minHeight: PopoverQuotaLayout.cardMinimumHeight,
                alignment: .topLeading
            )
            .background(HUDColorPalette.controlSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(accent.opacity(0.34), lineWidth: 0.7) }
        } else {
            HStack {
                Text(kind.label).font(.caption.weight(.semibold))
                Spacer()
                if !availability.displayText.isEmpty {
                    Text(availability.displayText)
                        .font(.caption2)
                        .foregroundStyle(HUDColorPalette.tertiaryText)
                }
            }
            .padding(9)
            .frame(
                maxWidth: .infinity,
                minHeight: PopoverQuotaLayout.cardMinimumHeight,
                alignment: .leading
            )
            .background(HUDColorPalette.controlSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    @ViewBuilder
    var overviewTurnActivity: some View {
        if !model.activeExecutions.isEmpty {
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
                PopoverInteractionTrace.effectDispatched("overview.refresh")
                model.refresh()
            } label: {
                Label("重新整理", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .popoverControlPressProbe("overview.refresh")

            Button {
                acknowledgeAction("正在開啟 Codex", control: "overview.openCodex")
                PopoverInteractionTrace.started("overview.openCodex")
                PopoverInteractionTrace.effectDispatched("overview.openCodex")
                openCodex()
            } label: {
                Label("開啟 Codex", systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .popoverControlPressProbe("overview.openCodex")

            Button {
                PopoverInteractionTrace.accepted("overview.quit")
                PopoverInteractionTrace.effectDispatched("overview.quit")
                quit()
            } label: {
                Label("關閉", systemImage: "power")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .popoverControlPressProbe("overview.quit")
        }
    }

    var resetCreditSection: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                                PopoverInteractionTrace.effectDispatched("resetCredit.selection")
                                PopoverInteractionTrace.effectCompleted("resetCredit.selection", success: true)
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
                            .popoverControlPressProbe("resetCredit.selection")
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
                            PopoverInteractionTrace.effectDispatched("resetCredit.confirmation")
                            showResetCreditConfirmation = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .popoverControlPressProbe("resetCredit.confirmation")
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
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isSelected ? HUDColorPalette.verificationAction : HUDColorPalette.tertiaryText)
                .frame(width: 18, alignment: .center)
                .padding(.top, 1)
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
                Text("Bucket：\(resetCreditBucketName(credit.resetType)) · 到期：\(creditDate(credit.expiresAt))")
                    .font(.caption2)
                    .foregroundStyle(HUDColorPalette.secondaryText)
            }
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func resetCreditBucketName(_ rawValue: String?) -> String {
        guard let rawValue else { return "未知配額" }
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        guard !normalized.isEmpty else { return "未知配額" }

        switch normalized {
        case "primary", "main", "five_hour", "5_hour", "5h", "fivehour":
            return "5 小時配額"
        case "secondary", "weekly", "seven_day", "7_day", "7d", "sevenday":
            return "每週配額"
        case "monthly", "thirty_day", "30_day", "30d", "thirtyday":
            return "每月配額"
        case "gpt_reserve_weekly", "gptreserveweekly":
            return "GPT Reserve 每週配額"
        default:
            let fallback = normalized
                .split(separator: "_", omittingEmptySubsequences: true)
                .map(String.init)
                .joined(separator: " ")
            return fallback.isEmpty ? "未知配額" : fallback
        }
    }
}

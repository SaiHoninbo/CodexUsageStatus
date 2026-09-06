import SwiftUI

/// Overview owns the current-state composition and its account/quota helpers.
/// Historical Token detail remains isolated in History.
extension UsagePopoverView {
    var overviewTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            quotaSummarySection
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
                now: model.currentDate
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
            }
            .layoutPriority(1)

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 3) {
                Text(row.remainingPercent.map { "\($0)%" } ?? "—")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(allAccountsUsageRowColor(row))
                if !row.isCurrent {
                    Button("切換並刷新") {
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
                model.refresh()
            } label: {
                Label("重新整理", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
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
                let details = credits.availableCredits
                if !details.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(details.enumerated()), id: \.element.id) { index, credit in
                            resetCreditDetailRow(credit, index: index)
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

                    Picker("選擇 credit", selection: Binding(
                        get: { model.selectedResetCreditID ?? "" },
                        set: { model.selectResetCredit(id: $0.isEmpty ? nil : $0) }
                    )) {
                        Text("請選擇…").tag("")
                        ForEach(Array(details.enumerated()), id: \.element.id) { index, credit in
                            Text(credit.title ?? "Reset credit \(index + 1)").tag(credit.id)
                        }
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

    private func resetCreditDetailRow(_ credit: RateLimitResetCredit, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(credit.title ?? "Reset credit \(index + 1)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HUDColorPalette.primaryText)
                    .lineLimit(1)
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
        .padding(.vertical, 7)
    }

    private func resetCreditCountdownColor(_ expiresAt: Int64?) -> Color {
        guard let expiresAt else { return HUDColorPalette.tertiaryText }
        return TimeInterval(expiresAt) <= model.currentDate.timeIntervalSince1970
            ? HUDColorPalette.warning
            : HUDColorPalette.verificationAction
    }
}

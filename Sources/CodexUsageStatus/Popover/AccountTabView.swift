import SwiftUI

/// Full account management is a secondary surface. Overview keeps the compact
/// switcher for daily use, while this surface owns the complete profile list.
extension UsagePopoverView {
    var accountsTab: some View {
        let rows = accountTabRows
        let currentRows = rows.filter(\.isCurrent)
        let attentionRows = rows.filter { row in
            !row.isCurrent && (row.isWarning || row.state == .stale || row.state == .unavailable || model.loginStates[row.profileID] != nil)
        }
        let recentRows = rows
            .filter { !$0.isCurrent }
            .sorted { (lastSeen[$0.profileID] ?? .distantPast) > (lastSeen[$1.profileID] ?? .distantPast) }
            .prefix(3)
            .map { $0 }

        return VStack(alignment: .leading, spacing: 9) {
            accountTabHeader
            accountTabActions

            if model.accountProfiles.isEmpty {
                Text("尚未建立帳號 profile。")
                    .font(.caption)
                    .foregroundStyle(HUDColorPalette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(HUDColorPalette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                accountManagementSummary(currentRows: currentRows, attentionRows: attentionRows, recentRows: recentRows, allRows: rows)
                accountManagementSection("目前帳號", rows: currentRows)
                if !attentionRows.isEmpty {
                    accountManagementSection("需要處理", rows: attentionRows)
                }
                if !recentRows.isEmpty {
                    accountManagementSection("最近使用", rows: recentRows, compact: true)
                }
                accountManagementSection("全部帳號", rows: rows, lazy: true)
            }

            Text("每個帳號使用獨立 CODEX_HOME 與 App Server；切換不會改動系統 ~/.codex。")
                .font(.caption2)
                .foregroundStyle(HUDColorPalette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accountTabHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Label("帳號與連線", systemImage: "person.2")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Button {
                    acknowledgeAction("已返回概覽", control: "accounts.backToOverview")
                    PopoverInteractionTrace.started("accounts.backToOverview")
                    selectionController.select(.overview)
                } label: {
                    Label("返回概覽", systemImage: "chevron.left")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(PopoverImmediateButtonStyle(controlID: "accounts.backToOverview"))
                .accessibilityLabel("返回概覽")
                Text(model.accountHealthState.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(model.accountHealthState == .loaded ? HUDColorPalette.continueAction : HUDColorPalette.secondaryText)
            }
            Text("目前帳號：\(model.accountDisplayName)")
                .font(.caption)
                .foregroundStyle(HUDColorPalette.secondaryText)
            if let error = model.accountHealthErrorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(HUDColorPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(HUDColorPalette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(HUDColorPalette.border, lineWidth: 0.7) }
    }

    private func accountManagementSummary(
        currentRows: [AllAccountsUsageRowPresentation],
        attentionRows: [AllAccountsUsageRowPresentation],
        recentRows: [AllAccountsUsageRowPresentation],
        allRows: [AllAccountsUsageRowPresentation]
    ) -> some View {
        HStack(spacing: 6) {
            accountManagementMetric("目前帳號", currentRows.count)
            accountManagementMetric("需要處理", attentionRows.count)
            accountManagementMetric("最近使用", recentRows.count)
            accountManagementMetric("全部帳號", allRows.count)
        }
        .padding(.horizontal, 2)
    }

    private func accountManagementMetric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(HUDColorPalette.tertiaryText)
                .lineLimit(1)
            Text("\(value)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(HUDColorPalette.primaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(HUDColorPalette.controlSurface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var lastSeen: [UUID: Date] {
        let lastSeen = Dictionary(uniqueKeysWithValues: model.accountProfiles.map { ($0.id, $0.lastSeen) })
        return lastSeen
    }

    @ViewBuilder
    private func accountManagementSection(
        _ title: String,
        rows: [AllAccountsUsageRowPresentation],
        compact: Bool = false,
        lazy: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(HUDColorPalette.secondaryText)
            if lazy {
                LazyVStack(alignment: .leading, spacing: 0) {
                    accountManagementRows(rows, compact: compact)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    accountManagementRows(rows, compact: compact)
                }
            }
        }
        .padding(.horizontal, 10)
        .background(HUDColorPalette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(HUDColorPalette.border, lineWidth: 0.7) }
    }

    @ViewBuilder
    private func accountManagementRows(
        _ rows: [AllAccountsUsageRowPresentation],
        compact: Bool
    ) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            accountTabRow(row, compact: compact)
            if index < rows.count - 1 {
                Divider().overlay(HUDColorPalette.divider)
            }
        }
    }

    private var accountTabActions: some View {
        HStack(spacing: 8) {
            Button {
                acknowledgeAction("新增帳號已接受", control: "accounts.create")
                PopoverInteractionTrace.started("accounts.create")
                _ = model.createManagedProfile()
            } label: {
                Label("新增帳號", systemImage: "person.badge.plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                acknowledgeAction("匯入已接受", control: "accounts.import")
                PopoverInteractionTrace.started("accounts.import")
                model.importProfileForCurrentAccount()
            } label: {
                Label("匯入 Codex profile", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var accountTabRows: [AllAccountsUsageRowPresentation] {
        let summaries = Dictionary(uniqueKeysWithValues: model.profileQuotaSummaries().map { ($0.profile.id, $0) })
        return AllAccountsUsageRowPresentation.orderedProfiles(
            model.accountProfiles,
            currentProfileID: model.currentProfileID
        ).map { profile in
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

    private func accountTabRow(_ row: AllAccountsUsageRowPresentation, compact: Bool = false) -> some View {
        let profile = model.accountProfiles.first(where: { $0.id == row.profileID })
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: row.isCurrent ? "checkmark.circle.fill" : (row.isWarning ? "exclamationmark.triangle.fill" : "person.crop.circle"))
                .foregroundStyle(accountTabRowColor(row))
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
                if !compact {
                    Text(row.activityText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(accountActivityColor(row.activityState))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let profile, let loginState = model.loginStates[profile.id] {
                    Text(loginState)
                        .font(.caption2)
                        .foregroundStyle(loginStateColor(loginState))
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 4) {
                Text(row.remainingPercent.map { "\($0)%" } ?? "—")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(accountTabRowColor(row))
                if !row.isCurrent {
                    Button("切換並刷新") {
                        acknowledgeAction("正在切換並刷新", control: "accounts.switch")
                        PopoverInteractionTrace.started("accounts.switch")
                        model.selectProfile(id: row.profileID)
                        model.setAccountScope(.current)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(HUDColorPalette.sevenDay)
                    .fixedSize()
                }
                if let profile, profile.isManaged {
                    HStack(spacing: 6) {
                        Button("登入") {
                            acknowledgeAction("登入已接受", control: "accounts.login")
                            PopoverInteractionTrace.started("accounts.login")
                            model.startOfficialLogin(for: profile.id)
                        }
                            .buttonStyle(.link)
                            .font(.caption2)
                            .disabled(model.loginStates[profile.id]?.hasPrefix("正在") == true)
                        Button(role: .destructive) {
                            PopoverInteractionTrace.accepted("accounts.remove")
                            profilePendingRemoval = profile
                            showRemoveProfileConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .help("刪除受管帳號")
                    }
                }
            }
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
    }

    private func accountTabRowColor(_ row: AllAccountsUsageRowPresentation) -> Color {
        switch row.state {
        case .currentLive: return HUDColorPalette.continueAction
        case .cached: return HUDColorPalette.sevenDay
        case .stale: return HUDColorPalette.warning
        case .unavailable: return HUDColorPalette.tertiaryText
        }
    }

    private func accountActivityColor(_ state: AllAccountsLocalActivityState) -> Color {
        switch state {
        case .currentLive: return HUDColorPalette.continueAction
        case .cached: return HUDColorPalette.sevenDay
        case .stale: return HUDColorPalette.warning
        case .noData: return HUDColorPalette.tertiaryText
        }
    }

    private func loginStateColor(_ state: String) -> Color {
        let normalized = state.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.contains("失敗") || normalized.contains("錯誤") || normalized.contains("找不到")
            ? HUDColorPalette.warning
            : HUDColorPalette.secondaryText
    }
}

import SwiftUI

/// Full account management lives in its own tab. Overview keeps the compact
/// switcher for daily use, while this surface owns the complete profile list.
extension UsagePopoverView {
    var accountsTab: some View {
        VStack(alignment: .leading, spacing: 9) {
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
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(accountTabRows) { row in
                        accountTabRow(row)
                        if row.id != accountTabRows.last?.id {
                            Divider().overlay(HUDColorPalette.divider)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .background(HUDColorPalette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(HUDColorPalette.border, lineWidth: 0.7) }
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

    private func accountTabRow(_ row: AllAccountsUsageRowPresentation) -> some View {
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
                Text(row.activityText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(accountActivityColor(row.activityState))
                    .lineLimit(1)
                    .truncationMode(.tail)
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

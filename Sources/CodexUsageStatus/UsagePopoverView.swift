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

    @State var showClearHistoryConfirmation = false
    @State var showResetCreditConfirmation = false
    @State var showRemoveProfileConfirmation = false
    @State var profilePendingRemoval: AccountProfile?
    @State var measuredContentHeight: CGFloat = 0
    // Disclosure is presentation-only state. It intentionally lives in the
    // view tree rather than UserDefaults so the compact Settings surface does
    // not introduce a new persistent product preference.
    @State var isNotificationsExpanded = false
    @State var isHUDExpanded = false
    @State var isSyncExpanded = false
    @State var isUpdateExpanded = false
    @State var isMetadataExpanded = false
    // Full account management is intentionally collapsed on entry. This is
    // view-local presentation state; account authority remains in the model.
    @State var isAllAccountsExpanded = false
    @State var expandedActiveWorkKeys: Set<CodexExecutionKey> = []
    @State private var autoExpandedUpdateVersion: String?
    @State var actionAcknowledgement: String?
    @State var actionAcknowledgementToken = UUID()

    var selectedTab: UsagePopoverTab { selectionController.selectedTab }

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
        .background(.regularMaterial)
        .preferredColorScheme(.dark)
        // Feedback is deliberately an overlay.  Inserting it into the
        // content VStack changes the measured height and makes AppKit resize
        // the popover on every click, which feels like a missed/slow action.
        .overlay(alignment: .topTrailing) {
            actionAcknowledgementView
                .padding(.top, 8)
                .padding(.trailing, 20)
                .allowsHitTesting(false)
        }
        .onPreferenceChange(PopoverContentHeightPreferenceKey.self) { height in
            guard height > 0, abs(height - measuredContentHeight) > 0.5 else { return }
            measuredContentHeight = height
            onContentHeightChange?(height)
        }
        .onChange(of: selectionController.requestGeneration) { _, _ in
            applyPendingSettingsSection()
        }
        .onChange(of: selectionController.selectedTab) { _, tab in
            if tab == .overview, model.accountScope != .current {
                model.setAccountScope(.current)
            }
            DispatchQueue.main.async {
                PopoverInteractionTrace.firstContentVisible("tab.\(tab.rawValue)")
            }
        }
        .onAppear {
            if selectedTab == .overview, model.accountScope != .current {
                model.setAccountScope(.current)
            }
            syncUpdateDisclosure(with: model.updateState)
        }
        .onChange(of: model.updateState) { _, newState in
            syncUpdateDisclosure(with: newState)
        }
        .alert("清除本機歷史？", isPresented: $showClearHistoryConfirmation) {
            Button("清除", role: .destructive) {
                PopoverInteractionTrace.accepted("history.clear")
                PopoverInteractionTrace.effectDispatched("history.clear")
                model.clearHistory()
                PopoverInteractionTrace.effectCompleted("history.clear", success: true)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("這會刪除最近 30 天的用量時間序列，不會影響 Codex 或登入狀態。")
        }
        .alert("確認使用 Reset Credit？", isPresented: $showResetCreditConfirmation) {
            Button("確認使用", role: .destructive) {
                PopoverInteractionTrace.accepted("resetCredit.consume")
                PopoverInteractionTrace.effectDispatched("resetCredit.consume")
                model.consumeSelectedResetCredit()
            }
            Button("取消", role: .cancel) { model.cancelResetCredit() }
        } message: {
            if let credit = model.selectedResetCredit {
                Text("即將使用：\(credit.title ?? "所選 Reset credit")\nBucket：\(credit.resetType ?? "未知")\n到期：\(creditDate(credit.expiresAt))\n這會立即消耗一張 Reset Credit，且無法自動復原。")
            } else {
                Text("請先選擇一張可用的 Reset credit。")
            }
        }
        .alert("刪除受管帳號？", isPresented: $showRemoveProfileConfirmation) {
            Button("刪除", role: .destructive) {
                PopoverInteractionTrace.accepted("accounts.remove")
                PopoverInteractionTrace.effectDispatched("accounts.remove")
                if let profilePendingRemoval { model.removeProfile(id: profilePendingRemoval.id) }
                profilePendingRemoval = nil
                PopoverInteractionTrace.effectCompleted("accounts.remove", success: true)
            }
            Button("取消", role: .cancel) { profilePendingRemoval = nil }
        } message: {
            Text("這會停止該帳號的 App Server，並刪除其受管 credentials、歷史與 Token Activity。系統 ~/.codex 不會被修改。")
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(UsagePopoverTab.allCases) { tab in
                Button {
                    acknowledgeAction("\(tab.title)已開啟", control: "tab.\(tab.rawValue)")
                    selectionController.select(tab)
                } label: {
                    Label(tab.title, systemImage: tab.systemImage)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: PopoverInteractionPolicy.tabCellMinimumHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PopoverImmediateButtonStyle(controlID: "tab.\(tab.rawValue)"))
                .foregroundStyle(selectedTab == tab ? HUDColorPalette.primaryText : HUDColorPalette.secondaryText)
                .background(
                    selectedTab == tab ? HUDColorPalette.controlSurface : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
            }
        }
        .padding(3)
        .background(HUDColorPalette.elevatedSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(HUDColorPalette.border, lineWidth: 0.7) }
    }

    @ViewBuilder
    private var actionAcknowledgementView: some View {
        if let actionAcknowledgement {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(HUDColorPalette.continueAction)
                Text(actionAcknowledgement)
                    .foregroundStyle(HUDColorPalette.secondaryText)
            }
            .font(.caption2.weight(.medium))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(HUDColorPalette.controlSurface.opacity(0.96), in: Capsule())
            .transition(.opacity)
            .accessibilityLabel(actionAcknowledgement)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .overview:
            overviewTab
        case .history:
            historyTab
        case .accounts:
            accountsTab
        case .settings:
            settingsTab
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: selectedTab == .overview ? 7 : 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("Codex 用量")
                            .font(.headline.weight(.semibold))
                        Text(AppVersion.label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(HUDColorPalette.tertiaryText)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Label(model.connectionState.displayName, systemImage: connectionIcon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(model.shouldShowOfflineBadge ? HUDColorPalette.warning : HUDColorPalette.continueAction)
                    HStack(spacing: 5) {
                        if let remaining = model.menuBarRemainingPercent {
                            Text("目前 \(remaining)%")
                                .foregroundStyle(model.menuBarColor)
                        }
                        Text(model.dataAgeText)
                            .foregroundStyle(HUDColorPalette.tertiaryText)
                    }
                    .font(.caption2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(HUDColorPalette.elevatedSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(HUDColorPalette.border, lineWidth: 0.7) }
    }

    // Shared formatting belongs to the shell because the alert, Overview, and
    // History all use the same value-semantic presentation rules.
    func durationText(_ value: Int64?) -> String {
        TokenActivityPresentation.durationText(value)
    }

    func creditDate(_ timestamp: Int64?) -> String {
        guard let timestamp else { return "未知" }
        return Date(timeIntervalSince1970: TimeInterval(timestamp)).formatted(date: .abbreviated, time: .shortened)
    }

    func acknowledgeAction(_ message: String, control: String) {
        PopoverInteractionTrace.accepted(control)
        actionAcknowledgement = message
        let token = UUID()
        actionAcknowledgementToken = token
        // Keep the acknowledgement out of the measured content tree and mark
        // the first visible response after SwiftUI receives the state change.
        // This is intentionally a next-turn observation; it does not move any
        // action earlier than the existing mouse-up handler.
        DispatchQueue.main.async {
            PopoverInteractionTrace.firstVisible(control)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard actionAcknowledgementToken == token else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                actionAcknowledgement = nil
            }
        }
    }

    private func applyPendingSettingsSection() {
        guard let section = selectionController.consumePendingSettingsSection() else { return }
        switch section {
        case .notifications:
            isNotificationsExpanded = true
        case .hud:
            isHUDExpanded = true
        case .sync:
            isSyncExpanded = true
        case .update:
            isUpdateExpanded = true
        case .metadata:
            isMetadataExpanded = true
        }
    }

    private func syncUpdateDisclosure(with state: AppUpdateState) {
        guard case .available(let release) = state,
              autoExpandedUpdateVersion != release.version else { return }
        autoExpandedUpdateVersion = release.version
        if !isUpdateExpanded {
            isUpdateExpanded = true
        }
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
}

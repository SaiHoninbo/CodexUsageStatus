import Foundation
import SwiftUI

struct CodexFloatingHUDView: View {
    private enum UpdateFeedbackKind {
        case checking
        case upToDate
        case available
        case error
    }

    private struct UpdateFeedback: Identifiable {
        let id = UUID()
        let kind: UpdateFeedbackKind
        let title: String
        let message: String
        let release: AppUpdateRelease?
    }

    @ObservedObject var model: UsageViewModel
    @ObservedObject var layoutState: FloatingHUDLayoutState
    let pasteClipboard: (@escaping (Bool) -> Void) -> Void
    let pasteAndSubmit: (@escaping (Bool) -> Void) -> Void
    let promptShortcut: (CodexPromptShortcut, @escaping (Bool) -> Void) -> Void
    let showDetails: () -> Void
    let openCodex: () -> Void
    let quit: () -> Void
    let resetPosition: () -> Void
    let refresh: () -> Void
    let selectProfile: (UUID) -> Void
    let setAccountScope: (AccountScope) -> Void
    let setNotificationsEnabled: (Bool) -> Void
    let setQuotaRefreshInterval: (Int) -> Void
    let setAccountRefreshInterval: (Int) -> Void
    let setTokenActivityRefreshInterval: (Int) -> Void
    let setCredentialWatchInterval: (Int) -> Void
    let setHUDScaleLevel: (HUDScaleLevel) -> Void
    let quotaRowCountChanged: (Int) -> Void
    let accountInfoRowVisibilityChanged: (Bool) -> Void
    let checkForUpdates: () -> Void
    let installUpdate: (AppUpdateRelease) -> Void
    let openReleasePage: () -> Void
    /// Keeps the non-activating AppKit panel appearance in lockstep with the
    /// SwiftUI theme without recreating the panel or changing its geometry.
    let setHUDThemeAppearance: (HUDThemeAppearance) -> Void
    let openSettingsForAlert: (HUDAlertPresentation) -> Void
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isPasteHovered = false
    @State private var isPasteAndSubmitHovered = false
    @State private var isContinueHovered = false
    @State private var isFixUntilDoneHovered = false
    @State private var isFullVerificationHovered = false
    @State private var isCommitAndPushHovered = false
    @State private var isPasteInFlight = false
    @State private var isPasteAndSubmitInFlight = false
    @State private var isPromptShortcutInFlight = false
    @State private var trackedProfileID: UUID?
    @State private var displayedAccountEmail: String?
    @State private var suppressedAccountEmail: String?
    @State private var displayedPlan: String?
    @State private var lastLivePercent: Int?
    @State private var hasPresentedHUD = false
    @State private var presentationCache: HUDDualQuotaPresentation?
    @State private var decreaseAmount: Int?
    @State private var decreaseAnimationID = 0
    @State private var updateCheckRequested = false
    @State private var updateFeedback: UpdateFeedback?
    @AppStorage(HUDThemePreference.themeKey) private var storedHUDTheme = HUDTheme.neonPurple.rawValue
    @AppStorage(HUDThemePreference.rotationEnabledKey) private var hudThemeRotationEnabled = false
    @AppStorage(HUDThemePreference.intervalKey) private var hudThemeRotationInterval = HUDThemeRotationInterval.oneHour.rawValue
    @AppStorage(HUDThemePreference.lastRotationKey) private var lastHUDThemeRotationAt = 0.0

    private var selectedHUDTheme: HUDTheme {
        HUDTheme(rawValue: storedHUDTheme) ?? .neonPurple
    }

    private var selectedHUDPalette: HUDThemePalette {
        HUDThemePalette.forTheme(selectedHUDTheme)
    }

    private var selectedHUDRotationInterval: HUDThemeRotationInterval {
        HUDThemeRotationInterval(rawValue: hudThemeRotationInterval) ?? .oneHour
    }

    private var themeRotationTaskID: String {
        "\(hudThemeRotationEnabled)-\(selectedHUDRotationInterval.rawValue)"
    }

    var body: some View {
        // Keep the context-menu host outside the pulse TimelineView. The
        // timeline intentionally refreshes several times per second for the
        // breathing border; attaching the menu inside it recreates the
        // AppKit anchor on every pulse and makes an open menu jitter.
        ZStack {
            if layoutState.hasEstablishedPosition
                || hasPresentedHUD
                || livePresentation != nil
                || displayedPresentation != nil {
                // Keep the content tree mounted while quota transport is
                // temporarily empty. The cached presentation is profile-bound
                // and renders an updating state instead of blanking the panel.
                HUDPresentationBoundary(
                    presentation: hudPresentation,
                    theme: selectedHUDTheme
                ) { presentation in
                    hudContainer(presentation: presentation)
                        .overlay { hudPulseOverlay(presentation: presentation) }
                }
                .equatable()
            } else {
                // Before the first valid quota, keep the host at its normal
                // size while the controller waits for a verified position.
                Color.clear
                    .frame(width: layoutState.size.width, height: layoutState.size.height)
            }

            // A borderless, non-activating NSPanel cannot reliably present a
            // SwiftUI Alert after its context menu closes. Keep the result in
            // the HUD itself so every check has immediate, visible feedback,
            // even when Codex remains the frontmost application.
            if let updateFeedback {
                updateFeedbackBanner(updateFeedback)
                    .zIndex(20)
            }
        }
        .contextMenu {
            contextMenuContent
        }
        .environment(\.hudThemePalette, selectedHUDPalette)
        .preferredColorScheme(selectedHUDPalette.appearance.colorScheme)
        .onAppear {
            setHUDThemeAppearance(selectedHUDPalette.appearance)
            evaluateThemeRotationIfDue()
        }
        .onChange(of: storedHUDTheme) { _, rawValue in
            let theme = HUDTheme(rawValue: rawValue) ?? .neonPurple
            setHUDThemeAppearance(HUDThemePalette.forTheme(theme).appearance)
        }
        .onChange(of: model.updateState) { _, newState in
            presentUpdateFeedback(for: newState)
        }
        .task(id: updateFeedback?.id) {
            guard let feedback = updateFeedback,
                  feedback.kind != .checking else { return }
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled else { return }
            updateFeedback = nil
        }
        .task(id: themeRotationTaskID) {
            guard hudThemeRotationEnabled else { return }
            while !Task.isCancelled && hudThemeRotationEnabled {
                evaluateThemeRotationIfDue()
                let remaining = max(
                    1,
                    Double(selectedHUDRotationInterval.rawValue)
                        - max(0, Date().timeIntervalSince1970 - lastHUDThemeRotationAt)
                )
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                guard !Task.isCancelled, hudThemeRotationEnabled else { return }
                storedHUDTheme = HUDThemeRotationPolicy.advance(selectedHUDTheme).rawValue
                lastHUDThemeRotationAt = Date().timeIntervalSince1970
            }
        }
    }

    private var hudPresentation: HUDPresentation {
        let resetCredit = HUDResetCreditPresentation.make(
            from: model.resetCredits,
            now: model.currentDate
        )
        let credits = displayedPresentation?.credits
        let showsAccountInfoRow = HUDAccountInfoVisibilityPolicy.showsRow(
            credits: credits,
            resetCreditCount: resetCredit?.count
        )
        return HUDPresentation(
            profileID: model.currentProfileID,
            accountEmail: displayedAccountEmail,
            plan: displayedPlan,
            identityEmail: model.currentAccountEmail,
            identityPlan: model.accountHealth?.identity.planType ?? model.snapshot?.planType,
            quota: displayedPresentation,
            tokenMetrics: model.hudTokenActivityMetrics,
            tokenActivityFeedback: model.hudTokenActivityFeedback,
            tokenActivityIsStale: model.hudTokenActivityIsStale,
            updateBadge: HUDUpdateBadgePolicy.state(
                updateState: model.updateState,
                currentVersion: AppVersion.current
            ),
            settingsAlert: HUDAlertPresentation.make(from: model.currentSettingsAlerts),
            dataAgeText: model.dataAgeText,
            connectionState: model.connectionState,
            isStale: model.isStale,
            isQuotaUpdating: isQuotaUpdating,
            isCodexFocused: layoutState.isCodexFocused,
            quotaRowCount: max(1, layoutState.quotaRowCount),
            showsAccountInfoRow: showsAccountInfoRow,
            resetCreditCount: resetCredit?.count,
            resetCreditNextExpiryAt: resetCredit?.nextExpiryAt,
            resetCreditCountdownText: resetCredit.flatMap { reset in
                guard reset.count > 0, let expiry = reset.nextExpiryAt else { return nil }
                return HUDResetCreditCountdownPolicy.text(expiresAt: expiry, now: model.currentDate)
            },
            scaleLevel: layoutState.scaleLevel,
            isPasteInFlight: isPasteInFlight,
            isPasteAndSubmitInFlight: isPasteAndSubmitInFlight,
            isPromptShortcutInFlight: isPromptShortcutInFlight,
            clipboardOperationInFlight: ClipboardPasteService.isTemporaryOperationInFlight,
            decreaseAmount: decreaseAmount,
            remainingPercent: model.hudRemainingPercent,
            statusColor: model.statusItemPresentation.color,
            isPasteHovered: isPasteHovered,
            isPasteAndSubmitHovered: isPasteAndSubmitHovered,
            isContinueHovered: isContinueHovered,
            isFixUntilDoneHovered: isFixUntilDoneHovered,
            isFullVerificationHovered: isFullVerificationHovered,
            isCommitAndPushHovered: isCommitAndPushHovered,
            reduceMotion: accessibilityReduceMotion
        )
    }

    private func requestUpdateCheck() {
        updateCheckRequested = true
        updateFeedback = UpdateFeedback(
            kind: .checking,
            title: "正在檢查更新…",
            message: "正在檢查 GitHub Release",
            release: nil
        )
        checkForUpdates()
    }

    private func presentUpdateFeedback(for state: AppUpdateState) {
        guard updateCheckRequested else { return }

        switch state {
        case .upToDate:
            updateCheckRequested = false
            updateFeedback = UpdateFeedback(
                kind: .upToDate,
                title: "更新檢查完成",
                message: "目前已是最新版本。",
                release: nil
            )
        case .available(let release):
            updateCheckRequested = false
            updateFeedback = UpdateFeedback(
                kind: .available,
                title: "有新版本可用",
                message: "發現 Codex Usage Status \(release.version)",
                release: release
            )
        case .error(let message):
            updateCheckRequested = false
            updateFeedback = UpdateFeedback(
                kind: .error,
                title: "更新檢查失敗",
                message: message,
                release: nil
            )
        case .idle, .checking, .downloading, .installing:
            break
        }
    }

    @ViewBuilder
    private func updateFeedbackBanner(_ feedback: UpdateFeedback) -> some View {
        HStack(spacing: 6) {
            Image(systemName: updateFeedbackIcon(for: feedback.kind))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(updateFeedbackColor(for: feedback.kind))

            VStack(alignment: .leading, spacing: 0) {
                Text(feedback.title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Text(feedback.message)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            switch feedback.kind {
            case .checking:
                ProgressView()
                    .controlSize(.small)
            case .available:
                Button(AppUpdatePresentationPolicy.installButtonTitle) {
                    if let release = feedback.release { installUpdate(release) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            case .error:
                Button("重試") { requestUpdateCheck() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            case .upToDate:
                Button("確定") { updateFeedback = nil }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: layoutState.size.width, height: layoutState.size.height, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: FloatingHUDLayout.cornerRadius(for: layoutState.scaleLevel), style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FloatingHUDLayout.cornerRadius(for: layoutState.scaleLevel), style: .continuous)
                .stroke(updateFeedbackColor(for: feedback.kind).opacity(0.72), lineWidth: 1.8)
        }
        .shadow(color: updateFeedbackColor(for: feedback.kind).opacity(0.16), radius: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(feedback.title)
        .accessibilityValue(feedback.message)
    }

    private func updateFeedbackIcon(for kind: UpdateFeedbackKind) -> String {
        switch kind {
        case .checking: return "arrow.down.circle"
        case .upToDate: return "checkmark.circle.fill"
        case .available: return "sparkles"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private func updateFeedbackColor(for kind: UpdateFeedbackKind) -> Color {
        switch kind {
        case .checking: return .accentColor
        case .upToDate: return .green
        case .available: return .orange
        case .error: return .red
        }
    }

    @ViewBuilder
    private func hudContainer(presentation: HUDPresentation) -> some View {
        let metrics = HUDMetrics(scaleLevel: presentation.scaleLevel)
        let cornerRadius = FloatingHUDLayout.cornerRadius(for: presentation.scaleLevel)
        let panelSize = metrics.panelSize(
            quotaRowCount: presentation.quotaRowCount,
            includesAccountInfoRow: presentation.showsAccountInfoRow
        )
        let displayedCredits = presentation.quota?.credits
        VStack(alignment: .leading, spacing: 0) {
            HUDTokenActivitySummaryView(
                summaryMetrics: presentation.tokenMetrics,
                feedback: presentation.tokenActivityFeedback,
                width: metrics.contentWidth,
                height: metrics.tokenSummaryHeight,
                scaleFactor: metrics.factor,
                isStale: presentation.tokenActivityIsStale,
                reduceMotion: presentation.reduceMotion
            )
            // The Token Hero consumes the theme palette from the environment.
            // Do not put an Equatable gate in front of it: palette-only theme
            // changes must repaint the secondary metric labels and values even
            // when the usage payload itself is unchanged.
            Color.clear.frame(height: metrics.tokenSummaryGap)
            hudHeader(presentation: presentation, metrics: metrics)
            Color.clear.frame(height: metrics.headerGap)
            quotaStack(presentation: presentation, width: metrics.contentWidth, height: metrics.quotaRowHeight, gap: metrics.quotaGap)
            Color.clear.frame(height: metrics.sectionGap)
            if presentation.showsAccountInfoRow {
                HUDAccountInfoRow(
                    credits: displayedCredits,
                    resetCreditCount: presentation.resetCreditCount,
                    resetCreditCountdownText: presentation.resetCreditCountdownText,
                    width: metrics.contentWidth,
                    sectionHeight: metrics.accountInfoSectionHeight,
                    rowHeight: metrics.accountInfoRowHeight,
                    scaleFactor: metrics.factor
                )
                Color.clear.frame(height: metrics.sectionGap)
            }
            actionCardsRow(presentation: presentation, metrics: metrics)
            Color.clear.frame(height: metrics.workflowActionGap)
            workflowShortcutsRow(presentation: presentation, metrics: metrics)
        }
        .padding(metrics.outerPadding)
        .frame(width: panelSize.width, height: panelSize.height, alignment: .topLeading)
        // Keep theme surfaces behind the content.  They are panel chrome, not
        // a foreground scrim: placing them in an overlay washes out text,
        // controls, and the Token Reel when a theme uses an opaque surface.
        .background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(selectedHUDPalette.panelSurface)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(selectedHUDPalette.panelTint)
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(selectedHUDPalette.panelBorder, lineWidth: 1.0)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Codex 用量")
        .accessibilityValue(hudAccessibilityValue(presentation: presentation))
        .onAppear {
            trackedProfileID = model.currentProfileID
            displayedAccountEmail = AccountProfileDisplay.fullEmail(model.currentAccountEmail)
            suppressedAccountEmail = nil
            displayedPlan = normalizedPlanLabel(model.accountHealth?.identity.planType ?? model.snapshot?.planType)
            cacheCurrentPresentation()
            syncLiveBaseline()
            quotaRowCountChanged(max(1, livePresentation?.rowCount ?? 1))
            accountInfoRowVisibilityChanged(presentation.showsAccountInfoRow)
        }
        .onChange(of: model.currentProfileID) { _, newProfileID in
            // Never carry quota from one account identity into another. The
            // panel remains mounted, but the new profile renders —/updating
            // until it receives its own valid snapshot.
            suppressedAccountEmail = displayedAccountEmail
            displayedAccountEmail = nil
            displayedPlan = nil
            presentationCache = nil
            quotaRowCountChanged(1)
            accountInfoRowVisibilityChanged(false)
            trackedProfileID = newProfileID
            resetTracking(for: newProfileID)
            // UsageViewModel clears the old snapshot and lastUpdated before
            // publishing a profile switch. If the new profile already has a
            // valid managed snapshot, recache it now even when its values are
            // equal to the previous profile and SwiftUI coalesces onChange.
            if newProfileID == model.currentProfileID,
               model.lastUpdated != nil,
               livePresentation != nil {
                cacheCurrentPresentation()
            }
        }
        .onChange(of: model.snapshot) { _, _ in
            cacheCurrentPresentation()
            observePercentChange()
            accountInfoRowVisibilityChanged(hudPresentation.showsAccountInfoRow)
            if trackedProfileID == model.currentProfileID,
               let plan = normalizedPlanLabel(model.snapshot?.planType) {
                displayedPlan = plan
            }
        }
        .onChange(of: presentationCache) { _, _ in
            quotaRowCountChanged(max(1, displayedPresentation?.rowCount ?? 1))
            accountInfoRowVisibilityChanged(hudPresentation.showsAccountInfoRow)
        }
        .onChange(of: model.resetCredits) { _, _ in
            accountInfoRowVisibilityChanged(hudPresentation.showsAccountInfoRow)
        }
        .onChange(of: model.lastUpdated) { _, newValue in
            // A managed profile can restore a cached snapshot with the same
            // percentage and reset timestamp as the previous account. The
            // update marker changes independently, so use it to recache only
            // after the new profile has delivered its own snapshot.
            guard newValue != nil else { return }
            cacheCurrentPresentation()
        }
        .onChange(of: model.accountHealth) { _, newHealth in
            // Account health is the authoritative publication for a profile's
            // identity. A new health snapshot clears any stale suppression
            // and is the only point at which a replacement account email is
            // accepted after a profile transition.
            guard trackedProfileID == model.currentProfileID,
                  let newHealth else { return }
            displayedAccountEmail = AccountProfileDisplay.fullEmail(newHealth.identity.email)
            suppressedAccountEmail = nil
            if let plan = normalizedPlanLabel(newHealth.identity.planType) {
                displayedPlan = plan
            }
        }
        .onChange(of: model.currentAccountEmail) { _, newValue in
            let normalized = AccountProfileDisplay.fullEmail(newValue)
            guard normalized != suppressedAccountEmail else { return }
            displayedAccountEmail = normalized
            suppressedAccountEmail = nil
        }
        .onChange(of: model.connectionState) { _, _ in
            syncLiveBaseline()
        }
        .onChange(of: model.isStale) { _, _ in
            syncLiveBaseline()
        }
        .task(id: decreaseAnimationID) {
            guard decreaseAmount != nil else { return }
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard !Task.isCancelled else { return }
            decreaseAmount = nil
        }
    }

    private func hudHeader(presentation: HUDPresentation, metrics: HUDMetrics) -> some View {
        HStack(alignment: .center, spacing: max(CGFloat(4), metrics.headerGap * 0.5)) {
            Text(presentation.accountEmail ?? "未提供 Email")
                .font(.system(size: metrics.quotaPrimaryTextSize, weight: .semibold, design: .rounded))
                .foregroundStyle(selectedHUDPalette.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.62)
                .allowsTightening(true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                .accessibilityElement()
                .accessibilityLabel("目前登入 Email")
                .accessibilityValue(presentation.accountEmail ?? "未提供 Email")
            if let plan = presentation.plan {
                HUDPlanBadge(plan: plan, height: metrics.headerHeight)
            }
            if let settingsAlert = presentation.settingsAlert {
                HUDSettingsAlertBadge(
                    presentation: settingsAlert,
                    height: metrics.headerHeight,
                    action: { openSettingsForAlert(settingsAlert) }
                )
            }
            HUDUpdateBadge(
                state: presentation.updateBadge,
                height: metrics.headerHeight,
                action: {
                    switch presentation.updateBadge {
                    case .available:
                        showDetails()
                    case .error:
                        requestUpdateCheck()
                    case .version, .checking:
                        break
                    }
                }
            )
        }
        .frame(width: metrics.contentWidth, height: metrics.headerHeight, alignment: .leading)
    }

    private func normalizedPlanLabel(_ rawPlan: String?) -> String? {
        guard let rawPlan else { return nil }
        let trimmed = rawPlan.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = trimmed.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        if key.contains("business") && key.contains("premium") { return "Business Premium" }
        if key.contains("business") { return "Business" }
        if key.contains("enterprise") { return "Enterprise" }
        if key.contains("team") { return "Team" }
        if key.contains("plus") { return "Plus" }
        if key.contains("pro") { return "Pro" }
        if key.contains("free") { return "Free" }
        return trimmed
    }

    private func quotaStack(presentation: HUDPresentation, width: CGFloat, height: CGFloat, gap: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: gap) {
                ForEach(quotaRowKinds(for: presentation), id: \.self) { kind in
                    HUDQuotaRow(
                        kind: kind,
                        presentation: quotaPresentation(for: kind, presentation: presentation),
                        isUpdating: presentation.isQuotaUpdating,
                        width: width,
                        height: height
                    )
                }
            }
            if let decreaseAmount = presentation.decreaseAmount {
                Text("−\(decreaseAmount)%")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(selectedHUDPalette.error)
                    .offset(x: 1, y: -3)
                    .zIndex(1)
            }
        }
    }

    private func quotaRowKinds(for presentation: HUDPresentation) -> [HUDQuotaWindowKind] {
        if let rows = presentation.quota?.rows, !rows.isEmpty {
            return rows.map(\.kind)
        }
        return Array(HUDQuotaWindowKind.allCases.prefix(presentation.quotaRowCount))
    }

    private func quotaPresentation(for kind: HUDQuotaWindowKind, presentation: HUDPresentation) -> HUDQuotaWindowPresentation? {
        presentation.quota?.rows.first(where: { $0.kind == kind })
    }

    private func actionCardsRow(presentation: HUDPresentation, metrics: HUDMetrics) -> some View {
        HStack(spacing: metrics.actionSpacing) {
            pasteShortcutButton(presentation: presentation, metrics: metrics)
            pasteAndSubmitShortcutButton(presentation: presentation, metrics: metrics)
            continueShortcutButton(presentation: presentation, metrics: metrics)
        }
        .frame(width: metrics.contentWidth, height: metrics.actionHeight, alignment: .leading)
    }

    private func workflowShortcutsRow(presentation: HUDPresentation, metrics: HUDMetrics) -> some View {
        HStack(spacing: metrics.actionSpacing) {
            workflowShortcutButton(
                .fixUntilDone,
                fillColor: selectedHUDPalette.fixAction,
                metrics: metrics,
                presentation: presentation,
                isHovered: $isFixUntilDoneHovered
            )
            workflowShortcutButton(
                .fullVerification,
                fillColor: selectedHUDPalette.verificationAction,
                metrics: metrics,
                presentation: presentation,
                isHovered: $isFullVerificationHovered
            )
            workflowShortcutButton(
                .commitAndPush,
                fillColor: selectedHUDPalette.commitPushAction,
                metrics: metrics,
                presentation: presentation,
                isHovered: $isCommitAndPushHovered
            )
        }
        .frame(width: metrics.contentWidth, height: metrics.workflowActionHeight, alignment: .leading)
    }

    private func pasteShortcutButton(presentation: HUDPresentation, metrics: HUDMetrics) -> some View {
        HUDActionCard(
            title: "貼上",
            systemImage: "doc.on.clipboard",
            iconSize: 14,
            action: {
                guard HUDPasteActionPolicy.canStart(
                    isInFlight: isPasteInFlight,
                    isCodexFocused: layoutState.isCodexFocused
                ) else { return }
                isPasteInFlight = true
                pasteClipboard { _ in
                    isPasteInFlight = false
                }
            },
            isDisabled: presentation.isPasteInFlight || !presentation.isCodexFocused,
            helpText: presentation.isCodexFocused ? "貼上剪貼簿內容" : "切換回 Codex 後可貼上",
            accessibilityLabel: "貼上剪貼簿內容",
            width: metrics.actionCardWidth,
            height: metrics.actionHeight,
            isHovered: $isPasteHovered
        )
        .opacity(presentation.isPasteInFlight ? 0.45 : 1)
    }

    private func pasteAndSubmitShortcutButton(presentation: HUDPresentation, metrics: HUDMetrics) -> some View {
        HUDActionCard(
            title: "貼上並送出",
            systemImage: "paperplane.fill",
            iconSize: 12,
            action: {
                guard !isPasteAndSubmitInFlight else { return }
                isPasteAndSubmitInFlight = true
                pasteAndSubmit { _ in
                    isPasteAndSubmitInFlight = false
                }
            },
            isDisabled: presentation.isPasteAndSubmitInFlight || !presentation.isCodexFocused,
            helpText: presentation.isCodexFocused ? "貼上並送出" : "切換回 Codex 後可貼上並送出",
            accessibilityLabel: "貼上並送出",
            fillStyle: presentation.isCodexFocused
                ? .filled(background: selectedHUDPalette.submitAction, foreground: selectedHUDPalette.filledActionForeground)
                : .neutral,
            width: metrics.actionCardWidth,
            height: metrics.actionHeight,
            isHovered: $isPasteAndSubmitHovered
        )
        .opacity(presentation.isPasteAndSubmitInFlight ? 0.45 : 1)
    }

    private func continueShortcutButton(presentation: HUDPresentation, metrics: HUDMetrics) -> some View {
        workflowShortcutButton(
            .continueTask,
            fillColor: selectedHUDPalette.continueAction,
            metrics: metrics,
            presentation: presentation,
            height: metrics.actionHeight,
            isHovered: $isContinueHovered
        )
    }

    private func workflowShortcutButton(
        _ shortcut: CodexPromptShortcut,
        fillColor: Color,
        metrics: HUDMetrics,
        presentation: HUDPresentation,
        height: CGFloat? = nil,
        isHovered: Binding<Bool>
    ) -> some View {
        let cardHeight = height ?? metrics.workflowActionHeight
        let isDisabled = presentation.isPromptShortcutInFlight
            || !presentation.isCodexFocused
            || presentation.clipboardOperationInFlight
        let helpText = presentation.isCodexFocused
            ? shortcut.helpText
            : "切換回 Codex 後可使用「\(shortcut.rawValue)」"
        return HUDActionCard(
            title: shortcut.rawValue,
            systemImage: shortcut == .commitAndPush ? "arrow.up.circle.fill" : (shortcut == .continueTask ? "play.fill" : (shortcut == .fullVerification ? "checkmark.circle.fill" : "wrench.and.screwdriver.fill")),
            iconSize: 12,
            action: {
                guard !isPromptShortcutInFlight,
                      layoutState.isCodexFocused,
                      !ClipboardPasteService.isTemporaryOperationInFlight else { return }
                isPromptShortcutInFlight = true
                promptShortcut(shortcut) { _ in
                    isPromptShortcutInFlight = false
                }
            },
            isDisabled: isDisabled,
            helpText: helpText,
            accessibilityLabel: shortcut.accessibilityLabel,
            fillStyle: presentation.isCodexFocused
                ? .filled(
                    background: fillColor,
                    foreground: shortcut == .commitAndPush
                        ? selectedHUDPalette.commitPushForeground
                        : selectedHUDPalette.filledActionForeground
                )
                : .neutral,
            width: metrics.actionCardWidth,
            height: cardHeight,
            isHovered: isHovered
        )
    }

    @ViewBuilder
    private func hudPulseOverlay(presentation: HUDPresentation) -> some View {
        if let profile = HUDWarningPolicy.framePulseProfile(
            remainingPercent: presentation.remainingPercent,
            connectionState: presentation.connectionState,
            isStale: presentation.isStale
        ) {
            // Keep the HUD visually stable. The earlier TimelineView rebuilt
            // an animated edge several times per second, which looked like a
            // panel flash on some macOS/window-manager combinations. A
            // color-matched static contour still communicates quota state
            // without moving or blinking the HUD.
            let opacity = profile.minOpacity + ((profile.maxOpacity - profile.minOpacity) * 0.45)
            hudPulseBorder(frameOpacity: opacity, presentation: presentation)
        } else if presentation.reduceMotion,
                  presentation.connectionState == .connected,
                  !presentation.isStale,
                  presentation.remainingPercent != nil {
            hudPulseBorder(frameOpacity: 0.14, presentation: presentation)
        }
    }

    private func hudPulseBorder(frameOpacity: Double, presentation: HUDPresentation) -> some View {
        RoundedRectangle(cornerRadius: FloatingHUDLayout.cornerRadius(for: layoutState.scaleLevel), style: .continuous)
            .stroke(
                hudColor(for: presentation.statusColor).opacity(max(0.28, frameOpacity)),
                lineWidth: frameOpacity > 0.48 ? 2.35 : 2.0
            )
        .frame(width: layoutState.size.width, height: layoutState.size.height)
        .allowsHitTesting(false)
    }

    private func hudColor(for statusColor: StatusItemColor) -> Color {
        switch statusColor {
        case .secondary: return selectedHUDPalette.secondaryText
        case .red: return selectedHUDPalette.error
        case .orange: return selectedHUDPalette.warning
        case .green: return selectedHUDPalette.continueAction
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Section {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.accountDisplayName)
                    .font(.headline)
                if let currentProfile = model.currentProfile {
                    Text(model.accountProfileDisplay(for: currentProfile).subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Label(model.menuBarTitle, systemImage: "gauge.with.dots.needle.33percent")
            Label(contextConnectionText, systemImage: contextConnectionIcon)
            Label("版本 \(AppVersion.current)", systemImage: "number.circle")
            Divider()
            Button(action: refresh) {
                Label("重新整理", systemImage: "arrow.clockwise")
            }
            Button(action: showDetails) {
                Label("開啟詳細面板", systemImage: "rectangle.and.text.magnifyingglass")
            }
        }

        Section {
            Button(action: openCodex) {
                Label("開啟 Codex", systemImage: "arrow.up.forward.app")
            }
            Button(action: resetPosition) {
                Label("重設 HUD 位置", systemImage: "scope")
            }
            Menu("HUD 尺寸") {
                ForEach(Array(HUDScaleLevel.allCases.enumerated()), id: \.offset) { index, level in
                    Button {
                        setHUDScaleLevel(level)
                    } label: {
                        Label(
                            "\(index + 1) · \(level.displayName)",
                            systemImage: layoutState.scaleLevel == level ? "checkmark" : "circle"
                        )
                    }
                }
            }
            Menu("HUD 色系") {
                ForEach(HUDTheme.allCases) { theme in
                    Button {
                        selectHUDTheme(theme)
                    } label: {
                        Label(
                            theme.displayName,
                            systemImage: selectedHUDTheme == theme ? "checkmark" : "circle"
                        )
                    }
                }
            }
            Menu("自動換色") {
                Button {
                    disableHUDThemeRotation()
                } label: {
                    Label(
                        "關閉自動換色",
                        systemImage: hudThemeRotationEnabled ? "circle" : "checkmark"
                    )
                }
                Divider()
                ForEach(HUDThemeRotationInterval.allCases) { interval in
                    Button {
                        enableHUDThemeRotation(interval)
                    } label: {
                        Label(
                            interval.displayName,
                            systemImage: hudThemeRotationEnabled && selectedHUDRotationInterval == interval ? "checkmark" : "circle"
                        )
                    }
                }
            }
        }

        Section {
            Button {
                guard HUDPasteActionPolicy.canStart(
                    isInFlight: isPasteInFlight,
                    isCodexFocused: layoutState.isCodexFocused
                ) else { return }
                isPasteInFlight = true
                pasteClipboard { _ in
                    isPasteInFlight = false
                }
            } label: {
                Label("貼上剪貼簿內容", systemImage: "doc.on.clipboard")
            }
            .disabled(
                isPasteInFlight
                    || !HUDContextMenuPolicy.pasteActionsEnabled(isCodexFocused: layoutState.isCodexFocused)
            )

            Button {
                guard !isPasteAndSubmitInFlight else { return }
                isPasteAndSubmitInFlight = true
                pasteAndSubmit { _ in
                    isPasteAndSubmitInFlight = false
                }
            } label: {
                Label("貼上並送出", systemImage: "paperplane.fill")
            }
            .disabled(
                isPasteAndSubmitInFlight
                    || !HUDContextMenuPolicy.pasteActionsEnabled(isCodexFocused: layoutState.isCodexFocused)
            )
        }

        Section {
            Button(action: requestUpdateCheck) {
                Label("檢查更新", systemImage: "arrow.down.circle")
            }

            switch model.updateState {
            case .available(let release):
                Button(action: { installUpdate(release) }) {
                    Label(AppUpdatePresentationPolicy.installButtonTitle + " \(release.version)", systemImage: "arrow.down.circle.fill")
                }
                Button(action: openReleasePage) {
                    Label("開啟 Release 頁面 \(release.version)", systemImage: "safari")
                }
            case .checking:
                Label("正在檢查 GitHub Release", systemImage: "arrow.down.circle")
            case .downloading(let release):
                Label("正在下載 \(release.version)", systemImage: "arrow.down.circle")
            case .installing(let release):
                Label("正在覆蓋並重新啟動 \(release.version)", systemImage: "arrow.triangle.2.circlepath")
            case .upToDate:
                Label("目前已是最新版本", systemImage: "checkmark.circle")
            case .error(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .lineLimit(2)
                Button("重試更新檢查", action: requestUpdateCheck)
            case .idle:
                EmptyView()
            }
        }

        Menu {
            Button {
                setAccountScope(.current)
            } label: {
                Label("目前帳號", systemImage: model.accountScope == .current ? "checkmark" : "person")
            }
            Button {
                setAccountScope(.all)
            } label: {
                Label("全部帳號總覽", systemImage: model.accountScope == .all ? "checkmark" : "person.2")
            }

            if !model.accountProfiles.isEmpty {
                Divider()
                ForEach(model.accountProfiles) { profile in
                    let display = model.accountProfileDisplay(for: profile)
                    Button {
                        selectProfile(profile.id)
                        setAccountScope(.current)
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: profile.id == model.currentProfileID ? "checkmark" : (display.isWarning ? "exclamationmark.triangle" : "person"))
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(display.title)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(display.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }

            Divider()
            Button(action: showDetails) {
                Label("管理帳號與登入", systemImage: "person.crop.circle.badge.plus")
            }
        } label: {
            Label("帳號管理", systemImage: "person.2")
        }

        Menu {
            Button {
                setNotificationsEnabled(!model.notificationsEnabled)
            } label: {
                Label(
                    model.notificationsEnabled ? "停用配額通知" : "啟用配額通知",
                    systemImage: model.notificationsEnabled ? "bell.slash" : "bell"
                )
            }
            Menu("更新頻率") {
                intervalMenu(
                    title: "Quota：\(model.quotaRefreshIntervalSeconds) 秒",
                    options: [30, 60, 120, 300, 600],
                    selected: model.quotaRefreshIntervalSeconds,
                    action: setQuotaRefreshInterval
                )
                intervalMenu(
                    title: "帳號身份：\(model.globalSyncIntervalSeconds) 秒",
                    options: [300, 600, 900, 1800],
                    selected: model.globalSyncIntervalSeconds,
                    action: setAccountRefreshInterval
                )
                intervalMenu(
                    title: "Token Activity：\(model.tokenActivityRefreshIntervalSeconds) 秒",
                    options: [300, 900, 1800, 3600],
                    selected: model.tokenActivityRefreshIntervalSeconds,
                    action: setTokenActivityRefreshInterval
                )
                intervalMenu(
                    title: "auth.json 監看：\(model.credentialWatchIntervalSeconds) 秒",
                    options: [5, 15, 30, 60],
                    selected: model.credentialWatchIntervalSeconds,
                    action: setCredentialWatchInterval
                )
            }
            Divider()
            Text("更新操作位於右鍵主選單")
                .foregroundStyle(.secondary)
        } label: {
            Label("通知與同步", systemImage: "bell.badge")
        }

        Divider()
        Button(action: quit) {
            Label("結束 Codex Usage Status", systemImage: "power")
        }
    }

    @ViewBuilder
    private func intervalMenu(
        title: String,
        options: [Int],
        selected: Int,
        action: @escaping (Int) -> Void
    ) -> some View {
        Menu {
            ForEach(options, id: \.self) { value in
                Button {
                    action(value)
                } label: {
                    Label("\(value) 秒", systemImage: value == selected ? "checkmark" : "circle")
                }
            }
        } label: {
            Text(title)
        }
    }

    private func selectHUDTheme(_ theme: HUDTheme) {
        storedHUDTheme = theme.rawValue
        hudThemeRotationEnabled = false
        lastHUDThemeRotationAt = Date().timeIntervalSince1970
    }

    private func enableHUDThemeRotation(_ interval: HUDThemeRotationInterval) {
        hudThemeRotationInterval = interval.rawValue
        hudThemeRotationEnabled = true
        lastHUDThemeRotationAt = Date().timeIntervalSince1970
    }

    private func disableHUDThemeRotation() {
        hudThemeRotationEnabled = false
        lastHUDThemeRotationAt = Date().timeIntervalSince1970
    }

    private func evaluateThemeRotationIfDue(now: Date = Date()) {
        guard hudThemeRotationEnabled else { return }
        let last = Date(timeIntervalSince1970: lastHUDThemeRotationAt)
        guard lastHUDThemeRotationAt > 0 else {
            lastHUDThemeRotationAt = now.timeIntervalSince1970
            return
        }
        guard HUDThemeRotationPolicy.shouldRotate(
            now: now,
            lastRotationAt: last,
            interval: selectedHUDRotationInterval
        ) else { return }

        let elapsed = max(0, now.timeIntervalSince(last))
        let steps = max(1, Int(elapsed / Double(selectedHUDRotationInterval.rawValue)))
        storedHUDTheme = HUDThemeRotationPolicy.advance(selectedHUDTheme, steps: steps).rawValue
        lastHUDThemeRotationAt = now.timeIntervalSince1970
    }

    private var contextConnectionText: String {
        if model.isStale { return "資料已過期" }
        return model.connectionState.displayName
    }

    private var contextConnectionIcon: String {
        if model.isStale { return "clock.badge.exclamationmark" }
        switch model.connectionState {
        case .connected: return "checkmark.circle"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .disconnected: return "circle"
        case .offline: return "wifi.slash"
        case .error, .stopped: return "exclamationmark.triangle"
        }
    }

    private var hasLiveHUDData: Bool {
        model.connectionState == .connected
            && !model.isStale
            && model.hudRemainingPercent != nil
    }

    private var isQuotaUpdating: Bool {
        livePresentation == nil
            || model.connectionState != .connected
            || model.isStale
    }

    private func resetTracking(for profileID: UUID?) {
        trackedProfileID = profileID
        lastLivePercent = nil
        decreaseAmount = nil
        decreaseAnimationID &+= 1
        syncLiveBaseline()
    }

    private func syncLiveBaseline() {
        guard model.connectionState == .connected,
              !model.isStale,
              let current = model.hudRemainingPercent else {
            lastLivePercent = nil
            return
        }
        if trackedProfileID != model.currentProfileID {
            trackedProfileID = model.currentProfileID
            lastLivePercent = nil
        }
        if lastLivePercent == nil {
            lastLivePercent = current
        }
    }

    private func observePercentChange() {
        guard trackedProfileID == model.currentProfileID else {
            resetTracking(for: model.currentProfileID)
            return
        }
        guard model.connectionState == .connected,
              !model.isStale,
              let current = model.hudRemainingPercent else {
            lastLivePercent = nil
            return
        }

        guard let amount = HUDWarningPolicy.decreaseAmount(
            previous: lastLivePercent,
            current: current,
            connectionState: model.connectionState,
            isStale: model.isStale,
            sameProfile: true
        ) else {
            lastLivePercent = current
            return
        }

        lastLivePercent = current
        let totalAmount = (decreaseAmount ?? 0) + amount
        decreaseAmount = totalAmount
        decreaseAnimationID &+= 1
    }

    private var livePresentation: HUDDualQuotaPresentation? {
        HUDQuotaPresentationPolicy.make(
            snapshot: model.snapshot,
            profileID: model.currentProfileID,
            now: model.currentDate
        )
    }

    private var displayedPresentation: HUDDualQuotaPresentation? {
        HUDVisibilityPolicy.mergedPresentation(
            currentProfileID: model.currentProfileID,
            live: livePresentation,
            cached: presentationCache
        )
    }

    private func hudAccessibilityValue(presentation: HUDPresentation) -> String {
        let quotaText = quotaRowKinds(for: presentation).map { kind in
            guard let quota = quotaPresentation(for: kind, presentation: presentation) else {
                return "\(kind.label)窗口，\(presentation.isQuotaUpdating ? "資料更新中" : "此帳號未提供")"
            }
            let reset = quota.resetDescription == "更新中" || quota.resetDescription == "已重置"
                ? quota.resetDescription
                : "\(quota.resetDescription)後重置"
            return "\(kind.label)窗口，剩餘 \(quota.remainingPercent)%，\(reset)"
        }.joined(separator: "；")
        let planText = presentation.plan.map { "，方案 \($0)" } ?? ""
        let creditsText: String
        if let credits = presentation.quota?.credits, credits.isDisplayable {
            creditsText = "，Credits \(credits.unlimited ? "unlimited" : (credits.displayBalance ?? "無法取得")) balance"
        } else {
            creditsText = ""
        }
        let workflowText = CodexPromptShortcut.allCases.map(\.rawValue).joined(separator: "、")
        return "Codex，\(quotaText)\(creditsText)\(planText)，\(presentation.dataAgeText)，帳號 \(presentation.accountEmail ?? "未提供 Email")。提供更新通知、詳細面板、只貼上、貼上並送出與\(workflowText)"
    }

    private func cacheCurrentPresentation() {
        guard let presentation = HUDQuotaPresentationPolicy.make(
            snapshot: model.snapshot,
            profileID: model.currentProfileID,
            now: model.currentDate
        ), let merged = HUDVisibilityPolicy.mergedPresentation(
            currentProfileID: model.currentProfileID,
            live: presentation,
            cached: presentationCache
        ), let cached = HUDVisibilityPolicy.presentationSnapshot(
            currentProfileID: model.currentProfileID,
            trackedProfileID: trackedProfileID,
            lastUpdated: model.lastUpdated,
            presentation: merged
        ) else { return }
        hasPresentedHUD = true
        presentationCache = cached
    }

}

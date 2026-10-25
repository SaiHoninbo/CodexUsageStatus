import Combine
import SwiftUI

/// The single-owner host for embedding the existing CodexUsageStatus
/// experience in PlanLoop. Integration mode keeps the donor's account,
/// history, notification, and shortcut model while omitting its own menu-bar
/// item, floating HUD, login item, updater, and local observer.
@MainActor
@_spi(CodexUsageStatusPlanLoopIntegration)
public final class CodexUsageStatusPlanLoopIntegrationHost:
    CodexUsageAccountQuotaProjectionSource,
    CodexUsageAccountQuotaProjectionLifecycle
{
    fileprivate let model: UsageViewModel
    fileprivate let selectionController: PopoverSelectionController
    private var hasStarted = false
    private var hasStopped = false
    private let readOnlyPreview: Bool
    private let preferencesDefaults: UserDefaults
    private var floatingHUDController: FloatingHUDPanelController?
    private var previewProjectionObservation: AnyCancellable?

    public var onShowDetails: (() -> Void)?
    public var onOpenCodex: (() -> Void)?
    public var onQuit: (() -> Void)?

    public init(
        readOnlyPreview: Bool = false,
        preferencesDefaults: UserDefaults? = nil,
        isolatedStorageRoot: URL? = nil
    ) {
        if readOnlyPreview {
            precondition(preferencesDefaults != nil, "Staging preview requires profile-scoped HUD preferences.")
            precondition(isolatedStorageRoot != nil, "Staging preview requires profile-scoped donor storage.")
        }
        self.readOnlyPreview = readOnlyPreview
        self.preferencesDefaults = preferencesDefaults ?? .standard
        model = UsageViewModel(
            runtimeMode: readOnlyPreview ? .planLoopStagingPreview : .planLoopIntegration,
            defaults: preferencesDefaults,
            isolatedStorageRoot: isolatedStorageRoot
        )
        selectionController = PopoverSelectionController()
    }

    public var isReadOnlyPreview: Bool { readOnlyPreview }

    public var accountQuotaSnapshot: CodexUsageAccountQuotaSnapshot {
        model.accountQuotaSnapshot
    }

    public var observationRootConfigurations: [CodexUsageObservationRootConfiguration] {
        model.planLoopObservationRootConfigurations
    }

    public var onObservationRootsChange: (([CodexUsageObservationRootConfiguration]) -> Void)? {
        get { model.planLoopObservationRootsDidChange }
        set { model.planLoopObservationRootsDidChange = newValue }
    }

    /// Feeds the donor's existing lifecycle and notification model from the
    /// host's one observer. Integration mode never starts a second observer.
    public func connectObservedTurnEvents(from provider: CodexUsageProjectionProvider) {
        guard !readOnlyPreview, !hasStopped else { return }
        provider.setPlanLoopTurnActivityHandler { [weak self] event in
            self?.model.receivePlanLoopObservedTurnActivity(event)
        }
        provider.setPlanLoopTurnCompletionHandler { [weak self] profileID, record in
            self?.model.receivePlanLoopObservedTurnCompletion(profileID: profileID, record: record)
        }
    }

    public func start() {
        guard !readOnlyPreview, !hasStarted, !hasStopped else { return }
        hasStarted = true
        model.start()

        // PlanLoop is the sole app host, but the donor remains the single
        // owner of its original HUD panel, geometry, theme, and context menu.
        let controller = FloatingHUDPanelController(
            model: model,
            defaults: preferencesDefaults,
            allowsCommitAndPush: false
        )
        controller.onShowDetails = { [weak self] in self?.onShowDetails?() }
        controller.onOpenCodex = { [weak self] in self?.onOpenCodex?() }
        controller.onQuit = { [weak self] in self?.onQuit?() }
        controller.onOpenSettingsForAlert = { [weak self] _ in self?.onShowDetails?() }
        floatingHUDController = controller
        controller.start()
    }

    /// Presents the donor's original HUD in staging with profile-bound
    /// preferences and only the credential-free projection supplied by the
    /// staging Bridge/observer. The donor model is never started.
    public func startReadOnlyPreviewHUD(from provider: CodexUsageProjectionProvider) {
        guard readOnlyPreview, !hasStopped, floatingHUDController == nil else { return }
        model.applyPlanLoopStagingProjection(
            provider.snapshot,
            trackedChatExecutions: provider.readOnlyPreviewHUDChatExecutions
        )
        previewProjectionObservation = provider.$snapshot.sink { [weak self, weak provider] snapshot in
            Task { @MainActor [weak self, weak provider] in
                guard let provider else { return }
                self?.model.applyPlanLoopStagingProjection(
                    snapshot,
                    trackedChatExecutions: provider.readOnlyPreviewHUDChatExecutions
                )
            }
        }

        let controller = FloatingHUDPanelController(
            model: model,
            defaults: preferencesDefaults,
            allowsCommitAndPush: false
        )
        controller.onShowDetails = { [weak self] in self?.onShowDetails?() }
        controller.onOpenCodex = { [weak self] in self?.onOpenCodex?() }
        controller.onQuit = { [weak self] in self?.onQuit?() }
        controller.onOpenSettingsForAlert = { [weak self] _ in self?.onShowDetails?() }
        floatingHUDController = controller
        controller.start()
    }

    public func stop() {
        guard !hasStopped else { return }
        hasStopped = true
        model.planLoopHUDEnabledDidChange = nil
        model.planLoopObservationRootsDidChange = nil
        previewProjectionObservation?.cancel()
        previewProjectionObservation = nil
        floatingHUDController?.stop()
        floatingHUDController = nil
        if hasStarted && !readOnlyPreview { model.stop() }
    }

    /// Stops the embedded model and waits for its existing bounded persistence
    /// handoff. PlanLoop keeps its canonical observer alive until AppKit allows
    /// termination, so a cancelled quit does not create an observation gap.
    @discardableResult
    public func prepareForTermination() async -> Bool {
        await model.prepareForTermination()
    }

    /// Returns a typed outcome so the PlanLoop AppKit termination decision
    /// can distinguish a completed save from persistence failure or timeout.
    public func prepareForTerminationResult() async -> CodexUsageTerminationPreparationResult {
        if readOnlyPreview { return .saved }
        return await model.prepareForTerminationResult()
    }

    /// Restores the embedded experience after AppKit cancels a termination
    /// request. It waits for any bounded flush task before restarting services.
    public func resumeAfterCancelledTermination() async {
        guard !readOnlyPreview, hasStarted, !hasStopped else { return }
        await model.resumeAfterCancelledTermination()
    }

    public func bindPlanLoopHUDFromPlanLoop(
        enabled: Bool,
        onChange: @escaping (Bool) -> Void
    ) {
        bindPlanLoopHUD(enabled: enabled, onChange: onChange)
    }

    public var floatingHUDEnabled: Bool { model.floatingHUDEnabled }

    public func setFloatingHUDEnabled(_ enabled: Bool) {
        guard !hasStopped else { return }
        model.setFloatingHUDEnabled(enabled)
    }

    public func resetFloatingHUDPosition() {
        guard !hasStopped else { return }
        floatingHUDController?.resetPosition()
    }

    fileprivate func bindPlanLoopHUD(
        enabled: Bool,
        onChange: @escaping (Bool) -> Void
    ) {
        guard !hasStopped else { return }
        model.synchronizeFloatingHUDEnabledFromPlanLoop(enabled)
        model.planLoopHUDEnabledDidChange = onChange
    }

    fileprivate func unbindPlanLoopHUD() {
        model.planLoopHUDEnabledDidChange = nil
    }
}


/// PlanLoop menu-bar controls bound to the donor's one HUD preference. The
/// embedded host owns the panel; this view never creates another HUD or
/// observer.
@MainActor
@_spi(CodexUsageStatusPlanLoopIntegration)
public struct CodexUsageStatusPlanLoopHUDControls: View {
    @ObservedObject private var model: UsageViewModel
    private let host: CodexUsageStatusPlanLoopIntegrationHost

    public init(host: CodexUsageStatusPlanLoopIntegrationHost) {
        self.host = host
        _model = ObservedObject(wrappedValue: host.model)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "顯示並跟隨 Codex HUD",
                isOn: Binding(
                    get: { model.floatingHUDEnabled },
                    set: { enabled in
                        Task { @MainActor in
                            host.setFloatingHUDEnabled(enabled)
                        }
                    },
                ),
            )
            .font(.caption)
            .accessibilityIdentifier("menubar.hud.enabled")

            Button("重設 HUD 位置", action: host.resetFloatingHUDPosition)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("menubar.hud.reset-position")
        }
    }
}

/// The donor-owned usage surfaces exposed to PlanLoop's navigation shell.
/// Each case maps to an existing donor tab, so data and account actions remain
/// backed by the same UsageViewModel rather than a second implementation.
@_spi(CodexUsageStatusPlanLoopIntegration)
public enum CodexUsageStatusPlanLoopSection: String, CaseIterable, Identifiable {
    case overview
    case history
    case accounts
    case preferences

    public var id: String { rawValue }

    fileprivate var usagePopoverTab: UsagePopoverTab {
        switch self {
        case .overview: .overview
        case .history: .history
        case .accounts: .accounts
        case .preferences: .settings
        }
    }

    fileprivate init(usagePopoverTab: UsagePopoverTab) {
        switch usagePopoverTab {
        case .overview: self = .overview
        case .history: self = .history
        case .accounts: self = .accounts
        case .settings: self = .preferences
        }
    }
}

/// Embeds one existing donor tab in PlanLoop's navigation. The donor keeps
/// its model, actions, confirmation UI, and pending-settings routing; only the
/// donor header and tab bar are omitted in this embedded presentation.
@MainActor
@_spi(CodexUsageStatusPlanLoopIntegration)
public struct CodexUsageStatusPlanLoopSectionView: View {
    @ObservedObject private var selectionController: PopoverSelectionController
    private let host: CodexUsageStatusPlanLoopIntegrationHost
    private let section: CodexUsageStatusPlanLoopSection
    private let projection: CodexUsageProjectionSnapshot
    private let isActive: Bool
    private let navigate: (CodexUsageStatusPlanLoopSection) -> Void

    public init(
        host: CodexUsageStatusPlanLoopIntegrationHost,
        section: CodexUsageStatusPlanLoopSection,
        projection: CodexUsageProjectionSnapshot,
        isActive: Bool = true,
        navigate: @escaping (CodexUsageStatusPlanLoopSection) -> Void
    ) {
        self.host = host
        self.section = section
        self.projection = projection
        self.isActive = isActive
        self.navigate = navigate
        _selectionController = ObservedObject(wrappedValue: host.selectionController)
    }

    public var body: some View {
        UsagePopoverView(
            model: host.model,
            selectionController: selectionController,
            planLoopProjection: projection,
            isReadOnlyPreview: host.isReadOnlyPreview,
            planLoopEmbeddedTab: section.usagePopoverTab,
            openCodex: { host.onOpenCodex?() },
            resetHUDPosition: { host.resetFloatingHUDPosition() },
            quit: { host.onQuit?() },
            onContentHeightChange: nil
        )
        .onChange(of: selectionController.selectedTab) { _, tab in
            guard isActive, tab != section.usagePopoverTab else { return }
            navigate(CodexUsageStatusPlanLoopSection(usagePopoverTab: tab))
        }
    }
}

/// Reuses the donor's four existing tabs and their model-owned actions inside
/// the PlanLoop menu-bar window; it never creates an NSStatusItem or HUD.
@MainActor
@_spi(CodexUsageStatusPlanLoopIntegration)
public struct CodexUsageStatusPlanLoopExperience: View {
    @ObservedObject private var model: UsageViewModel
    @ObservedObject private var selectionController: PopoverSelectionController
    private let host: CodexUsageStatusPlanLoopIntegrationHost
    private let openCodex: () -> Void
    private let resetHUDPosition: () -> Void
    private let projection: CodexUsageProjectionSnapshot
    private let hudEnabled: Bool
    private let setHUDEnabled: (Bool) -> Void
    private let quit: () -> Void
    private let readOnlyPreview: Bool

    public init(
        host: CodexUsageStatusPlanLoopIntegrationHost,
        openCodex: @escaping () -> Void,
        resetHUDPosition: @escaping () -> Void,
        projection: CodexUsageProjectionSnapshot,
        hudEnabled: Bool,
        setHUDEnabled: @escaping (Bool) -> Void,
        quit: @escaping () -> Void,
        readOnlyPreview: Bool = false
    ) {
        self.host = host
        self.openCodex = openCodex
        self.resetHUDPosition = resetHUDPosition
        self.projection = projection
        self.hudEnabled = hudEnabled
        self.setHUDEnabled = setHUDEnabled
        self.quit = quit
        self.readOnlyPreview = readOnlyPreview
        _model = ObservedObject(wrappedValue: host.model)
        _selectionController = ObservedObject(wrappedValue: host.selectionController)
        host.bindPlanLoopHUD(enabled: hudEnabled, onChange: setHUDEnabled)
    }

    public var body: some View {
        UsagePopoverView(
            model: model,
            selectionController: selectionController,
            planLoopProjection: projection,
            isReadOnlyPreview: readOnlyPreview,
            openCodex: openCodex,
            resetHUDPosition: resetHUDPosition,
            quit: quit,
            onContentHeightChange: nil
        )
        .onChange(of: hudEnabled) { _, enabled in
            host.bindPlanLoopHUD(enabled: enabled, onChange: setHUDEnabled)
        }
        .onDisappear {
            host.unbindPlanLoopHUD()
        }
    }
}

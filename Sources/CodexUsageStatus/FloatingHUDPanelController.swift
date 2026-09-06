import AppKit
import Combine
import CoreGraphics
import SwiftUI

enum FloatingHUDLayout {
    // C layout: both placements use one scalable panel geometry. Placement
    // changes the anchor only; it never creates a second size contract.
    // Sizes used by the previous shipped HUD builds. These are only used
    // while migrating persisted screen anchors; new anchors are size-agnostic.
    static let previousWideSize = NSSize(width: 360, height: 60)
    static let previousLegacySize = NSSize(width: 156, height: 66)
    static let cornerRadius: CGFloat = HUDMetrics.canonicalCornerRadius

    static func cornerRadius(for scaleLevel: HUDScaleLevel) -> CGFloat {
        HUDMetrics(scaleLevel: scaleLevel).cornerRadius
    }

    static func size(
        for placement: HUDPlacement,
        scaleLevel: HUDScaleLevel = .standard,
        quotaRowCount: Int = HUDMetrics.canonicalQuotaRowCount,
        includesAccountInfoRow: Bool = false
    ) -> NSSize {
        _ = placement
        let metrics = HUDMetrics(scaleLevel: scaleLevel)
        let size = metrics.panelSize(
            quotaRowCount: quotaRowCount,
            includesAccountInfoRow: includesAccountInfoRow
        )
        return NSSize(width: size.width, height: size.height)
    }
}

@MainActor
final class FloatingHUDLayoutState: ObservableObject {
    @Published var placement: HUDPlacement = .bottomRight
    @Published var scaleLevel: HUDScaleLevel = HUDScaleLevel.load()
    /// The HUD is a Codex-only overlay. This state is also used by the view
    /// to keep actions disabled during a focus transition.
    @Published var isCodexFocused = true
    @Published var hasEstablishedPosition = false
    @Published var quotaRowCount: Int = 1
    @Published var showsAccountInfoRow = false

    var size: NSSize {
        FloatingHUDLayout.size(
            for: placement,
            scaleLevel: scaleLevel,
            quotaRowCount: quotaRowCount,
            includesAccountInfoRow: showsAccountInfoRow
        )
    }
}

private final class DraggableHUDPanel: NSPanel {
    var onUserMoved: ((NSPoint) -> Void)?
    var onDragStateChanged: ((Bool) -> Void)?
    private var dragOffset: NSPoint?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        dragOffset = event.locationInWindow
        onDragStateChanged?(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOffset else { return }
        let screenPoint = convertPoint(toScreen: event.locationInWindow)
        guard let origin = HUDDragPolicy.origin(
            screenPoint: screenPoint,
            dragOffset: dragOffset
        ) else { return }
        setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragOffset != nil else { return }
        dragOffset = nil
        onDragStateChanged?(false)
        // Persistence and placement/size reconciliation are intentionally
        // deferred until the drag ends. Doing that work for every high-rate
        // mouseDragged event can re-enter SwiftUI/AppKit layout and starve the
        // main event loop, which presents as a full application freeze.
        onUserMoved?(frame.origin)
    }
}

/// A small, non-activating overlay that follows the frontmost Codex window.
///
/// This intentionally owns a separate NSPanel instead of injecting a view into
/// ChatGPT/Codex. The App Server remains the source of usage data and the HUD
/// only presents the current model state.
@MainActor
final class FloatingHUDPanelController: NSObject {
    private let model: UsageViewModel
    var onShowDetails: (() -> Void)?
    var onOpenCodex: (() -> Void)?
    var onQuit: (() -> Void)?
    private var panel: NSPanel?
    private var refreshTimer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var modelObservation: AnyCancellable?
    private var visibilityRefreshTask: Task<Void, Never>?
    private var geometryRefreshTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    private let bottomRightPositionKey = "ui.floatingHUD.bottomRightOffset"
    private let anchorPositionKey = "ui.floatingHUD.anchor"
    private let relativePositionKey = "ui.floatingHUD.relativeOffset"
    private let legacyPositionKey = "ui.floatingHUD.position"
    private var lastCodexWindowFrame: NSRect?
    private var lastCodexVisibleFrame: NSRect?
    private var lastCodexProcessID: pid_t?
    private var trustedCodexApplicationIdentity: CodexApplicationPolicy.TrustedApplicationIdentity?
    private var lastPositionedCodexWindowFrame: NSRect?
    private var lastPositionedVisibleFrame: NSRect?
    private var lastPositionedProcessID: pid_t?
    private var lastPositionedPanelSize: NSSize?
    private var hasEstablishedPosition = false
    private var lastKnownSafePanelFrame: NSRect?
    private var positioningSessionGeneration: UInt64 = 0
    private var lastPlacement: HUDPlacement = .bottomRight
    private let layoutState = FloatingHUDLayoutState()
    private var isUserDraggingHUD = false
    /// Only a confirmed focus loss may hide the HUD. AX/Quartz and quota
    /// gaps retain the current panel without scheduling a timeout hide.
    private var focusLossTask: Task<Void, Never>?
    private var focusLossGeneration: UInt64 = 0
    private let focusLossGrace: Duration = .milliseconds(500)

    init(model: UsageViewModel) {
        self.model = model
        super.init()
    }

    func start() {
        guard panel == nil else {
            refreshVisibility()
            return
        }

        let rootView = CodexFloatingHUDView(
            model: model,
            layoutState: layoutState,
            pasteClipboard: { [weak self] completion in
                guard let self else {
                    completion(false)
                    return
                }
                self.pasteClipboard(completion: completion)
            },
            pasteAndSubmit: { [weak self] completion in
                guard let self else {
                    completion(false)
                    return
                }
                self.pasteAndSubmit(completion: completion)
            },
            promptShortcut: { [weak self] shortcut, completion in
                guard let self else {
                    completion(false)
                    return
                }
                self.pastePromptShortcut(shortcut, completion: completion)
            },
            showDetails: { [weak self] in self?.onShowDetails?() },
            openCodex: { [weak self] in self?.onOpenCodex?() },
            quit: { [weak self] in self?.onQuit?() },
            resetPosition: { [weak self] in self?.resetPosition() },
            refresh: { [weak self] in self?.model.refresh() },
            selectProfile: { [weak self] id in self?.model.selectProfile(id: id) },
            setAccountScope: { [weak self] scope in self?.model.setAccountScope(scope) },
            setNotificationsEnabled: { [weak self] enabled in self?.model.setNotificationsEnabled(enabled) },
            setQuotaRefreshInterval: { [weak self] seconds in self?.model.setQuotaRefreshInterval(seconds) },
            setAccountRefreshInterval: { [weak self] seconds in self?.model.setGlobalSyncInterval(seconds) },
            setTokenActivityRefreshInterval: { [weak self] seconds in self?.model.setTokenActivityRefreshInterval(seconds) },
            setCredentialWatchInterval: { [weak self] seconds in self?.model.setCredentialWatchInterval(seconds) },
            setHUDScaleLevel: { [weak self] level in self?.setHUDScaleLevel(level) },
            quotaRowCountChanged: { [weak self] count in self?.setQuotaRowCount(count) },
            accountInfoRowVisibilityChanged: { [weak self] visible in self?.setAccountInfoRowVisibility(visible) },
            checkForUpdates: { [weak self] in self?.model.checkForUpdates() },
            cancelUpdateCheck: { [weak self] in self?.model.cancelUpdateCheck() },
            openReleasePage: { [weak self] in self?.model.openUpdateReleasePage() }
        )
        let hostingView = FirstClickHostingView(rootView: rootView)
        let darkAppearance = NSAppearance(named: .darkAqua)
        hostingView.appearance = darkAppearance
        let newPanel = DraggableHUDPanel(
            contentRect: NSRect(origin: .zero, size: layoutState.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        // The SwiftUI rounded material owns the visible shape. Keeping the
        // host layer rectangular prevents AppKit from clipping the animated
        // edge glow into gray corner artifacts.
        hostingView.layer?.cornerRadius = 0
        hostingView.layer?.masksToBounds = false
        newPanel.contentView = hostingView
        newPanel.setContentSize(layoutState.size)
        newPanel.isReleasedWhenClosed = false
        newPanel.isFloatingPanel = true
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        newPanel.backgroundColor = .clear
        newPanel.appearance = darkAppearance
        newPanel.isOpaque = false
        newPanel.hasShadow = false
        newPanel.hidesOnDeactivate = false
        newPanel.ignoresMouseEvents = false
        newPanel.title = "Codex Usage HUD"
        newPanel.onUserMoved = { [weak self] origin in
            self?.savePosition(origin)
        }
        newPanel.onDragStateChanged = { [weak self] isDragging in
            self?.isUserDraggingHUD = isDragging
        }
        panel = newPanel

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestVisibilityRefresh()
            }
        }

        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.object as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                self?.handleApplicationTermination(application)
            }
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.requestVisibilityRefresh() }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.requestVisibilityRefresh() }
        }

        // Geometry depends only on quota rows/Credits and profile resets. A
        // narrow publisher keeps history, token-range, notification, login,
        // and status-item publications from scheduling even the cheap resize
        // path; visibility remains on the event-driven AX path plus fallback.
        modelObservation = Publishers.Merge(
            model.$snapshot.map { _ in () }.eraseToAnyPublisher(),
            model.$currentProfileID.map { _ in () }.eraseToAnyPublisher()
        ).sink { [weak self] _ in
            self?.requestGeometryRefresh()
        }

        // Visibility/placement uses AX and CGWindowList, so it is deliberately
        // sampled as a slow safety fallback. Model publications only refresh
        // cached geometry and never trigger a heavy system-window query.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestVisibilityRefresh()
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshVisibility()
        }
    }

    func stop() {
        cancelFocusLoss()
        visibilityRefreshTask?.cancel()
        visibilityRefreshTask = nil
        geometryRefreshTask?.cancel()
        geometryRefreshTask = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        workspaceObserver = nil
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
        }
        terminationObserver = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        modelObservation?.cancel()
        modelObservation = nil
        panel?.orderOut(nil)
        panel = nil
        isUserDraggingHUD = false
        invalidatePositioningSession(clearProcessID: true)
    }

    func resetPosition() {
        cancelFocusLoss()
        defaults.removeObject(forKey: bottomRightPositionKey)
        defaults.removeObject(forKey: anchorPositionKey)
        defaults.removeObject(forKey: relativePositionKey)
        defaults.removeObject(forKey: legacyPositionKey)
        lastPositionedCodexWindowFrame = nil
        lastPositionedVisibleFrame = nil
        lastPositionedProcessID = nil
        lastPositionedPanelSize = nil
        refreshVisibility()
    }

    /// Resize transaction for the seven persisted HUD levels.  The old panel
    /// size and origin are captured before calculating the new size so
    /// `resizedOrigin` can preserve the user's selected edge anchor.
    func setHUDScaleLevel(_ newLevel: HUDScaleLevel) {
        guard layoutState.scaleLevel != newLevel else { return }
        guard let panel else {
            layoutState.scaleLevel = newLevel
            newLevel.persist(to: defaults)
            return
        }

        let oldPanelSize = panel.frame.size
        let oldOrigin = panel.frame.origin
        let placement = layoutState.placement
        let newSize = FloatingHUDLayout.size(
            for: placement,
            scaleLevel: newLevel,
            quotaRowCount: layoutState.quotaRowCount,
            includesAccountInfoRow: layoutState.showsAccountInfoRow
        )
        let targetFrame = lastCodexWindowFrame
        let visibleFrame = lastCodexVisibleFrame
        let resizedOrigin: NSPoint
        if let targetFrame {
            resizedOrigin = HUDPlacementPolicy.resizedOrigin(
                origin: oldOrigin,
                targetFrame: targetFrame,
                oldPanelSize: oldPanelSize,
                newPanelSize: newSize,
                placement: placement
            )
        } else {
            resizedOrigin = oldOrigin
        }

        applySize(newSize, to: panel)
        let correctedOrigin = visibleFrame.map {
            clampedOrigin(resizedOrigin, panelSize: newSize, visibleFrame: $0)
        } ?? resizedOrigin
        panel.setFrameOrigin(correctedOrigin)
        layoutState.scaleLevel = newLevel
        newLevel.persist(to: defaults)
        if let targetFrame {
            saveAnchor(
                origin: correctedOrigin,
                targetFrame: targetFrame,
                panelSize: newSize,
                placement: placement
            )
        }
        lastPositionedPanelSize = newSize
        if hasEstablishedPosition, lastKnownSafePanelFrame != nil {
            lastKnownSafePanelFrame = panel.frame
            layoutState.hasEstablishedPosition = true
        }
    }

    /// Keeps the AppKit frame in lockstep with the number of quota windows
    /// actually published for the active account. A one-window Free account
    /// therefore has no empty second row, while a plan exposing an individual
    /// spend-control window grows to show the third row without changing the
    /// action/footer geometry.
    private func synchronizeQuotaRowCount(for panel: NSPanel) {
        let presentation = HUDQuotaPresentationPolicy.make(
            snapshot: model.snapshot,
            profileID: model.currentProfileID,
            now: model.currentDate
        )
        let newCount = max(1, presentation?.rowCount ?? 1)
        setQuotaRowCount(newCount, on: panel)
    }

    private func setQuotaRowCount(_ count: Int) {
        guard let panel else {
            layoutState.quotaRowCount = max(1, count)
            return
        }
        setQuotaRowCount(count, on: panel)
    }

    private func setQuotaRowCount(_ count: Int, on panel: NSPanel) {
        let newCount = max(1, count)
        guard newCount != layoutState.quotaRowCount else { return }

        let oldPanelSize = panel.frame.size
        let oldOrigin = panel.frame.origin
        let placement = layoutState.placement
        let newSize = FloatingHUDLayout.size(
            for: placement,
            scaleLevel: layoutState.scaleLevel,
            quotaRowCount: newCount,
            includesAccountInfoRow: layoutState.showsAccountInfoRow
        )
        let targetFrame = lastCodexWindowFrame
        let visibleFrame = lastCodexVisibleFrame
        let resizedOrigin: NSPoint
        if let targetFrame {
            resizedOrigin = HUDPlacementPolicy.resizedOrigin(
                origin: oldOrigin,
                targetFrame: targetFrame,
                oldPanelSize: oldPanelSize,
                newPanelSize: newSize,
                placement: placement
            )
        } else {
            resizedOrigin = oldOrigin
        }

        applySize(newSize, to: panel)
        let correctedOrigin = visibleFrame.map {
            clampedOrigin(resizedOrigin, panelSize: newSize, visibleFrame: $0)
        } ?? resizedOrigin
        panel.setFrameOrigin(correctedOrigin)
        layoutState.quotaRowCount = newCount
        if let targetFrame {
            saveAnchor(
                origin: correctedOrigin,
                targetFrame: targetFrame,
                panelSize: newSize,
                placement: placement
            )
        }
        lastPositionedPanelSize = newSize
        if hasEstablishedPosition, lastKnownSafePanelFrame != nil {
            lastKnownSafePanelFrame = panel.frame
            layoutState.hasEstablishedPosition = true
        }
    }

    private func setAccountInfoRowVisibility(_ visible: Bool) {
        guard let panel else {
            layoutState.showsAccountInfoRow = visible
            return
        }
        setAccountInfoRowVisibility(visible, on: panel)
    }

    private func setAccountInfoRowVisibility(_ visible: Bool, on panel: NSPanel) {
        guard visible != layoutState.showsAccountInfoRow else { return }

        let oldPanelSize = panel.frame.size
        let oldOrigin = panel.frame.origin
        let placement = layoutState.placement
        let newSize = FloatingHUDLayout.size(
            for: placement,
            scaleLevel: layoutState.scaleLevel,
            quotaRowCount: layoutState.quotaRowCount,
            includesAccountInfoRow: visible
        )
        let targetFrame = lastCodexWindowFrame
        let visibleFrame = lastCodexVisibleFrame
        let resizedOrigin: NSPoint
        if let targetFrame {
            resizedOrigin = HUDPlacementPolicy.resizedOrigin(
                origin: oldOrigin,
                targetFrame: targetFrame,
                oldPanelSize: oldPanelSize,
                newPanelSize: newSize,
                placement: placement
            )
        } else {
            resizedOrigin = oldOrigin
        }

        applySize(newSize, to: panel)
        let correctedOrigin = visibleFrame.map {
            clampedOrigin(resizedOrigin, panelSize: newSize, visibleFrame: $0)
        } ?? resizedOrigin
        panel.setFrameOrigin(correctedOrigin)
        layoutState.showsAccountInfoRow = visible
        if let targetFrame {
            saveAnchor(
                origin: correctedOrigin,
                targetFrame: targetFrame,
                panelSize: newSize,
                placement: placement
            )
        }
        lastPositionedPanelSize = newSize
        if hasEstablishedPosition, lastKnownSafePanelFrame != nil {
            lastKnownSafePanelFrame = panel.frame
            layoutState.hasEstablishedPosition = true
        }
    }

    private func pasteClipboard(completion: @escaping (Bool) -> Void) {
        ClipboardPasteService.pasteToCodex(
            processID: lastCodexProcessID,
            completion: completion
        )
    }

    private func pasteAndSubmit(completion: @escaping (Bool) -> Void) {
        ClipboardPasteService.pasteAndSubmitToCodex(
            processID: lastCodexProcessID,
            completion: completion
        )
    }

    private func pastePromptShortcut(
        _ shortcut: CodexPromptShortcut,
        completion: @escaping (Bool) -> Void
    ) {
        ClipboardPasteService.pasteTemporaryTextToCodex(
            shortcut,
            processID: lastCodexProcessID,
            completion: completion
        )
    }

    private func refreshVisibility() {
        guard let panel else { return }
        // Automatic positioning and visibility work must not compete with a
        // user-controlled drag. The panel's final frame is persisted from
        // mouseUp, after which the next scheduled refresh can resume.
        guard !isUserDraggingHUD else { return }
        guard model.floatingHUDEnabled else {
            hideAndInvalidatePositioningSession(panel)
            return
        }

        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        guard let frontmostApplication else {
            // Unknown identity fails closed. Keep the same-process session and
            // safe frame so a later authoritative Codex observation can
            // restore it without treating an unknown app as Codex.
            hideImmediately(panel)
            return
        }
        guard isCodexApplication(frontmostApplication) else {
            scheduleFocusLoss(panel)
            return
        }
        cancelFocusLoss()
        let codexApp = frontmostApplication
        layoutState.isCodexFocused = true

        if let previousProcessID = lastCodexProcessID,
           previousProcessID != codexApp.processIdentifier {
            // A process transition is a session boundary even when the old
            // Codex has not delivered its termination notification yet.
            panel.orderOut(nil)
            invalidatePendingVisibilityCallbacks()
            resetEstablishedPositionForNewCodexProcess()
        }
        lastCodexProcessID = codexApp.processIdentifier
        synchronizeQuotaRowCount(for: panel)
        switch position(panel, beside: codexApp) {
        case .positioned:
            panel.alphaValue = 1.0
            // Re-ordering the hosting panel while a SwiftUI context menu is
            // open makes AppKit recalculate the menu anchor and produces a
            // visible wobble. Only show after a successful first placement.
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        case .retainedExistingPosition:
            guard restoreRetainedPositionIfPossible(panel) else {
                hideImmediately(panel)
                return
            }
            panel.alphaValue = 1.0
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        case .unavailable:
            // Without an authenticated safe frame, even a currently visible
            // panel is not evidence of a trustworthy position.
            if panel.isVisible {
                hideImmediately(panel)
            }
            return
        }
    }

    /// Coalesce bursts of model/workspace notifications into one visibility
    /// reconciliation.  The short delay lets @Published finish assigning its
    /// new value while preventing every intermediate publication from doing a
    /// full AX + CGWindowList pass on the main actor.
    private func requestVisibilityRefresh() {
        guard visibilityRefreshTask == nil else { return }
        let expectedGeneration = positioningSessionGeneration
        visibilityRefreshTask = Task { @MainActor [weak self] in
            defer { self?.visibilityRefreshTask = nil }
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled,
                  let self,
                  expectedGeneration == self.positioningSessionGeneration else { return }
            self.refreshVisibility()
        }
    }

    /// Cheap model-driven sizing path. It uses the last authoritative window
    /// and screen frames already read by the event/fallback reconciler and
    /// therefore avoids AX/CGWindowList work on every @Published emission.
    private func requestGeometryRefresh() {
        guard geometryRefreshTask == nil else { return }
        geometryRefreshTask = Task { @MainActor [weak self] in
            defer { self?.geometryRefreshTask = nil }
            await Task.yield()
            guard let self, !Task.isCancelled, !self.isUserDraggingHUD,
                  let panel = self.panel else { return }
            self.synchronizeQuotaRowCount(for: panel)
        }
    }

    private func isCodexApplication(_ application: NSRunningApplication) -> Bool {
        guard CodexApplicationPolicy.isCodexApplication(bundleIdentifier: application.bundleIdentifier),
              let bundleURL = application.bundleURL else {
            trustedCodexApplicationIdentity = nil
            return false
        }

        let processIdentifier = application.processIdentifier
        guard let launchDate = application.launchDate else {
            trustedCodexApplicationIdentity = nil
            return CodexApplicationPolicy.isTrustedBundle(at: bundleURL)
        }
        if let trustedCodexApplicationIdentity,
           trustedCodexApplicationIdentity.matches(
               processIdentifier: processIdentifier,
               launchDate: launchDate,
               bundleURL: bundleURL
           ) {
            return true
        }

        let isTrusted = CodexApplicationPolicy.isTrustedBundle(at: bundleURL)
        trustedCodexApplicationIdentity = isTrusted
            ? CodexApplicationPolicy.TrustedApplicationIdentity(
                processIdentifier: processIdentifier,
                launchDate: launchDate,
                bundleURL: bundleURL
            )
            : nil
        return isTrusted
    }

    private func invalidatePendingVisibilityCallbacks() {
        cancelFocusLoss()
        visibilityRefreshTask?.cancel()
        visibilityRefreshTask = nil
        positioningSessionGeneration &+= 1
    }

    private func resetEstablishedPositionForNewCodexProcess() {
        hasEstablishedPosition = false
        layoutState.hasEstablishedPosition = false
        lastKnownSafePanelFrame = nil
        lastCodexWindowFrame = nil
        lastCodexVisibleFrame = nil
        lastPositionedCodexWindowFrame = nil
        lastPositionedVisibleFrame = nil
        lastPositionedProcessID = nil
        lastPositionedPanelSize = nil
        lastCodexProcessID = nil
    }

    private func invalidatePositioningSession(clearProcessID: Bool) {
        positioningSessionGeneration &+= 1
        cancelFocusLoss()
        hasEstablishedPosition = false
        layoutState.hasEstablishedPosition = false
        lastKnownSafePanelFrame = nil
        lastCodexWindowFrame = nil
        lastCodexVisibleFrame = nil
        lastPositionedCodexWindowFrame = nil
        lastPositionedVisibleFrame = nil
        lastPositionedProcessID = nil
        lastPositionedPanelSize = nil
        if clearProcessID {
            lastCodexProcessID = nil
            trustedCodexApplicationIdentity = nil
        }
    }

    private func hideAndInvalidatePositioningSession(_ panel: NSPanel) {
        panel.orderOut(nil)
        invalidatePositioningSession(clearProcessID: true)
        layoutState.isCodexFocused = false
    }

    private func restoreRetainedPositionIfPossible(_ panel: NSPanel) -> Bool {
        guard hasEstablishedPosition,
              let safeFrame = lastKnownSafePanelFrame else { return false }
        panel.setFrame(safeFrame, display: false)
        return true
    }

    private func handleApplicationTermination(_ application: NSRunningApplication) {
        guard let trackedProcessID = lastCodexProcessID,
              trackedProcessID == application.processIdentifier else { return }
        panel?.orderOut(nil)
        invalidatePositioningSession(clearProcessID: true)
        layoutState.isCodexFocused = false
    }

    private func markPositionEstablished(_ panel: NSPanel) {
        lastKnownSafePanelFrame = panel.frame
        hasEstablishedPosition = true
        layoutState.hasEstablishedPosition = true
    }

    private func position(_ panel: NSPanel, beside application: NSRunningApplication) -> HUDPositionResult {
        guard let quartzTargetFrame = codexWindowFrame(for: application.processIdentifier),
              let displayMapping = quartzDisplayMapping(for: quartzTargetFrame) else {
            return HUDVisibilityPolicy.positionResult(
                hasValidFrame: false,
                hasRetainableSafeFrame: hasEstablishedPosition
                    && lastKnownSafePanelFrame != nil
                    && lastCodexProcessID == application.processIdentifier
            )
        }
        let targetFrame = appKitWindowFrame(from: quartzTargetFrame, mapping: displayMapping)
        // Focused-window metadata is authoritative. If it is temporarily
        // unavailable, only an authenticated safe frame may be restored.
        // A hidden panel remains hidden until a new frame is verifiable.
        // Use only the display selected by the validated Quartz geometry. If
        // the window list is momentarily unavailable while macOS changes
        // Spaces/displays, the guard above keeps a hidden HUD hidden or retains
        // a visible HUD without moving it to a guessed screen.
        let visibleFrame = displayMapping.screen.visibleFrame

        lastCodexWindowFrame = targetFrame
        lastCodexVisibleFrame = visibleFrame

        // The HUD is refreshed every second so it can follow Codex, but a
        // repeated frame read must not re-apply the same anchor. Window-list
        // coordinates can vary by a fraction of a point between reads; doing
        // a fresh setFrameOrigin on every tick makes the panel appear to drift
        // even when the user did not move anything.
        if isAlreadyPositioned(
            processID: application.processIdentifier,
            targetFrame: targetFrame,
            visibleFrame: visibleFrame,
            panel: panel
        ) {
            markPositionEstablished(panel)
            return .positioned
        }
        defer {
            lastPositionedProcessID = application.processIdentifier
            lastPositionedCodexWindowFrame = targetFrame
            lastPositionedVisibleFrame = visibleFrame
            lastPositionedPanelSize = panel.frame.size
        }

        if let anchor = savedAnchor() {
            lastPlacement = anchor.placement
            layoutState.placement = anchor.placement
            let size = FloatingHUDLayout.size(
                for: anchor.placement,
                scaleLevel: layoutState.scaleLevel,
                quotaRowCount: layoutState.quotaRowCount,
                includesAccountInfoRow: layoutState.showsAccountInfoRow
            )
            applySize(size, to: panel)
            let origin = HUDPlacementPolicy.origin(
                for: anchor,
                targetFrame: targetFrame,
                panelSize: size
            )
            panel.setFrameOrigin(clampedOrigin(origin, panelSize: size, visibleFrame: visibleFrame))
            saveAnchor(origin: panel.frame.origin, targetFrame: targetFrame, panelSize: size, placement: anchor.placement)
            markPositionEstablished(panel)
            return .positioned
        }

        let panelFrame = panel.frame
        let initialPlacement = HUDPlacementPolicy.placement(
            targetFrame: targetFrame,
            hudFrame: panelFrame,
            previous: lastPlacement
        )

        // Migrate the previous right/bottom anchor into the new edge-aware
        // anchor. Existing builds only stored a bottom offset, so preserve it
        // as a bottom placement once, then let future drags select top/bottom.
        if let bottomRightOffset = savedBottomRightOffset() {
            let previousSize = FloatingHUDLayout.previousWideSize
            let oldOrigin = CGPoint(
                x: targetFrame.maxX - previousSize.width - bottomRightOffset.x,
                y: targetFrame.minY + bottomRightOffset.y
            )
            let placement = HUDPlacementPolicy.placement(
                targetFrame: targetFrame,
                hudFrame: CGRect(origin: oldOrigin, size: previousSize),
                previous: initialPlacement
            )
            lastPlacement = placement
            layoutState.placement = placement
            let size = FloatingHUDLayout.size(
                for: placement,
                scaleLevel: layoutState.scaleLevel,
                quotaRowCount: layoutState.quotaRowCount,
                includesAccountInfoRow: layoutState.showsAccountInfoRow
            )
            applySize(size, to: panel)
            let origin = HUDPlacementPolicy.resizedOrigin(
                origin: oldOrigin,
                targetFrame: targetFrame,
                oldPanelSize: previousSize,
                newPanelSize: size,
                placement: placement
            )
            panel.setFrameOrigin(clampedOrigin(origin, panelSize: size, visibleFrame: visibleFrame))
            saveAnchor(origin: panel.frame.origin, targetFrame: targetFrame, panelSize: size, placement: placement)
            markPositionEstablished(panel)
            return .positioned
        }

        // Migrate the previous left/bottom-relative position into the new
        // right/bottom anchor without visibly moving the HUD.
        if let relativeOffset = savedRelativeOffset() {
            let origin = NSPoint(
                x: targetFrame.minX + relativeOffset.x,
                y: targetFrame.minY + relativeOffset.y
            )
            let placement = HUDPlacementPolicy.placement(
                targetFrame: targetFrame,
                hudFrame: CGRect(origin: origin, size: panelFrame.size),
                previous: initialPlacement
            )
            lastPlacement = placement
            layoutState.placement = placement
            let size = FloatingHUDLayout.size(
                for: placement,
                scaleLevel: layoutState.scaleLevel,
                quotaRowCount: layoutState.quotaRowCount,
                includesAccountInfoRow: layoutState.showsAccountInfoRow
            )
            applySize(size, to: panel)
            let resizedOrigin = HUDPlacementPolicy.resizedOrigin(
                origin: origin,
                targetFrame: targetFrame,
                oldPanelSize: panelFrame.size,
                newPanelSize: size,
                placement: placement
            )
            panel.setFrameOrigin(clampedOrigin(resizedOrigin, panelSize: size, visibleFrame: visibleFrame))
            saveAnchor(origin: panel.frame.origin, targetFrame: targetFrame, panelSize: size, placement: placement)
            markPositionEstablished(panel)
            return .positioned
        }

        // Migrate a position saved by the first draggable build. The old value
        // was an absolute screen coordinate; convert it once to the new
        // Codex-relative right/bottom anchor so future window movement and
        // resizing remain synchronized.
        if let legacyOrigin = legacySavedPosition() {
            let previousSize = FloatingHUDLayout.previousLegacySize
            let placement = HUDPlacementPolicy.placement(
                targetFrame: targetFrame,
                hudFrame: CGRect(origin: legacyOrigin, size: previousSize),
                previous: initialPlacement
            )
            lastPlacement = placement
            layoutState.placement = placement
            let size = FloatingHUDLayout.size(
                for: placement,
                scaleLevel: layoutState.scaleLevel,
                quotaRowCount: layoutState.quotaRowCount,
                includesAccountInfoRow: layoutState.showsAccountInfoRow
            )
            applySize(size, to: panel)
            let resizedOrigin = HUDPlacementPolicy.resizedOrigin(
                origin: legacyOrigin,
                targetFrame: targetFrame,
                oldPanelSize: previousSize,
                newPanelSize: size,
                placement: placement
            )
            panel.setFrameOrigin(clampedOrigin(resizedOrigin, panelSize: size, visibleFrame: visibleFrame))
            saveAnchor(origin: panel.frame.origin, targetFrame: targetFrame, panelSize: size, placement: placement)
            markPositionEstablished(panel)
            return .positioned
        }

        lastPlacement = .bottomRight
        layoutState.placement = .bottomRight
        let size = layoutState.size
        applySize(size, to: panel)
        var x = targetFrame.maxX - size.width - 18
        var y = targetFrame.maxY - size.height - 18
        x = min(x, visibleFrame.maxX - size.width - 8)
        x = max(x, visibleFrame.minX + 8)
        y = min(y, visibleFrame.maxY - size.height - 8)
        y = max(y, visibleFrame.minY + 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        saveAnchor(origin: panel.frame.origin, targetFrame: targetFrame, panelSize: size, placement: .bottomRight)
        markPositionEstablished(panel)
        return .positioned
    }

    private func applySize(_ size: NSSize, to panel: NSPanel) {
        guard panel.frame.size != size else { return }
        panel.setContentSize(size)
    }

    private func scheduleFocusLoss(_ panel: NSPanel) {
        guard panel.isVisible, focusLossTask == nil else { return }
        focusLossGeneration &+= 1
        let generation = focusLossGeneration
        let expectedPositioningGeneration = positioningSessionGeneration
        let expectedProcessID = lastCodexProcessID
        let grace = focusLossGrace
        focusLossTask = Task { @MainActor [weak self, weak panel] in
            do {
                try await Task.sleep(for: grace)
            } catch {
                return
            }
            guard let self,
                  expectedPositioningGeneration == self.positioningSessionGeneration,
                  expectedProcessID == self.lastCodexProcessID,
                  HUDVisibilityPolicy.shouldApplyFocusLoss(
                      scheduledGeneration: generation,
                      currentGeneration: self.focusLossGeneration
                  ),
                  !Task.isCancelled,
                  let panel,
                  panel.isVisible else { return }

            // A nil frontmost application is still unknown focus. Only a
            // concrete non-Codex application may confirm the hide.
            guard let frontmost = NSWorkspace.shared.frontmostApplication,
                  !self.isCodexApplication(frontmost) else {
                self.focusLossTask = nil
                return
            }
            self.focusLossTask = nil
            self.focusLossGeneration &+= 1
            self.layoutState.isCodexFocused = false
            panel.orderOut(nil)
        }
    }

    private func cancelFocusLoss() {
        focusLossGeneration &+= 1
        focusLossTask?.cancel()
        focusLossTask = nil
    }

    private func hideImmediately(_ panel: NSPanel) {
        cancelFocusLoss()
        layoutState.isCodexFocused = false
        panel.orderOut(nil)
    }

    private func savedAnchor() -> HUDAnchor? {
        guard let values = defaults.array(forKey: anchorPositionKey) as? [Double], values.count == 3,
              let placement = HUDPlacement(rawValue: Int(values[2])) else { return nil }
        return HUDAnchor(
            rightInset: CGFloat(values[0]),
            verticalInset: CGFloat(values[1]),
            placement: placement
        )
    }

    private func saveAnchor(origin: NSPoint, targetFrame: NSRect, panelSize: NSSize, placement: HUDPlacement) {
        let anchor = HUDPlacementPolicy.anchor(
            origin: origin,
            targetFrame: targetFrame,
            panelSize: panelSize,
            placement: placement
        )
        defaults.set([
            Double(anchor.rightInset),
            Double(anchor.verticalInset),
            Double(anchor.placement.rawValue)
        ], forKey: anchorPositionKey)
        defaults.removeObject(forKey: bottomRightPositionKey)
        defaults.removeObject(forKey: relativePositionKey)
        defaults.removeObject(forKey: legacyPositionKey)
    }

    private func savedRelativeOffset() -> NSPoint? {
        guard let values = defaults.array(forKey: relativePositionKey) as? [Double], values.count == 2 else {
            return nil
        }
        return NSPoint(x: values[0], y: values[1])
    }

    private func savedBottomRightOffset() -> NSPoint? {
        guard let values = defaults.array(forKey: bottomRightPositionKey) as? [Double], values.count == 2 else {
            return nil
        }
        return NSPoint(x: values[0], y: values[1])
    }

    private func legacySavedPosition() -> NSPoint? {
        guard let values = defaults.array(forKey: legacyPositionKey) as? [Double], values.count == 2 else {
            return nil
        }
        return NSPoint(x: values[0], y: values[1])
    }

    private func savePosition(_ origin: NSPoint) {
        guard let codexWindowFrame = lastCodexWindowFrame,
              let panel else {
            defaults.set([Double(origin.x), Double(origin.y)], forKey: legacyPositionKey)
            return
        }

        let placement = HUDPlacementPolicy.placement(
            targetFrame: codexWindowFrame,
            hudFrame: NSRect(origin: origin, size: panel.frame.size),
            previous: lastPlacement
        )
        lastPlacement = placement
        layoutState.placement = placement
        let newSize = FloatingHUDLayout.size(
            for: placement,
            scaleLevel: layoutState.scaleLevel,
            quotaRowCount: layoutState.quotaRowCount,
            includesAccountInfoRow: layoutState.showsAccountInfoRow
        )
        let resizedOrigin = HUDPlacementPolicy.resizedOrigin(
            origin: origin,
            targetFrame: codexWindowFrame,
            oldPanelSize: panel.frame.size,
            newPanelSize: newSize,
            placement: placement
        )
        applySize(newSize, to: panel)
        panel.setFrameOrigin(resizedOrigin)
        saveAnchor(origin: resizedOrigin, targetFrame: codexWindowFrame, panelSize: newSize, placement: placement)
        if hasEstablishedPosition, lastKnownSafePanelFrame != nil {
            lastKnownSafePanelFrame = panel.frame
            layoutState.hasEstablishedPosition = true
        }
        lastPositionedProcessID = lastCodexProcessID
        lastPositionedCodexWindowFrame = codexWindowFrame
        lastPositionedVisibleFrame = lastCodexVisibleFrame
        lastPositionedPanelSize = panel.frame.size
    }

    private func isAlreadyPositioned(
        processID: pid_t,
        targetFrame: NSRect?,
        visibleFrame: NSRect,
        panel: NSPanel
    ) -> Bool {
        guard hasEstablishedPosition,
              lastKnownSafePanelFrame != nil,
              lastCodexProcessID == processID,
              lastPositionedProcessID == processID,
              approximatelyEqual(lastPositionedVisibleFrame, visibleFrame),
              approximatelyEqual(lastPositionedCodexWindowFrame, targetFrame),
              lastPositionedPanelSize == panel.frame.size,
              panel.isVisible else {
            return false
        }
        return true
    }

    private func approximatelyEqual(_ lhs: NSRect?, _ rhs: NSRect?, tolerance: CGFloat = 1.0) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return abs(lhs.minX - rhs.minX) <= tolerance
                && abs(lhs.minY - rhs.minY) <= tolerance
                && abs(lhs.width - rhs.width) <= tolerance
                && abs(lhs.height - rhs.height) <= tolerance
        default:
            return false
        }
    }

    private func clampedOrigin(_ origin: NSPoint, panelSize: NSSize, visibleFrame: NSRect) -> NSPoint {
        let x = min(max(origin.x, visibleFrame.minX + 8), visibleFrame.maxX - panelSize.width - 8)
        let y = min(max(origin.y, visibleFrame.minY + 8), visibleFrame.maxY - panelSize.height - 8)
        return NSPoint(x: x, y: y)
    }

    private struct QuartzDisplayMapping {
        let screen: NSScreen
        let quartzFrame: CGRect
        let scaleX: CGFloat
        let scaleY: CGFloat
    }

    /// Match Quartz window-list coordinates to the NSScreen that owns them.
    /// CGDisplayBounds uses the global Quartz display space (which can have
    /// negative origins for a monitor above/left of the primary display), so
    /// matching by an arbitrary AppKit midpoint is incorrect on multi-monitor
    /// layouts.
    private func quartzDisplayMapping(for windowFrame: CGRect) -> QuartzDisplayMapping? {
        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        let candidates = NSScreen.screens.compactMap { screen -> QuartzDisplayMapping? in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
            let quartzFrame = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            guard quartzFrame.width > 0, quartzFrame.height > 0 else { return nil }
            // `.optionAll` can return a window from a Space that is not
            // currently visible. It still must belong to a real display before
            // AppKit coordinates are derived; otherwise selecting a zero-score
            // screen would be a guessed position.
            let intersection = quartzFrame.intersection(windowFrame)
            let hasPositiveOverlap = intersection.width > 0 && intersection.height > 0
            guard quartzFrame.contains(center) || hasPositiveOverlap else { return nil }
            return QuartzDisplayMapping(
                screen: screen,
                quartzFrame: quartzFrame,
                scaleX: screen.frame.width / quartzFrame.width,
                scaleY: screen.frame.height / quartzFrame.height
            )
        }

        // Prefer the unique display containing the window center. If the
        // window spans displays, select a unique largest positive overlap;
        // ties are ambiguous and must remain unavailable rather than guessing.
        let centered = candidates.filter { $0.quartzFrame.contains(center) }
        if centered.count == 1 { return centered[0] }
        guard centered.isEmpty else { return nil }

        let scored = candidates.map { mapping in
            let intersection = mapping.quartzFrame.intersection(windowFrame)
            let area = max(0, intersection.width) * max(0, intersection.height)
            return (mapping, area)
        }.sorted { $0.1 > $1.1 }
        guard let best = scored.first, best.1 > 0 else { return nil }
        guard scored.dropFirst().allSatisfy({ $0.1 < best.1 }) else { return nil }
        return best.0
    }

    /// Window-list coordinates use a top-left origin. Convert to AppKit's
    /// bottom-left coordinate system using the matched display's own bounds.
    private func appKitWindowFrame(from windowFrame: CGRect, mapping: QuartzDisplayMapping) -> NSRect {
        let quartz = mapping.quartzFrame
        let x = mapping.screen.frame.minX
            + (windowFrame.minX - quartz.minX) * mapping.scaleX
        let y = mapping.screen.frame.minY
            + (quartz.maxY - windowFrame.maxY) * mapping.scaleY
        let width = windowFrame.width * mapping.scaleX
        let height = windowFrame.height * mapping.scaleY
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func codexWindowFrame(for processID: pid_t) -> CGRect? {
        let application = NSRunningApplication(processIdentifier: processID)
        let focusedBounds = application.flatMap(CodexFocusedWindowReader.focusedWindowBounds)
        // `.optionAll` is required because the HUD joins all Spaces and the
        // focused Codex window may be reported outside the active Space.
        // Identity remains fail-closed through PID/layer/size and AX geometry.
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        let candidates = windows.compactMap { info -> CGRect? in
            guard let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID == processID,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  width >= 300, height >= 200 else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }
        // AX and Quartz normally share the same top-left global coordinate
        // space. Require exactly one close match so two windows cannot be
        // cross-wired; when AX is unavailable, only a single filtered Quartz
        // candidate is accepted, preserving the same fail-closed behavior.
        return HUDVisibilityPolicy.uniqueQuartzWindowMatch(
            focusedBounds: focusedBounds,
            candidates: candidates
        )
    }
}

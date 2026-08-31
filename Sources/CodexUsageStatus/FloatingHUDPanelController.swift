import AppKit
import Combine
import CoreGraphics
import SwiftUI

private enum FloatingHUDLayout {
    // C layout: both placements use one scalable panel geometry. Placement
    // changes the anchor only; it never creates a second size contract.
    static let bottomRightSize = NSSize(width: 416, height: 240)
    static let topRightSize = NSSize(width: 416, height: 240)
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
        includesCredits: Bool = false
    ) -> NSSize {
        _ = placement
        let metrics = HUDMetrics(scaleLevel: scaleLevel)
        let size = metrics.panelSize(quotaRowCount: quotaRowCount, includesCredits: includesCredits)
        return NSSize(width: size.width, height: size.height)
    }
}

@MainActor
private final class FloatingHUDLayoutState: ObservableObject {
    @Published var placement: HUDPlacement = .bottomRight
    @Published var scaleLevel: HUDScaleLevel = HUDScaleLevel.load()
    /// The HUD is a Codex-only overlay. This state is also used by the view
    /// to keep actions disabled during a focus transition.
    @Published var isCodexFocused = true
    @Published var hasEstablishedPosition = false
    @Published var quotaRowCount: Int = 1
    @Published var hasCredits = false

    var size: NSSize {
        FloatingHUDLayout.size(
            for: placement,
            scaleLevel: scaleLevel,
            quotaRowCount: quotaRowCount,
            includesCredits: hasCredits
        )
    }
}

private final class DraggableHUDPanel: NSPanel {
    var onUserMoved: ((NSPoint) -> Void)?
    private var dragOffset: NSPoint?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        dragOffset = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOffset else { return }
        let mouseLocation = NSEvent.mouseLocation
        let origin = NSPoint(
            x: mouseLocation.x - dragOffset.x,
            y: mouseLocation.y - dragOffset.y
        )
        setFrameOrigin(origin)
        onUserMoved?(origin)
    }

    override func mouseUp(with event: NSEvent) {
        dragOffset = nil
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
    private let gitCoordinator: GitWorkspaceCoordinator
    var onShowDetails: (() -> Void)?
    var onShowGitWorkspace: (() -> Void)?
    var onOpenCodex: (() -> Void)?
    var onQuit: (() -> Void)?
    private var panel: NSPanel?
    private var refreshTimer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var modelObservation: AnyCancellable?
    private let defaults = UserDefaults.standard
    private let bottomRightPositionKey = "ui.floatingHUD.bottomRightOffset"
    private let anchorPositionKey = "ui.floatingHUD.anchor"
    private let relativePositionKey = "ui.floatingHUD.relativeOffset"
    private let legacyPositionKey = "ui.floatingHUD.position"
    private var lastCodexWindowFrame: NSRect?
    private var lastCodexVisibleFrame: NSRect?
    private var lastCodexProcessID: pid_t?
    private var lastPositionedCodexWindowFrame: NSRect?
    private var lastPositionedVisibleFrame: NSRect?
    private var lastPositionedProcessID: pid_t?
    private var lastPositionedPanelSize: NSSize?
    private var hasEstablishedPosition = false
    private var lastKnownSafePanelFrame: NSRect?
    private var positioningSessionGeneration: UInt64 = 0
    private var lastPlacement: HUDPlacement = .bottomRight
    private let layoutState = FloatingHUDLayoutState()
    /// Only a confirmed focus loss may hide the HUD. AX/Quartz and quota
    /// gaps retain the current panel without scheduling a timeout hide.
    private var focusLossTask: Task<Void, Never>?
    private var focusLossGeneration: UInt64 = 0
    private let focusLossGrace: Duration = .milliseconds(500)

    init(model: UsageViewModel, gitCoordinator: GitWorkspaceCoordinator) {
        self.model = model
        self.gitCoordinator = gitCoordinator
        super.init()
    }

    func start() {
        guard panel == nil else {
            refreshVisibility()
            return
        }

        let rootView = CodexFloatingHUDView(
            model: model,
            gitCoordinator: gitCoordinator,
            layoutState: layoutState,
            pasteClipboard: { [weak self] in self?.pasteClipboard() },
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
            showGitWorkspace: { [weak self] in self?.onShowGitWorkspace?() },
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
            creditsVisibilityChanged: { [weak self] visible in self?.setCreditsVisibility(visible) },
            checkForUpdates: { [weak self] in self?.model.checkForUpdates() },
            cancelUpdateCheck: { [weak self] in self?.model.cancelUpdateCheck() },
            downloadAvailableUpdate: { [weak self] in self?.model.downloadAvailableUpdate() },
            revealDownloadedUpdate: { [weak self] in self?.model.revealDownloadedUpdate() },
            installDownloadedUpdate: { [weak self] in self?.model.installDownloadedUpdate() },
            openReleasePage: { [weak self] in self?.model.openUpdateReleasePage() }
        )
        let hostingView = NSHostingView(rootView: rootView)
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
        newPanel.isOpaque = false
        newPanel.hasShadow = false
        newPanel.hidesOnDeactivate = false
        newPanel.ignoresMouseEvents = false
        newPanel.title = "Codex Usage HUD"
        newPanel.onUserMoved = { [weak self] origin in
            self?.savePosition(origin)
        }
        panel = newPanel

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let expectedGeneration = self.positioningSessionGeneration
            Task { @MainActor [weak self] in
                guard let self,
                      expectedGeneration == self.positioningSessionGeneration else { return }
                self.refreshVisibility()
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

        modelObservation = model.objectWillChange.sink { [weak self] _ in
            // @Published emits before the value is assigned. Hop to the next
            // main-actor turn so the HUD sees the new preference/state.
            guard let self else { return }
            let expectedGeneration = self.positioningSessionGeneration
            Task { @MainActor [weak self] in
                guard let self,
                      expectedGeneration == self.positioningSessionGeneration else { return }
                self.refreshVisibility()
            }
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let expectedGeneration = self.positioningSessionGeneration
            Task { @MainActor [weak self] in
                guard let self,
                      expectedGeneration == self.positioningSessionGeneration else { return }
                self.refreshVisibility()
            }
        }
        refreshVisibility()
    }

    func stop() {
        cancelFocusLoss()
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
        modelObservation?.cancel()
        modelObservation = nil
        panel?.orderOut(nil)
        panel = nil
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
            includesCredits: layoutState.hasCredits
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
            includesCredits: layoutState.hasCredits
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

    private func synchronizeCreditsVisibility(for panel: NSPanel) {
        guard let presentation = HUDQuotaPresentationPolicy.make(
            snapshot: model.snapshot,
            profileID: model.currentProfileID,
            now: model.currentDate
        ) else { return }
        setCreditsVisibility(presentation.credits?.isDisplayable == true, on: panel)
    }

    private func setCreditsVisibility(_ visible: Bool) {
        guard let panel else {
            layoutState.hasCredits = visible
            return
        }
        setCreditsVisibility(visible, on: panel)
    }

    private func setCreditsVisibility(_ visible: Bool, on panel: NSPanel) {
        guard visible != layoutState.hasCredits else { return }

        let oldPanelSize = panel.frame.size
        let oldOrigin = panel.frame.origin
        let placement = layoutState.placement
        let newSize = FloatingHUDLayout.size(
            for: placement,
            scaleLevel: layoutState.scaleLevel,
            quotaRowCount: layoutState.quotaRowCount,
            includesCredits: visible
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
        layoutState.hasCredits = visible
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

    private func pasteClipboard() {
        ClipboardPasteService.pasteToCodex(processID: lastCodexProcessID)
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
        synchronizeCreditsVisibility(for: panel)
        gitCoordinator.refreshIfNeeded()
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

    private func isCodexApplication(_ application: NSRunningApplication) -> Bool {
        CodexApplicationPolicy.isCodexApplication(
            bundleIdentifier: application.bundleIdentifier,
            localizedName: application.localizedName,
            bundlePath: application.bundleURL?.path
        )
    }

    private func invalidatePendingVisibilityCallbacks() {
        cancelFocusLoss()
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
                includesCredits: layoutState.hasCredits
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
                includesCredits: layoutState.hasCredits
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
                includesCredits: layoutState.hasCredits
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
                includesCredits: layoutState.hasCredits
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
            includesCredits: layoutState.hasCredits
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
        let focusedBounds = application.flatMap(CodexWorkspaceResolver.focusedWindowBounds)
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

private struct HUDQuotaRow: View {
    let kind: HUDQuotaWindowKind
    let presentation: HUDQuotaWindowPresentation?
    let isUpdating: Bool
    let width: CGFloat
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    init(
        kind: HUDQuotaWindowKind,
        presentation: HUDQuotaWindowPresentation?,
        isUpdating: Bool,
        width: CGFloat,
        height: CGFloat
    ) {
        self.kind = kind
        self.presentation = presentation
        self.isUpdating = isUpdating
        self.width = width
        self.height = height
    }

    private var accent: Color {
        switch kind {
        case .fiveHour: return HUDColorPalette.fiveHour
        case .sevenDay: return HUDColorPalette.sevenDay
        case .gptReserveWeekly: return HUDColorPalette.gptReserveWeekly
        }
    }

    private var systemImage: String {
        "clock"
    }

    private var fillFraction: CGFloat {
        CGFloat(max(0, min(1, presentation?.fillFraction ?? 0)))
    }

    private var percentText: String {
        presentation.map { "\($0.remainingPercent)%" } ?? "—%"
    }

    private var resetText: String {
        presentation?.resetDescription ?? (isUpdating ? "更新中" : "未提供")
    }

    private var cornerRadius: CGFloat {
        max(4, height * 0.12)
    }

    private var scaleFactor: CGFloat {
        height / HUDMetrics.canonicalQuotaRowHeight
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(isUpdating ? 0.18 : 0.24))
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(accent.opacity(isUpdating ? 0.32 : 0.58))
                .frame(width: width * fillFraction)

            HStack(spacing: max(5, height * 0.18)) {
                Image(systemName: systemImage)
                    .font(.system(size: height * 0.42, weight: .semibold))
                    .frame(width: height * 0.58)
                Text(kind.label)
                    .font(.system(
                        size: height * HUDMetrics.canonicalQuotaPrimaryTextScale,
                        weight: .semibold,
                        design: .rounded
                    ))
                Text(percentText)
                    .font(.system(size: height * 0.48, weight: .bold, design: .rounded))
                Spacer(minLength: height * 0.12)
                HStack(spacing: height * 0.12) {
                    Text("剩餘")
                    Text(resetText)
                }
                .font(.system(size: height * 0.38, weight: .medium, design: .rounded))
                .foregroundStyle(HUDColorPalette.secondaryText)
            }
            .foregroundStyle(HUDColorPalette.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.52)
            .allowsTightening(true)
            .padding(.horizontal, height * 0.28)
            .frame(width: width, height: height, alignment: .leading)
        }
        .frame(width: width, height: height, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    accent.opacity(isUpdating ? 0.24 : 0.32),
                    lineWidth: 0.6 * scaleFactor
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind.label)配額")
        .accessibilityValue(
            presentation.map {
                let reset = $0.resetDescription == "更新中" || $0.resetDescription == "已重置"
                    ? $0.resetDescription
                    : "\($0.resetDescription)後重置"
                return "剩餘 \($0.remainingPercent)%，\(reset)"
            } ?? (isUpdating ? "資料更新中" : "此帳號未提供此窗口")
        )
    }
}

/// Purchased OpenAI GPT credits are an account balance, not a quota window.
/// Keep them outside the progress-bar stack so the three-window contract stays
/// readable and the balance never looks like a fourth blood bar.
private struct HUDCreditsRow: View {
    let credits: CreditsBalance
    let width: CGFloat
    let sectionHeight: CGFloat
    let rowHeight: CGFloat
    let scaleFactor: CGFloat

    private var balanceText: String {
        credits.displayBalance ?? "—"
    }

    var body: some View {
        VStack(spacing: 0) {
            divider
            HStack(spacing: max(6, 8 * scaleFactor)) {
                Image(systemName: "wallet.pass")
                    .font(.system(size: max(16, 22 * scaleFactor), weight: .semibold))
                    .foregroundStyle(HUDColorPalette.credits)
                    .frame(width: max(22, 27 * scaleFactor))
                Text("Credits")
                    .font(.system(
                        size: max(14, 18 * scaleFactor),
                        weight: .semibold,
                        design: .rounded
                    ))
                    .foregroundStyle(HUDColorPalette.credits)
                Spacer(minLength: 8 * scaleFactor)
                Text(balanceText)
                    .font(.system(
                        size: max(18, 24 * scaleFactor),
                        weight: .bold,
                        design: .rounded
                    ))
                    .foregroundStyle(HUDColorPalette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.64)
                    .allowsTightening(true)
                Text("balance")
                    .font(.system(
                        size: max(11, 13 * scaleFactor),
                        weight: .medium,
                        design: .rounded
                    ))
                    .foregroundStyle(HUDColorPalette.secondaryText)
                    .lineLimit(1)
            }
            .frame(width: width, height: rowHeight, alignment: .leading)
            divider
        }
        .frame(width: width, height: sectionHeight, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Credits")
        .accessibilityValue(credits.unlimited ? "unlimited balance" : "\(balanceText) balance")
        .help("OpenAI GPT 購買額度餘額")
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.black.opacity(0.14))
            .frame(width: width, height: max(0.6, 0.8 * scaleFactor))
    }
}

private struct HUDActionCard: View {
    fileprivate enum FillStyle {
        case neutral
        case filled(background: Color, foreground: Color)
    }

    let title: String
    let systemImage: String
    let iconSize: CGFloat
    let action: () -> Void
    let isDisabled: Bool
    let helpText: String
    let accessibilityLabel: String
    let iconColor: Color
    let fillStyle: FillStyle
    let width: CGFloat
    let height: CGFloat
    @Binding var isHovered: Bool

    private var cornerRadius: CGFloat {
        max(5, height * 0.14)
    }

    private var scaleFactor: CGFloat {
        height / HUDMetrics.canonicalActionHeight
    }

    init(
        title: String,
        systemImage: String,
        iconSize: CGFloat,
        action: @escaping () -> Void,
        isDisabled: Bool,
        helpText: String,
        accessibilityLabel: String,
        iconColor: Color = HUDColorPalette.primaryText,
        fillStyle: FillStyle = .neutral,
        width: CGFloat,
        height: CGFloat,
        isHovered: Binding<Bool>
    ) {
        self.title = title
        self.systemImage = systemImage
        self.iconSize = iconSize
        self.action = action
        self.isDisabled = isDisabled
        self.helpText = helpText
        self.accessibilityLabel = accessibilityLabel
        self.iconColor = iconColor
        self.fillStyle = fillStyle
        self.width = width
        self.height = height
        self._isHovered = isHovered
    }

    private var imageForegroundColor: Color {
        switch fillStyle {
        case .neutral:
            return iconColor.opacity(isHovered ? 0.96 : 0.78)
        case .filled(_, let foreground):
            return foreground.opacity(isHovered ? 0.98 : 0.96)
        }
    }

    private var textForegroundColor: Color {
        switch fillStyle {
        case .neutral:
            return HUDColorPalette.primaryText
        case .filled(_, let foreground):
            return foreground.opacity(isHovered ? 0.98 : 0.96)
        }
    }

    private var backgroundColor: Color {
        switch fillStyle {
        case .neutral:
            return isHovered ? Color.black.opacity(0.10) : Color.clear
        case .filled(let background, _):
            return background.opacity(isHovered ? 0.94 : 0.84)
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Button(action: action) {
            HStack(spacing: 3 * scaleFactor) {
                Image(systemName: systemImage)
                    .font(.system(size: iconSize * scaleFactor, weight: .semibold))
                    .foregroundStyle(imageForegroundColor)
                Text(title)
                    // Match the footer Commit/Push labels at the shared 14pt
                    // baseline while retaining proportional HUD scaling.
                    .font(.system(size: 14 * scaleFactor, weight: .semibold, design: .rounded))
                    .foregroundStyle(textForegroundColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .allowsTightening(true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .frame(width: width, height: height)
        .background(backgroundColor, in: shape)
        .overlay {
            if case .neutral = fillStyle {
                shape.stroke(Color.black.opacity(0.22), lineWidth: 0.8 * scaleFactor)
            }
        }
        .contentShape(shape)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
        .help(helpText)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct HUDUpdateBadge: View {
    let state: HUDUpdateBadgeState
    let height: CGFloat
    let action: () -> Void

    private var isActionable: Bool { state.isActionable }

    private var title: String {
        switch state {
        case .version(let version): return "v\(version)"
        case .available: return "有新版本"
        case .checking: return "檢查中…"
        case .downloading: return "更新中…"
        case .error(let version): return "v\(version)"
        }
    }

    private var icon: String {
        switch state {
        case .version: return "number.circle"
        case .available: return "circle.fill"
        case .checking: return "arrow.triangle.2.circlepath"
        case .downloading: return "arrow.down.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var iconColor: Color {
        switch state {
        case .available: return HUDColorPalette.update
        case .error: return .red
        default: return HUDColorPalette.secondaryText
        }
    }

    private var accessibilityValue: String {
        switch state {
        case .version(let version): return "目前版本 \(version)"
        case .available(let version): return "有新版本 \(version)，點擊開啟更新詳情"
        case .checking: return "正在檢查更新"
        case .downloading: return "正在下載更新"
        case .error(let version): return "目前版本 \(version)，更新檢查失敗，點擊重新檢查"
        }
    }

    private func badgeContent(spacing: CGFloat, iconSize: CGFloat, titleSize: CGFloat) -> AnyView {
        AnyView(HStack(spacing: spacing) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(iconColor)
            Text(title)
                .font(.system(size: titleSize, weight: .semibold, design: .rounded))
                .foregroundStyle(HUDColorPalette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .allowsTightening(true)
        })
    }

    private func badgeButtonLabel(
        spacing: CGFloat,
        iconSize: CGFloat,
        titleSize: CGFloat,
        minimumWidth: CGFloat,
        horizontalPadding: CGFloat
    ) -> AnyView {
        let content = badgeContent(spacing: spacing, iconSize: iconSize, titleSize: titleSize)
        return AnyView(
            content
                .frame(minWidth: minimumWidth, minHeight: self.height, maxHeight: self.height)
                .padding(.horizontal, horizontalPadding)
        )
    }

    var body: some View {
        let spacing = max(CGFloat(3), height * 0.12)
        let iconSize = max(CGFloat(9), height * 0.42)
        let titleSize = max(CGFloat(9), height * HUDMetrics.canonicalQuotaPrimaryTextScale)
        let minimumWidth = max(CGFloat(76), height * 4.4)
        let horizontalPadding = max(CGFloat(6), height * 0.2)
        Button(action: action) {
            badgeButtonLabel(
                spacing: spacing,
                iconSize: iconSize,
                titleSize: titleSize,
                minimumWidth: minimumWidth,
                horizontalPadding: horizontalPadding
            )
        }
        .buttonStyle(.plain)
        .disabled(!isActionable)
        .background(Color.white.opacity(0.44), in: Capsule())
        .overlay { Capsule().stroke(Color.black.opacity(0.12), lineWidth: 0.6) }
        .help(isActionable ? (state.isAvailable ? "開啟更新詳情" : "重新檢查更新") : accessibilityValue)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }
}

/// Compact account-plan badge shown beside the in-memory Email identity. The
/// badge is informational only; plan data continues to come from the existing
/// account-health/snapshot publication and is never persisted by the HUD.
private struct HUDPlanBadge: View {
    let plan: String
    let height: CGFloat

    private var normalizedPlan: String {
        plan.lowercased().replacingOccurrences(of: "_", with: " ")
    }

    private var tint: Color {
        if normalizedPlan.contains("pro") { return Color.purple }
        if normalizedPlan.contains("plus") { return Color.blue }
        if normalizedPlan.contains("business") { return Color.orange }
        if normalizedPlan.contains("team") { return Color.teal }
        if normalizedPlan.contains("enterprise") { return Color.indigo }
        if normalizedPlan.contains("free") { return Color.gray }
        return HUDColorPalette.secondaryText
    }

    var body: some View {
        Text(plan)
            .font(.system(size: max(9, height * HUDMetrics.canonicalQuotaPrimaryTextScale), weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .allowsTightening(true)
            .padding(.horizontal, max(7, height * 0.28))
            .frame(minWidth: max(46, height * 2.15), minHeight: height, maxHeight: height)
            .background(tint.opacity(0.13), in: Capsule())
            .overlay { Capsule().stroke(tint.opacity(0.35), lineWidth: max(0.6, height * 0.025)) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("帳號方案")
            .accessibilityValue(plan)
    }
}

private struct CodexFloatingHUDView: View {
    private enum UpdateFeedbackKind {
        case checking
        case upToDate
        case available
        case downloading
        case downloaded
        case error
    }

    private struct UpdateFeedback: Identifiable {
        let id = UUID()
        let kind: UpdateFeedbackKind
        let title: String
        let message: String
    }

    @ObservedObject var model: UsageViewModel
    @ObservedObject var gitCoordinator: GitWorkspaceCoordinator
    @ObservedObject var layoutState: FloatingHUDLayoutState
    let pasteClipboard: () -> Void
    let pasteAndSubmit: (@escaping (Bool) -> Void) -> Void
    let promptShortcut: (CodexPromptShortcut, @escaping (Bool) -> Void) -> Void
    let showDetails: () -> Void
    let showGitWorkspace: () -> Void
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
    let creditsVisibilityChanged: (Bool) -> Void
    let checkForUpdates: () -> Void
    let cancelUpdateCheck: () -> Void
    let downloadAvailableUpdate: () -> Void
    let revealDownloadedUpdate: () -> Void
    let installDownloadedUpdate: () -> Void
    let openReleasePage: () -> Void
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isUpdateHovered = false
    @State private var isDetailsHovered = false
    @State private var isPasteHovered = false
    @State private var isPasteAndSubmitHovered = false
    @State private var isExecuteHovered = false
    @State private var isCommitHovered = false
    @State private var isPushHovered = false
    @State private var isCommitPushHovered = false
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
                hudContainer()
                    .overlay { hudPulseOverlay }
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
        .preferredColorScheme(.light)
        .onChange(of: model.updateState) { _, newState in
            presentUpdateFeedback(for: newState)
        }
        .task(id: updateFeedback?.id) {
            guard let feedback = updateFeedback,
                  feedback.kind != .checking,
                  feedback.kind != .downloading else { return }
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled else { return }
            updateFeedback = nil
        }
    }

    private func requestUpdateCheck() {
        updateCheckRequested = true
        updateFeedback = UpdateFeedback(
            kind: .checking,
            title: "正在檢查更新…",
            message: "正在連線到 GitHub Release"
        )
        checkForUpdates()
    }

    private func cancelUpdateCheckAction() {
        // End the HUD's local feedback immediately, then let the shared
        // view model/service finish cancelling the URLSession task.  This
        // keeps the button responsive even if the request's cancellation
        // callback is delayed by the system.
        cancelUpdateCheck()
        updateCheckRequested = false
        updateFeedback = UpdateFeedback(
            kind: .error,
            title: "更新檢查已取消",
            message: "更新檢查已取消。"
        )
    }

    private func presentUpdateFeedback(for state: AppUpdateState) {
        // A download started from the result banner is a second, explicit
        // phase. It must continue to update the same visible banner even
        // though the original check request has already completed.
        guard updateCheckRequested || updateFeedback?.kind == .downloading else { return }

        switch state {
        case .upToDate:
            updateCheckRequested = false
            updateFeedback = UpdateFeedback(
                kind: .upToDate,
                title: "更新檢查完成",
                message: "目前已是最新版本。"
            )
        case .available(let release):
            updateCheckRequested = false
            updateFeedback = UpdateFeedback(
                kind: .available,
                title: "有新版本可用",
                message: "發現 Codex Usage Status \(release.version)"
            )
        case .error(let message):
            updateCheckRequested = false
            updateFeedback = UpdateFeedback(
                kind: .error,
                title: "更新檢查失敗",
                message: message
            )
        case .downloaded(let release, _):
            guard updateFeedback?.kind == .downloading else { return }
            updateFeedback = UpdateFeedback(
                kind: .downloaded,
                title: "更新已下載並驗證",
                message: "\(release.version) 已準備完成"
            )
        case .idle, .checking, .downloading:
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
                Button("取消") { cancelUpdateCheckAction() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            case .downloading:
                ProgressView()
                    .controlSize(.small)
            case .available:
                Button("立即更新") {
                    updateFeedback = UpdateFeedback(
                        kind: .downloading,
                        title: "正在下載並安裝…",
                        message: "驗證後會自動重新啟動"
                    )
                    downloadAvailableUpdate()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            case .downloaded:
                Text("已驗證，正在啟動安裝器…")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.green)
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
        case .downloading: return "arrow.down.circle.dotted"
        case .downloaded: return "checkmark.seal.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private func updateFeedbackColor(for kind: UpdateFeedbackKind) -> Color {
        switch kind {
        case .checking, .downloading: return .accentColor
        case .upToDate, .downloaded: return .green
        case .available: return .orange
        case .error: return .red
        }
    }

    @ViewBuilder
    private func hudContainer() -> some View {
        let metrics = HUDMetrics(scaleLevel: layoutState.scaleLevel)
        let panelSize = metrics.panelSize(
            quotaRowCount: max(1, layoutState.quotaRowCount),
            includesCredits: layoutState.hasCredits
        )
        let displayedCredits = displayedPresentation?.credits
        let shouldShowCredits = displayedCredits?.isDisplayable == true
        VStack(alignment: .leading, spacing: 0) {
            hudHeader(metrics: metrics)
            Color.clear.frame(height: metrics.headerGap)
            quotaStack(width: metrics.contentWidth, height: metrics.quotaRowHeight, gap: metrics.quotaGap)
            Color.clear.frame(height: metrics.sectionGap)
            if let displayedCredits, shouldShowCredits {
                HUDCreditsRow(
                    credits: displayedCredits,
                    width: metrics.contentWidth,
                    sectionHeight: metrics.creditsSectionHeight,
                    rowHeight: metrics.creditsRowHeight,
                    scaleFactor: metrics.factor
                )
                Color.clear.frame(height: metrics.sectionGap)
            }
            actionCardsRow(metrics: metrics)
            Color.clear.frame(height: metrics.sectionGap)
            footerRow(metrics: metrics)
        }
        .padding(metrics.outerPadding)
        .frame(width: panelSize.width, height: panelSize.height, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: FloatingHUDLayout.cornerRadius(for: layoutState.scaleLevel), style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FloatingHUDLayout.cornerRadius(for: layoutState.scaleLevel), style: .continuous)
                .fill(HUDColorPalette.panelTint)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: FloatingHUDLayout.cornerRadius(for: layoutState.scaleLevel), style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Codex 用量")
        .accessibilityValue(hudAccessibilityValue)
        .onAppear {
            trackedProfileID = model.currentProfileID
            displayedAccountEmail = AccountProfileDisplay.fullEmail(model.currentAccountEmail)
            suppressedAccountEmail = nil
            displayedPlan = normalizedPlanLabel(model.accountHealth?.identity.planType ?? model.snapshot?.planType)
            cacheCurrentPresentation()
            syncLiveBaseline()
            quotaRowCountChanged(max(1, livePresentation?.rowCount ?? 1))
            creditsVisibilityChanged(displayedPresentation?.credits?.isDisplayable == true)
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
            creditsVisibilityChanged(false)
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
            creditsVisibilityChanged(displayedPresentation?.credits?.isDisplayable == true)
            if trackedProfileID == model.currentProfileID,
               let plan = normalizedPlanLabel(model.snapshot?.planType) {
                displayedPlan = plan
            }
        }
        .onChange(of: presentationCache) { _, _ in
            quotaRowCountChanged(max(1, displayedPresentation?.rowCount ?? 1))
            creditsVisibilityChanged(displayedPresentation?.credits?.isDisplayable == true)
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

    private func hudHeader(metrics: HUDMetrics) -> some View {
        HStack(alignment: .center, spacing: max(CGFloat(4), metrics.headerGap * 0.5)) {
            Text(displayedAccountEmail ?? "未提供 Email")
                .font(.system(size: metrics.quotaPrimaryTextSize, weight: .semibold, design: .rounded))
                .foregroundStyle(HUDColorPalette.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.62)
                .allowsTightening(true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                .accessibilityElement()
                .accessibilityLabel("目前登入 Email")
                .accessibilityValue(displayedAccountEmail ?? "未提供 Email")
            if let displayedPlan {
                HUDPlanBadge(plan: displayedPlan, height: metrics.headerHeight)
            }
            let badgeState = HUDUpdateBadgePolicy.state(
                updateState: model.updateState,
                currentVersion: AppVersion.current
            )
            HUDUpdateBadge(
                state: badgeState,
                height: metrics.headerHeight,
                action: {
                    switch badgeState {
                    case .available:
                        showDetails()
                    case .error:
                        requestUpdateCheck()
                    case .version, .checking, .downloading:
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

    private func quotaStack(width: CGFloat, height: CGFloat, gap: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: gap) {
                ForEach(quotaRowKinds, id: \.self) { kind in
                    HUDQuotaRow(
                        kind: kind,
                        presentation: quotaPresentation(for: kind),
                        isUpdating: isQuotaUpdating,
                        width: width,
                        height: height
                    )
                }
            }
            if let decreaseAmount {
                Text("−\(decreaseAmount)%")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.red)
                    .offset(x: 1, y: -3)
                    .zIndex(1)
            }
        }
    }

    private var quotaRowKinds: [HUDQuotaWindowKind] {
        if let rows = displayedPresentation?.rows, !rows.isEmpty {
            return rows.map(\.kind)
        }
        return Array(HUDQuotaWindowKind.allCases.prefix(max(1, layoutState.quotaRowCount)))
    }

    private func quotaPresentation(for kind: HUDQuotaWindowKind) -> HUDQuotaWindowPresentation? {
        displayedPresentation?.rows.first(where: { $0.kind == kind })
    }

    private func actionCardsRow(metrics: HUDMetrics) -> some View {
        HStack(spacing: metrics.actionSpacing) {
            pasteShortcutButton(metrics: metrics)
            pasteAndSubmitShortcutButton(metrics: metrics)
            executeShortcutButton(metrics: metrics)
        }
        .frame(width: metrics.contentWidth, height: metrics.actionHeight, alignment: .leading)
    }

    private func footerRow(metrics: HUDMetrics) -> some View {
        HStack(spacing: metrics.footerButtonSpacing) {
            promptShortcutButton(.commit, metrics: metrics, width: metrics.footerButtonWidth, hovered: $isCommitHovered)
            promptShortcutButton(.push, metrics: metrics, width: metrics.footerButtonWidth, hovered: $isPushHovered)
            promptShortcutButton(.commitPush, metrics: metrics, width: metrics.footerButtonWidth, hovered: $isCommitPushHovered)
        }
        .frame(width: metrics.footerControlsWidth, height: metrics.footerHeight, alignment: .leading)
        // Keep the footer's leading inset, but let the final action fill to
        // the capsule's trailing edge instead of leaving a second right gap.
        .padding(.leading, metrics.footerHorizontalPadding)
        .frame(width: metrics.contentWidth, height: metrics.footerHeight, alignment: .leading)
        .background(Color.black.opacity(0.035), in: Capsule())
        .overlay { Capsule().stroke(Color.black.opacity(0.16), lineWidth: 0.8) }
    }

    private func detailsShortcutButton(metrics: HUDMetrics) -> some View {
        HUDActionCard(
            title: "詳細",
            systemImage: "rectangle.and.text.magnifyingglass",
            iconSize: 12,
            action: showDetails,
            isDisabled: false,
            helpText: "開啟詳細面板",
            accessibilityLabel: "開啟詳細面板",
            width: metrics.actionCardWidth,
            height: metrics.actionHeight,
            isHovered: $isDetailsHovered
        )
    }

    private func pasteShortcutButton(metrics: HUDMetrics) -> some View {
        HUDActionCard(
            title: "貼上",
            systemImage: "doc.on.clipboard",
            iconSize: 14,
            action: pasteClipboard,
            isDisabled: !layoutState.isCodexFocused,
            helpText: layoutState.isCodexFocused ? "貼上剪貼簿內容" : "切換回 Codex 後可貼上",
            accessibilityLabel: "貼上剪貼簿內容",
            width: metrics.actionCardWidth,
            height: metrics.actionHeight,
            isHovered: $isPasteHovered
        )
    }

    private func pasteAndSubmitShortcutButton(metrics: HUDMetrics) -> some View {
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
            isDisabled: isPasteAndSubmitInFlight || !layoutState.isCodexFocused,
            helpText: layoutState.isCodexFocused ? "貼上並送出" : "切換回 Codex 後可貼上並送出",
            accessibilityLabel: "貼上並送出",
            fillStyle: .filled(background: HUDColorPalette.submitAction, foreground: .white),
            width: metrics.actionCardWidth,
            height: metrics.actionHeight,
            isHovered: $isPasteAndSubmitHovered
        )
        .opacity(isPasteAndSubmitInFlight ? 0.45 : 1)
    }

    private func executeShortcutButton(metrics: HUDMetrics) -> some View {
        HUDActionCard(
            title: "執行",
            systemImage: "play.fill",
            iconSize: 12,
            action: {
                guard !isPromptShortcutInFlight,
                      layoutState.isCodexFocused,
                      !ClipboardPasteService.isTemporaryOperationInFlight else { return }
                isPromptShortcutInFlight = true
                promptShortcut(.execute) { _ in
                    isPromptShortcutInFlight = false
                }
            },
            isDisabled: isPromptShortcutInFlight || !layoutState.isCodexFocused || ClipboardPasteService.isTemporaryOperationInFlight,
            helpText: layoutState.isCodexFocused ? "執行" : "切換回 Codex 後可執行",
            accessibilityLabel: "執行",
            fillStyle: .filled(background: HUDColorPalette.executeAction, foreground: .white),
            width: metrics.actionCardWidth,
            height: metrics.actionHeight,
            isHovered: $isExecuteHovered
        )
    }

    private func promptShortcutButton(
        _ shortcut: CodexPromptShortcut,
        metrics: HUDMetrics,
        width: CGFloat,
        hovered: Binding<Bool>
    ) -> some View {
        let isFilled = shortcut == .commitPush
        let backgroundColor = isFilled
            ? (hovered.wrappedValue ? HUDColorPalette.commitPush.opacity(0.94) : HUDColorPalette.commitPush.opacity(0.84))
            : Color.clear
        let foregroundColor = isFilled ? Color.white : (shortcut == .commit ? HUDColorPalette.commit : HUDColorPalette.push)
        let textForegroundColor = isFilled ? Color.white.opacity(0.96) : HUDColorPalette.primaryText
        return Button {
            guard !isPromptShortcutInFlight,
                  layoutState.isCodexFocused,
                  !ClipboardPasteService.isTemporaryOperationInFlight else { return }
            isPromptShortcutInFlight = true
            promptShortcut(shortcut) { _ in
                isPromptShortcutInFlight = false
            }
        } label: {
            HStack(spacing: metrics.factor * 4) {
                Image(systemName: shortcut == .commit ? "point.3.connected.trianglepath.dotted" : shortcut == .push ? "arrow.up" : "arrow.up.right.circle")
                    .font(.system(size: metrics.factor * 17, weight: .semibold))
                    .foregroundStyle(foregroundColor)
                Text(shortcut.text)
                    .font(.system(size: metrics.factor * 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(textForegroundColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .allowsTightening(true)
            }
            .frame(width: width, height: metrics.footerHeight)
        }
        .buttonStyle(.plain)
        .disabled(isPromptShortcutInFlight || !layoutState.isCodexFocused || ClipboardPasteService.isTemporaryOperationInFlight)
        .opacity(isPromptShortcutInFlight ? 0.45 : 1)
        .onHover { hovered.wrappedValue = $0 }
        .help("將「\(shortcut.text)」貼入 Codex\(shortcut.submitAfterPaste ? "並送出" : "")")
        .accessibilityLabel(shortcut.accessibilityLabel)
        .accessibilityValue(shortcut.submitAfterPaste ? "貼上並送出一次" : "貼上但不送出")
        .background(
            backgroundColor,
            in: RoundedRectangle(cornerRadius: metrics.footerHeight * 0.24, style: .continuous)
        )
    }

    @ViewBuilder
    private var hudPulseOverlay: some View {
        if let profile = HUDWarningPolicy.framePulseProfile(
            remainingPercent: model.hudRemainingPercent,
            connectionState: model.connectionState,
            isStale: model.isStale
        ) {
            // Keep the HUD visually stable. The earlier TimelineView rebuilt
            // an animated edge several times per second, which looked like a
            // panel flash on some macOS/window-manager combinations. A
            // color-matched static contour still communicates quota state
            // without moving or blinking the HUD.
            let opacity = profile.minOpacity + ((profile.maxOpacity - profile.minOpacity) * 0.45)
            hudPulseBorder(frameOpacity: opacity)
        } else if accessibilityReduceMotion && hasLiveHUDData {
            hudPulseBorder(frameOpacity: 0.14)
        }
    }

    private func hudPulseBorder(frameOpacity: Double) -> some View {
        RoundedRectangle(cornerRadius: FloatingHUDLayout.cornerRadius(for: layoutState.scaleLevel), style: .continuous)
            .stroke(
                model.menuBarColor.opacity(max(0.28, frameOpacity)),
                lineWidth: frameOpacity > 0.48 ? 2.35 : 2.0
            )
        .frame(width: layoutState.size.width, height: layoutState.size.height)
        .allowsHitTesting(false)
    }

    private var hasAvailableUpdate: Bool {
        switch model.updateState {
        case .available, .downloaded:
            return true
        default:
            return false
        }
    }

    private var updateShortcutIcon: String {
        switch model.updateState {
        case .available, .downloaded:
            return "bell.badge.fill"
        case .checking, .downloading:
            return "arrow.down.circle"
        default:
            return "arrow.down.circle"
        }
    }

    private func updateShortcutAction() {
        switch model.updateState {
        case .available, .downloaded, .checking, .downloading:
            // The detail panel already owns download/install actions and the
            // shared AppUpdateState, so the HUD never starts a second request.
            showDetails()
        case .idle, .upToDate, .error:
            // Route manual HUD checks through the same feedback path as the
            // context menu so the user sees checking/available/error state
            // immediately instead of only receiving a silent state update.
            requestUpdateCheck()
        }
    }

    private func updateShortcutButton(metrics: HUDMetrics) -> some View {
        HUDActionCard(
            title: "更新",
            systemImage: updateShortcutIcon,
            iconSize: 13,
            action: updateShortcutAction,
            isDisabled: false,
            helpText: hasAvailableUpdate ? "有更新可用，開啟更新面板" : "檢查更新",
            accessibilityLabel: hasAvailableUpdate ? "有更新可用" : "檢查更新",
            iconColor: hasAvailableUpdate ? .orange : .primary,
            width: metrics.actionCardWidth,
            height: metrics.actionHeight,
            isHovered: $isUpdateHovered
        )
        .accessibilityValue(hasAvailableUpdate ? "開啟更新面板" : "檢查目前版本")
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
        }

        Section {
            Button(action: pasteClipboard) {
                Label("貼上剪貼簿內容", systemImage: "doc.on.clipboard")
            }
            .disabled(!HUDContextMenuPolicy.pasteActionsEnabled(isCodexFocused: layoutState.isCodexFocused))

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

        // Keep update actions at the top level so they are discoverable from
        // the HUD's context menu.  The previous version placed these under
        // the collapsed "通知與同步" submenu, which made an available
        // release look as if the app had no update action at all.
        Section {
            Button(action: showGitWorkspace) {
                Label("開啟 Git 工作區", systemImage: "arrow.triangle.branch")
            }
            .disabled(!gitCoordinator.isWorkspaceKnown)
            Button(action: { gitCoordinator.refreshNow() }) {
                Label("重新整理 Git 狀態", systemImage: "arrow.clockwise")
            }
            .disabled(!layoutState.isCodexFocused)
        }

        Section {
            Button(action: requestUpdateCheck) {
                Label("檢查更新", systemImage: "arrow.down.circle")
            }

            switch model.updateState {
            case .available(let release):
                Button {
                    downloadAvailableUpdate()
                } label: {
                    Label("立即更新並重新啟動 \(release.version)", systemImage: "arrow.down.app")
                }
                Button(action: openReleasePage) {
                    Label("開啟 Release 頁面", systemImage: "safari")
                }
            case .checking:
                Button(action: cancelUpdateCheckAction) {
                    Label("取消更新檢查", systemImage: "xmark.circle")
                }
            case .downloading(let release):
                Label("正在下載並驗證 \(release.version)…", systemImage: "arrow.down.circle.dotted")
            case .downloaded(let release, _):
                Label("更新 \(release.version) 已驗證", systemImage: "checkmark.seal")
                Button(action: installDownloadedUpdate) {
                    Label("安裝並重新啟動", systemImage: "arrow.down.app")
                }
                Button(action: showDetails) {
                    Label("查看更新資訊", systemImage: "info.circle")
                }
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

    private var hudAccessibilityValue: String {
        let quotaText = quotaRowKinds.map { kind in
            guard let presentation = quotaPresentation(for: kind) else {
                return "\(kind.label)窗口，\(isQuotaUpdating ? "資料更新中" : "此帳號未提供")"
            }
            let reset = presentation.resetDescription == "更新中" || presentation.resetDescription == "已重置"
                ? presentation.resetDescription
                : "\(presentation.resetDescription)後重置"
            return "\(kind.label)窗口，剩餘 \(presentation.remainingPercent)%，\(reset)"
        }.joined(separator: "；")
        let planText = displayedPlan.map { "，方案 \($0)" } ?? ""
        let creditsText: String
        if let credits = displayedPresentation?.credits, credits.isDisplayable {
            creditsText = "，Credits \(credits.unlimited ? "unlimited" : (credits.displayBalance ?? "無法取得")) balance"
        } else {
            creditsText = ""
        }
        return "Codex，\(quotaText)\(creditsText)\(planText)，\(model.dataAgeText)，帳號 \(displayedAccountEmail ?? "未提供 Email")。提供更新通知、詳細面板、只貼上、貼上並送出、執行、Commit 與 Push 快捷鈕"
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

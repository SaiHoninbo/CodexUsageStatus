import AppKit
import Combine
import CoreGraphics
import SwiftUI

private enum FloatingHUDLayout {
    // The HUD has a second, memory-only account identity line. Keep the
    // width compact while giving that line enough vertical room to remain
    // readable; the two placements differ only by their small top/bottom
    // inset, as before.
    static let bottomRightSize = NSSize(width: 300, height: 61)
    static let topRightSize = NSSize(width: 300, height: 57)
    // Sizes used by the previous shipped HUD builds. These are only used
    // while migrating persisted screen anchors; new anchors are size-agnostic.
    static let previousWideSize = NSSize(width: 360, height: 60)
    static let previousLegacySize = NSSize(width: 156, height: 66)
    static let cornerRadius: CGFloat = 15

    static func size(for placement: HUDPlacement) -> NSSize {
        switch placement {
        case .topRight: return topRightSize
        case .bottomRight: return bottomRightSize
        }
    }
}

@MainActor
private final class FloatingHUDLayoutState: ObservableObject {
    @Published var placement: HUDPlacement = .bottomRight
    /// The HUD is a Codex-only overlay. This state is also used by the view
    /// to keep actions disabled during a focus transition.
    @Published var isCodexFocused = true

    var size: NSSize { FloatingHUDLayout.size(for: placement) }
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
            checkForUpdates: { [weak self] in self?.model.checkForUpdates() },
            cancelUpdateCheck: { [weak self] in self?.model.cancelUpdateCheck() },
            downloadAvailableUpdate: { [weak self] in self?.model.downloadAvailableUpdate() },
            revealDownloadedUpdate: { [weak self] in self?.model.revealDownloadedUpdate() },
            installDownloadedUpdate: { [weak self] in self?.model.installDownloadedUpdate() },
            openReleasePage: { [weak self] in self?.model.openUpdateReleasePage() }
        )
        let hostingView = NSHostingView(rootView: rootView)
        let newPanel = DraggableHUDPanel(
            contentRect: NSRect(origin: .zero, size: FloatingHUDLayout.bottomRightSize),
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
        newPanel.setContentSize(FloatingHUDLayout.bottomRightSize)
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
            Task { @MainActor [weak self] in
                self?.refreshVisibility()
            }
        }

        modelObservation = model.objectWillChange.sink { [weak self] _ in
            // @Published emits before the value is assigned. Hop to the next
            // main-actor turn so the HUD sees the new preference/state.
            Task { @MainActor [weak self] in
                self?.refreshVisibility()
            }
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshVisibility()
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
        modelObservation?.cancel()
        modelObservation = nil
        panel?.orderOut(nil)
        panel = nil
        lastCodexWindowFrame = nil
        lastCodexVisibleFrame = nil
        lastCodexProcessID = nil
        lastPositionedCodexWindowFrame = nil
        lastPositionedVisibleFrame = nil
        lastPositionedProcessID = nil
        lastPositionedPanelSize = nil
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

    private func pasteClipboard() {
        ClipboardPasteService.pasteToCodex(processID: lastCodexProcessID)
    }

    private func pasteAndSubmit(completion: @escaping (Bool) -> Void) {
        ClipboardPasteService.pasteAndSubmitToCodex(
            processID: lastCodexProcessID,
            completion: completion
        )
    }

    private func refreshVisibility() {
        guard let panel else { return }
        // A HUD without any effective quota percentage is only a partial
        // transport state (for example while account switching, reconnecting,
        // or before the first rate-limit read). Primary is preferred, but the
        // model may legitimately expose a fallback window while primary is
        // omitted; keep the HUD consistent with the menu-bar value then.
        guard model.floatingHUDEnabled else {
            hideImmediately(panel)
            return
        }

        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        guard let frontmostApplication else {
            // A nil frontmost application is an unknown focus transition, not
            // proof that Codex was left. Keep the current panel and wait for a
            // concrete application identity before scheduling focus loss.
            cancelFocusLoss()
            return
        }
        guard isCodexApplication(frontmostApplication) else {
            scheduleFocusLoss(panel)
            return
        }
        cancelFocusLoss()
        let codexApp = frontmostApplication
        layoutState.isCodexFocused = true

        guard HUDQuotaPresentationPolicy.make(
            snapshot: model.snapshot,
            profileID: model.currentProfileID,
            now: model.currentDate
        )?.hasRecognizedWindow == true else {
            // Keep a visible panel through account boundaries, reconnects,
            // and sparse quota responses. The view owns profile-bound cached
            // presentation and renders an updating state without blanking.
            return
        }

        if let previousProcessID = lastCodexProcessID,
           previousProcessID != codexApp.processIdentifier {
            // Do not carry a prior app's display/frame into a new process.
            lastCodexWindowFrame = nil
            lastCodexVisibleFrame = nil
            lastPositionedCodexWindowFrame = nil
            lastPositionedVisibleFrame = nil
            lastPositionedProcessID = nil
        }
        lastCodexProcessID = codexApp.processIdentifier
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
            panel.alphaValue = 1.0
        case .unavailable:
            // A hidden HUD must not be resurrected at an old or guessed
            // position while the focused window metadata is unavailable.
            return
        }
    }

    private func isCodexApplication(_ application: NSRunningApplication) -> Bool {
        let bundleID = application.bundleIdentifier?.lowercased() ?? ""
        let name = application.localizedName?.lowercased() ?? ""
        let path = application.bundleURL?.path.lowercased() ?? ""
        // The native Codex desktop app identifies itself as `com.openai.codex`.
        // Keep this exact so CodexUsageStatus itself is never treated as the
        // host, while browsers and unrelated applications remain hidden.
        let isNativeCodexBundle = bundleID == "com.openai.codex"
        return isNativeCodexBundle
            || bundleID.contains("chatgpt")
            || name.contains("chatgpt")
            || path.contains("/chatgpt.app")
    }

    private func position(_ panel: NSPanel, beside application: NSRunningApplication) -> HUDPositionResult {
        guard let quartzTargetFrame = codexWindowFrame(for: application.processIdentifier),
              let displayMapping = quartzDisplayMapping(for: quartzTargetFrame) else {
            return HUDVisibilityPolicy.positionResult(
                hasValidFrame: false,
                panelIsVisible: panel.isVisible
            )
        }
        let targetFrame = appKitWindowFrame(from: quartzTargetFrame, mapping: displayMapping)
        // Focused-window metadata is authoritative. If it is temporarily
        // unavailable, retain an already visible panel at its current origin.
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
            let size = FloatingHUDLayout.size(for: anchor.placement)
            applySize(size, to: panel)
            let origin = HUDPlacementPolicy.origin(
                for: anchor,
                targetFrame: targetFrame,
                panelSize: size
            )
            panel.setFrameOrigin(clampedOrigin(origin, panelSize: size, visibleFrame: visibleFrame))
            saveAnchor(origin: panel.frame.origin, targetFrame: targetFrame, panelSize: size, placement: anchor.placement)
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
            let size = FloatingHUDLayout.size(for: placement)
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
            let size = FloatingHUDLayout.size(for: placement)
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
            let size = FloatingHUDLayout.size(for: placement)
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
            return .positioned
        }

        lastPlacement = .bottomRight
        layoutState.placement = .bottomRight
        let size = FloatingHUDLayout.bottomRightSize
        applySize(size, to: panel)
        var x = targetFrame.maxX - size.width - 18
        var y = targetFrame.maxY - size.height - 18
        x = min(x, visibleFrame.maxX - size.width - 8)
        x = max(x, visibleFrame.minX + 8)
        y = min(y, visibleFrame.maxY - size.height - 8)
        y = max(y, visibleFrame.minY + 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        saveAnchor(origin: panel.frame.origin, targetFrame: targetFrame, panelSize: size, placement: .bottomRight)
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
        focusLossTask = Task { @MainActor [weak self, weak panel] in
            do {
                try await Task.sleep(for: self?.focusLossGrace ?? .milliseconds(500))
            } catch {
                return
            }
            guard let self,
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
        let newSize = FloatingHUDLayout.size(for: placement)
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
        guard lastPositionedProcessID == processID,
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
    private static let shellWidth: CGFloat = 138
    private static let shellHeight: CGFloat = 17

    let kind: HUDQuotaWindowKind
    let presentation: HUDQuotaWindowPresentation?
    let isUpdating: Bool
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    private var accent: Color {
        switch kind {
        case .fiveHour: return .orange
        case .sevenDay: return .blue
        }
    }

    private var fillFraction: CGFloat {
        CGFloat(max(0, min(1, presentation?.fillFraction ?? 0)))
    }

    private var percentText: String {
        presentation.map { "\($0.remainingPercent)%" } ?? "—%"
    }

    private var resetText: String {
        presentation?.resetDescription ?? "更新中"
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Both quota rows intentionally share one fixed shell width. The
            // fill is embedded in this shell, so changing one window never
            // changes the geometry of the other row or the left allocation.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(isUpdating ? 0.18 : 0.24))
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(accent.opacity(isUpdating ? 0.32 : 0.58))
                .frame(width: Self.shellWidth * fillFraction)

            HStack(spacing: 3) {
                Image(systemName: "clock")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 11)
                Text(kind.label)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                Text(percentText)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                Text(resetText)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.86))
            }
            // Keep labels readable independently of fill strength. The fixed
            // shell receives the proposal, allowing text to tighten without
            // reintroducing content-hug geometry or a trailing track.
            .foregroundStyle(.primary.opacity(0.96))
            .lineLimit(1)
            .minimumScaleFactor(0.58)
            .allowsTightening(true)
            .padding(.horizontal, 6)
            .frame(width: Self.shellWidth, height: Self.shellHeight, alignment: .leading)
        }
        .frame(width: Self.shellWidth, height: Self.shellHeight, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(
                    accent.opacity(isUpdating ? 0.24 : 0.32),
                    lineWidth: 0.6
                )
        }
        .animation(
            isUpdating || accessibilityReduceMotion ? nil : .easeOut(duration: 0.24),
            value: presentation?.remainingPercent
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind.label)配額")
        .accessibilityValue(
            presentation.map {
                let reset = $0.resetDescription == "更新中" || $0.resetDescription == "已重置"
                    ? $0.resetDescription
                    : "\($0.resetDescription)後重置"
                return "剩餘 \($0.remainingPercent)%，\(reset)"
            } ?? "資料更新中"
        )
    }
}

private struct HUDActionCard: View {
    let title: String
    let systemImage: String
    let iconSize: CGFloat
    let action: () -> Void
    let isDisabled: Bool
    let helpText: String
    let accessibilityLabel: String
    let iconColor: Color
    @Binding var isHovered: Bool

    init(
        title: String,
        systemImage: String,
        iconSize: CGFloat,
        action: @escaping () -> Void,
        isDisabled: Bool,
        helpText: String,
        accessibilityLabel: String,
        iconColor: Color = .primary,
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
        self._isHovered = isHovered
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(iconColor.opacity(isHovered ? 0.96 : 0.78))
                Text(title)
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.90))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .allowsTightening(true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .frame(width: 72, height: 18)
        .background(
            isHovered ? Color.primary.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.22), lineWidth: 0.8)
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
        .help(helpText)
        .accessibilityLabel(accessibilityLabel)
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
    @State private var isGitHovered = false
    @State private var isCommitHovered = false
    @State private var isPushHovered = false
    @State private var isPasteAndSubmitInFlight = false
    @State private var trackedProfileID: UUID?
    @State private var lastLivePercent: Int?
    @State private var hasPresentedHUD = false
    @State private var presentationCache: HUDDualQuotaPresentation?
    @State private var decreaseAmount: Int?
    @State private var decreaseBounce = false
    @State private var decreaseAnimationID = 0
    @State private var updateCheckRequested = false
    @State private var updateFeedback: UpdateFeedback?

    var body: some View {
        // Keep the context-menu host outside the pulse TimelineView. The
        // timeline intentionally refreshes several times per second for the
        // breathing border; attaching the menu inside it recreates the
        // AppKit anchor on every pulse and makes an open menu jitter.
        ZStack {
            if hasPresentedHUD || livePresentation != nil || displayedPresentation != nil {
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
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .zIndex(20)
            }
        }
        .contextMenu {
            contextMenuContent
        }
        .onChange(of: model.updateState) { _, newState in
            presentUpdateFeedback(for: newState)
        }
        .task(id: updateFeedback?.id) {
            guard let feedback = updateFeedback,
                  feedback.kind != .checking,
                  feedback.kind != .downloading else { return }
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                updateFeedback = nil
            }
        }
    }

    private func requestUpdateCheck() {
        updateCheckRequested = true
        withAnimation(.easeOut(duration: 0.16)) {
            updateFeedback = UpdateFeedback(
                kind: .checking,
                title: "正在檢查更新…",
                message: "正在連線到 GitHub Release"
            )
        }
        checkForUpdates()
    }

    private func cancelUpdateCheckAction() {
        // End the HUD's local feedback immediately, then let the shared
        // view model/service finish cancelling the URLSession task.  This
        // keeps the button responsive even if the request's cancellation
        // callback is delayed by the system.
        cancelUpdateCheck()
        updateCheckRequested = false
        withAnimation(.easeOut(duration: 0.16)) {
            updateFeedback = UpdateFeedback(
                kind: .error,
                title: "更新檢查已取消",
                message: "更新檢查已取消。"
            )
        }
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: FloatingHUDLayout.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FloatingHUDLayout.cornerRadius, style: .continuous)
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
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                quotaStack
                accountEmailView
            }
            .frame(width: 138, alignment: .leading)

            controlsColumn
            .frame(width: 152, alignment: .trailing)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, layoutState.placement == .topRight ? 1 : 2)
        .frame(width: layoutState.size.width, height: layoutState.size.height, alignment: .leading)
        .overlay(alignment: .leading) {
            // The separator is a visual boundary only. It overlays the
            // existing 5pt inset + 138pt quota allocation and never consumes
            // width from the fixed 300pt HUD contract.
            Rectangle()
                .fill(Color.primary.opacity(0.18))
                .frame(width: 1, height: 55)
                .offset(x: 143)
                .allowsHitTesting(false)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: FloatingHUDLayout.cornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: FloatingHUDLayout.cornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Codex 用量")
        .accessibilityValue(hudAccessibilityValue)
        .onAppear {
            trackedProfileID = model.currentProfileID
            cacheCurrentPresentation()
            syncLiveBaseline()
        }
        .onChange(of: model.currentProfileID) { _, newProfileID in
            // Never carry quota from one account identity into another. The
            // panel remains mounted, but the new profile renders —/updating
            // until it receives its own valid snapshot.
            presentationCache = nil
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
        }
        .onChange(of: model.lastUpdated) { _, newValue in
            // A managed profile can restore a cached snapshot with the same
            // percentage and reset timestamp as the previous account. The
            // update marker changes independently, so use it to recache only
            // after the new profile has delivered its own snapshot.
            guard newValue != nil else { return }
            cacheCurrentPresentation()
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
            withAnimation(.easeOut(duration: 0.18)) {
                decreaseAmount = nil
                decreaseBounce = false
            }
        }
    }

    private var quotaStack: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 2) {
                HUDQuotaRow(
                    kind: .fiveHour,
                    presentation: displayedPresentation?.fiveHour,
                    isUpdating: isQuotaUpdating
                )
                HUDQuotaRow(
                    kind: .sevenDay,
                    presentation: displayedPresentation?.sevenDay,
                    isUpdating: isQuotaUpdating
                )
            }
            if let decreaseAmount {
                Text("−\(decreaseAmount)%")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.red)
                    .shadow(color: .red.opacity(0.26), radius: 1.5, y: 0.2)
                    .scaleEffect(accessibilityReduceMotion ? 1 : (decreaseBounce ? 1.08 : 0.94))
                    .offset(x: 1, y: -3)
                    .transition(
                        accessibilityReduceMotion
                            ? .opacity
                            : .scale(scale: 0.78).combined(with: .opacity)
                    )
                    .zIndex(1)
            }
        }
    }

    private var accountEmailView: some View {
        Text(verbatim: model.currentAccountEmail ?? "未提供 Email")
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(.primary.opacity(model.currentAccountEmail == nil ? 0.48 : 0.82))
            .lineLimit(1)
            .minimumScaleFactor(0.34)
            .allowsTightening(true)
            .frame(width: 138, alignment: .leading)
            .help(model.currentAccountEmail ?? "目前帳號尚未提供 Email")
    }

    private var controlsColumn: some View {
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 8) {
                pasteShortcutButton
                pasteAndSubmitShortcutButton
            }
            .frame(width: 152, height: 18, alignment: .trailing)

            HStack(spacing: 8) {
                detailsShortcutButton
                updateShortcutButton
            }
            .frame(width: 152, height: 18, alignment: .trailing)

            gitControlsRow
        }
        .frame(width: 152, height: 55, alignment: .topTrailing)
    }

    private var detailsShortcutButton: some View {
        HUDActionCard(
            title: "詳細",
            systemImage: "rectangle.and.text.magnifyingglass",
            iconSize: 12,
            action: showDetails,
            isDisabled: false,
            helpText: "開啟詳細面板",
            accessibilityLabel: "開啟詳細面板",
            isHovered: $isDetailsHovered
        )
    }

    private var pasteShortcutButton: some View {
        HUDActionCard(
            title: "貼上",
            systemImage: "doc.on.clipboard",
            iconSize: 14,
            action: pasteClipboard,
            isDisabled: !layoutState.isCodexFocused,
            helpText: layoutState.isCodexFocused ? "貼上剪貼簿內容" : "切換回 Codex 後可貼上",
            accessibilityLabel: "貼上剪貼簿內容",
            isHovered: $isPasteHovered
        )
    }

    private var pasteAndSubmitShortcutButton: some View {
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
            isHovered: $isPasteAndSubmitHovered
        )
        .opacity(isPasteAndSubmitInFlight ? 0.45 : 1)
    }

    private var gitControlsRow: some View {
        HStack(spacing: 0) {
            Button(action: showGitWorkspace) {
                HStack(spacing: 2) {
                    Text("<>")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                    Text("Git 工作區")
                        .font(.system(size: 8.2, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.primary.opacity(gitCoordinator.isWorkspaceKnown ? 0.82 : 0.46))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
                .frame(width: 72, height: 17)
                .background(
                    isGitHovered ? Color.primary.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .disabled(!gitCoordinator.isWorkspaceKnown)
            .onHover { isGitHovered = $0 }
            .help(gitCoordinator.isWorkspaceKnown ? "開啟 Git 工作區（\(gitCoordinator.compactStatusLabel)）" : "目前 Codex 工作區尚未解析")
            .accessibilityLabel("Git 工作區")
            .accessibilityValue(gitCoordinator.compactStatusLabel)

            Button(action: commitShortcutAction) {
                HStack(spacing: 2) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Commit")
                        .font(.system(size: 8.2, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.primary.opacity(isCommitHovered ? 0.96 : 0.76))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
                .frame(width: 44, height: 17)
                .background(isCommitHovered ? Color.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(gitCoordinator.operationState.isBusy)
            .onHover { isCommitHovered = $0 }
            .help("Commit：開啟 Git 工作區並要求確認")
            .accessibilityLabel("Commit")
            .accessibilityValue(gitCoordinator.isWorkspaceKnown ? "開啟 Git 工作區並要求確認" : "工作區尚未解析")

            Button(action: pushShortcutAction) {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Push")
                        .font(.system(size: 8.2, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.primary.opacity(isPushHovered ? 0.96 : 0.76))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
                .frame(width: 36, height: 17)
                .background(isPushHovered ? Color.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(gitCoordinator.operationState.isBusy)
            .onHover { isPushHovered = $0 }
            .help("Push：開啟 Git 工作區並要求確認")
            .accessibilityLabel("Push")
            .accessibilityValue(gitCoordinator.isWorkspaceKnown ? "開啟 Git 工作區並要求確認" : "工作區尚未解析")
        }
        .frame(width: 152, height: 17, alignment: .trailing)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.22), lineWidth: 0.8)
        }
        .overlay {
            HStack(spacing: 0) {
                Color.clear.frame(width: 72, height: 17)
                Rectangle().fill(Color.primary.opacity(0.18)).frame(width: 1, height: 11)
                Color.clear.frame(width: 43, height: 17)
                Rectangle().fill(Color.primary.opacity(0.18)).frame(width: 1, height: 11)
                Color.clear.frame(width: 35, height: 17)
            }
            .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
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
            hudPulseBorder(
                frameOpacity: opacity,
                glowRadius: accessibilityReduceMotion ? 0 : min(profile.glowRadius, 4)
            )
        } else if accessibilityReduceMotion && hasLiveHUDData {
            hudPulseBorder(frameOpacity: 0.14, glowRadius: 0)
        }
    }

    private func hudPulseBorder(frameOpacity: Double, glowRadius: Double) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: FloatingHUDLayout.cornerRadius, style: .continuous)
                .stroke(
                    model.menuBarColor.opacity(max(0.28, frameOpacity)),
                    lineWidth: frameOpacity > 0.48 ? 2.35 : 2.0
                )
                .shadow(
                    color: model.menuBarColor.opacity(min(0.9, frameOpacity * 1.18)),
                    radius: glowRadius
                )
            RoundedRectangle(cornerRadius: FloatingHUDLayout.cornerRadius, style: .continuous)
                .stroke(model.menuBarColor.opacity(min(0.62, frameOpacity * 0.74)), lineWidth: 1.4)
                .blur(radius: max(2, glowRadius * 0.42))
        }
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

    private var updateShortcutButton: some View {
        HUDActionCard(
            title: "更新",
            systemImage: updateShortcutIcon,
            iconSize: 13,
            action: updateShortcutAction,
            isDisabled: false,
            helpText: hasAvailableUpdate ? "有更新可用，開啟更新面板" : "檢查更新",
            accessibilityLabel: hasAvailableUpdate ? "有更新可用" : "檢查更新",
            iconColor: hasAvailableUpdate ? .orange : .primary,
            isHovered: $isUpdateHovered
        )
        .accessibilityValue(hasAvailableUpdate ? "開啟更新面板" : "檢查目前版本")
    }

    private func commitShortcutAction() {
        // Opening the workspace is always safe. If the user has already
        // selected files and entered a message, surface the existing
        // confirmation in that panel; no Git mutation happens here.
        if gitCoordinator.isWorkspaceKnown {
            gitCoordinator.requestCommitConfirmation()
        }
        showGitWorkspace()
    }

    private func pushShortcutAction() {
        if gitCoordinator.isWorkspaceKnown {
            gitCoordinator.requestPushConfirmation()
        }
        showGitWorkspace()
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
        withAnimation(.easeOut(duration: 0.12)) {
            decreaseAmount = nil
            decreaseBounce = false
        }
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
        withAnimation(
            accessibilityReduceMotion
                ? .easeIn(duration: 0.12)
                : .spring(response: 0.25, dampingFraction: 0.58)
        ) {
            decreaseAmount = totalAmount
            decreaseBounce = !accessibilityReduceMotion
            decreaseAnimationID &+= 1
        }
    }

    private var livePresentation: HUDDualQuotaPresentation? {
        HUDQuotaPresentationPolicy.make(
            snapshot: model.snapshot,
            profileID: model.currentProfileID,
            now: model.currentDate
        )
    }

    private var displayedPresentation: HUDDualQuotaPresentation? {
        livePresentation ?? HUDVisibilityPolicy.cachedPresentation(
            currentProfileID: model.currentProfileID,
            cached: presentationCache
        )
    }

    private var hudAccessibilityValue: String {
        let rows = [
            (label: HUDQuotaWindowKind.fiveHour.label, presentation: displayedPresentation?.fiveHour),
            (label: HUDQuotaWindowKind.sevenDay.label, presentation: displayedPresentation?.sevenDay)
        ]
        let quotaText = rows.map { row in
            guard let presentation = row.presentation else {
                return "\(row.label)窗口，資料更新中"
            }
            let reset = presentation.resetDescription == "更新中" || presentation.resetDescription == "已重置"
                ? presentation.resetDescription
                : "\(presentation.resetDescription)後重置"
            return "\(row.label)窗口，剩餘 \(presentation.remainingPercent)%，\(reset)"
        }.joined(separator: "；")
        return "Codex，\(quotaText)，\(model.dataAgeText)，帳號 \(model.currentAccountEmail ?? "未提供 Email")。提供更新通知、詳細面板、只貼上、貼上並送出、Commit 與 Push 快捷鈕"
    }

    private func cacheCurrentPresentation() {
        guard let presentation = HUDQuotaPresentationPolicy.make(
            snapshot: model.snapshot,
            profileID: model.currentProfileID,
            now: model.currentDate
        ), let cached = HUDVisibilityPolicy.presentationSnapshot(
            currentProfileID: model.currentProfileID,
            trackedProfileID: trackedProfileID,
            lastUpdated: model.lastUpdated,
            presentation: presentation
        ) else { return }
        hasPresentedHUD = true
        presentationCache = cached
    }

}

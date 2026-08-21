import AppKit
import Combine
import CoreGraphics
import SwiftUI

private enum FloatingHUDLayout {
    // The compact HUD keeps the percentage and reset countdown in one
    // vertical cluster.  These heights are about 10% shorter than the
    // previous 52/46pt layouts while still leaving enough room for the
    // readable two-line content and the action buttons.
    static let bottomRightSize = NSSize(width: 300, height: 47)
    static let topRightSize = NSSize(width: 300, height: 42)
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
    var onShowDetails: (() -> Void)?
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
            pasteClipboard: { [weak self] in self?.pasteClipboard() },
            pasteAndSubmit: { [weak self] completion in
                guard let self else {
                    completion(false)
                    return
                }
                self.pasteAndSubmit(completion: completion)
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
            checkForUpdates: { [weak self] in self?.model.checkForUpdates() },
            cancelUpdateCheck: { [weak self] in self?.model.cancelUpdateCheck() },
            downloadAvailableUpdate: { [weak self] in self?.model.downloadAvailableUpdate() },
            revealDownloadedUpdate: { [weak self] in self?.model.revealDownloadedUpdate() },
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
        guard model.floatingHUDEnabled,
              model.hudRemainingPercent != nil else {
            layoutState.isCodexFocused = false
            panel.orderOut(nil)
            return
        }

        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let codexIsFocused = frontmostApplication.map(isCodexApplication) == true
        guard codexIsFocused, let codexApp = frontmostApplication else {
            // Do not leave a floating usage panel over unrelated apps. Keep
            // the last Codex process/frame in memory so returning to Codex
            // restores the same relative position without a jump.
            layoutState.isCodexFocused = false
            panel.orderOut(nil)
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
        layoutState.isCodexFocused = true
        position(panel, beside: codexApp)
        panel.alphaValue = 1.0
        // Re-ordering the hosting panel while a SwiftUI context menu is open
        // makes AppKit recalculate the menu anchor and produces a visible
        // wobble. The panel is already at the floating level, so only bring
        // it forward when transitioning from hidden to visible.
        if !panel.isVisible {
            panel.orderFrontRegardless()
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

    private func position(_ panel: NSPanel, beside application: NSRunningApplication) {
        let quartzTargetFrame = codexWindowFrame(for: application.processIdentifier)
        let displayMapping = quartzTargetFrame.flatMap(quartzDisplayMapping(for:))
        let targetFrame: NSRect? = quartzTargetFrame.flatMap { quartzFrame in
            guard let displayMapping else { return nil }
            return appKitWindowFrame(from: quartzFrame, mapping: displayMapping)
        }
        // Use the display that actually contains Codex. If the window list is
        // momentarily unavailable while macOS changes Spaces/displays, keep
        // the last known display instead of falling back to NSScreen.main and
        // making the HUD jump across monitors.
        let visibleFrame = displayMapping?.screen.visibleFrame
            ?? lastCodexVisibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame

        guard let visibleFrame else { return }

        // During a Space/display transition CGWindowList can briefly return
        // no Codex window. Preserve the current HUD position until the next
        // tick rather than moving it to a guessed screen corner.
        if quartzTargetFrame == nil, targetFrame == nil,
           lastCodexWindowFrame != nil, panel.isVisible {
            return
        }

        let preferredFrame = targetFrame ?? visibleFrame
        if let targetFrame {
            lastCodexWindowFrame = targetFrame
        }
        if let displayVisibleFrame = displayMapping?.screen.visibleFrame {
            lastCodexVisibleFrame = displayVisibleFrame
        }

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
            return
        }
        defer {
            lastPositionedProcessID = application.processIdentifier
            lastPositionedCodexWindowFrame = targetFrame
            lastPositionedVisibleFrame = visibleFrame
            lastPositionedPanelSize = panel.frame.size
        }

        guard let targetFrame else {
            applySize(FloatingHUDLayout.bottomRightSize, to: panel)
            var x = preferredFrame.maxX - panel.frame.width - 18
            var y = preferredFrame.maxY - panel.frame.height - 18
            x = min(x, visibleFrame.maxX - panel.frame.width - 8)
            x = max(x, visibleFrame.minX + 8)
            y = min(y, visibleFrame.maxY - panel.frame.height - 8)
            y = max(y, visibleFrame.minY + 8)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            return
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
            return
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
            return
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
            return
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
            return
        }

        lastPlacement = .bottomRight
        layoutState.placement = .bottomRight
        let size = FloatingHUDLayout.bottomRightSize
        applySize(size, to: panel)
        var x = preferredFrame.maxX - size.width - 18
        var y = preferredFrame.maxY - size.height - 18
        x = min(x, visibleFrame.maxX - size.width - 8)
        x = max(x, visibleFrame.minX + 8)
        y = min(y, visibleFrame.maxY - size.height - 8)
        y = max(y, visibleFrame.minY + 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        saveAnchor(origin: panel.frame.origin, targetFrame: targetFrame, panelSize: size, placement: .bottomRight)
    }

    private func applySize(_ size: NSSize, to panel: NSPanel) {
        guard panel.frame.size != size else { return }
        panel.setContentSize(size)
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
            return QuartzDisplayMapping(
                screen: screen,
                quartzFrame: quartzFrame,
                scaleX: screen.frame.width / quartzFrame.width,
                scaleY: screen.frame.height / quartzFrame.height
            )
        }

        // Prefer the display containing the window center. If a window spans
        // two displays, the largest overlap is the stable fallback.
        return candidates.max { lhs, rhs in
            func score(_ mapping: QuartzDisplayMapping) -> CGFloat {
                let intersection = mapping.quartzFrame.intersection(windowFrame)
                let area = max(0, intersection.width) * max(0, intersection.height)
                return mapping.quartzFrame.contains(center) ? 1_000_000_000 + area : area
            }
            return score(lhs) < score(rhs)
        }
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
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        return windows.compactMap { info -> CGRect? in
            guard let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID == processID,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  width >= 300,
                  height >= 200 else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }
        .max { lhs, rhs in lhs.width * lhs.height < rhs.width * rhs.height }
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
    @ObservedObject var layoutState: FloatingHUDLayoutState
    let pasteClipboard: () -> Void
    let pasteAndSubmit: (@escaping (Bool) -> Void) -> Void
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
    let checkForUpdates: () -> Void
    let cancelUpdateCheck: () -> Void
    let downloadAvailableUpdate: () -> Void
    let revealDownloadedUpdate: () -> Void
    let openReleasePage: () -> Void
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isRefreshHovered = false
    @State private var isDetailsHovered = false
    @State private var isPasteHovered = false
    @State private var isPasteAndSubmitHovered = false
    @State private var isPasteAndSubmitInFlight = false
    @State private var trackedProfileID: UUID?
    @State private var lastLivePercent: Int?
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
            if model.hudRemainingPercent == nil {
                // Keep the host at its normal size while the controller orders it
                // out. This prevents a one-frame partial HUD from being painted
                // during an account/focus transition.
                Color.clear
                    .frame(width: layoutState.size.width, height: layoutState.size.height)
            } else if let profile = HUDWarningPolicy.framePulseProfile(
                remainingPercent: model.hudRemainingPercent,
                connectionState: model.connectionState,
                isStale: model.isStale
            ), !accessibilityReduceMotion {
                TimelineView(.periodic(from: .now, by: profile.period / 10.0)) { context in
                    hudContainer(frameOpacity: frameOpacity(at: context.date, profile: profile), glowRadius: profile.glowRadius)
                }
            } else {
                hudContainer(
                    frameOpacity: accessibilityReduceMotion && hasLiveHUDData ? 0.14 : 0,
                    glowRadius: 0
                )
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
                Button("下載") {
                    guard let release = model.updateState.release else { return }
                    updateFeedback = UpdateFeedback(
                        kind: .downloading,
                        title: "正在下載更新…",
                        message: "正在驗證 \(release.version)"
                    )
                    downloadAvailableUpdate()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            case .downloaded:
                Button("顯示") {
                    revealDownloadedUpdate()
                    updateFeedback = nil
                }
                .buttonStyle(.bordered)
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
    private func hudContainer(frameOpacity: Double, glowRadius: Double) -> some View {
        HStack(spacing: 4) {
            // The progress bar used to repeat the same information as the
            // large percentage label.  Keep one clear source of truth: the
            // percentage sits above its reset countdown in this compact
            // cluster.
            VStack(alignment: .leading, spacing: -2) {
                // Keep the decrease badge inside the percentage cluster. It
                // remains visible for the full animation and never escapes
                // the rounded HUD mask.
                ZStack(alignment: .topTrailing) {
                    percentTextView
                    if let decreaseAmount {
                        Text("−\(decreaseAmount)%")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.red)
                            .shadow(color: .red.opacity(0.26), radius: 1.5, y: 0.2)
                            .scaleEffect(accessibilityReduceMotion ? 1 : (decreaseBounce ? 1.08 : 0.94), anchor: .center)
                            .offset(x: 5, y: -2)
                            .transition(
                                accessibilityReduceMotion
                                    ? .opacity
                                    : .scale(scale: 0.78).combined(with: .opacity)
                            )
                            .zIndex(1)
                    }
                }
                .frame(width: 86, height: 28, alignment: .leading)

                Text(hudResetDescription)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(model.menuBarColor)
                    .multilineTextAlignment(.leading)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .shadow(color: .black.opacity(0.12), radius: 0.7, y: 0.4)
            }
            // Reserve a compact, stable column for the usage information so
            // the new middle shortcuts never squeeze the countdown into an
            // unreadable width.
            .frame(width: 178, alignment: .leading)

            HStack(spacing: 2) {
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary.opacity(isRefreshHovered ? 0.95 : 0.66))
                        .frame(width: 22, height: 22)
                        .background(
                            isRefreshHovered ? Color.primary.opacity(0.12) : Color.clear,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .onHover { isRefreshHovered = $0 }
                .help("重新整理")
                .accessibilityLabel("重新整理")

                Button(action: showDetails) {
                    Image(systemName: "rectangle.and.text.magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary.opacity(isDetailsHovered ? 0.95 : 0.66))
                        .frame(width: 22, height: 22)
                        .background(
                            isDetailsHovered ? Color.primary.opacity(0.12) : Color.clear,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .onHover { isDetailsHovered = $0 }
                .help("開啟詳細面板")
                .accessibilityLabel("開啟詳細面板")
            }
            .frame(width: 48, height: 24, alignment: .center)

            HStack(spacing: 2) {
                Button(action: pasteClipboard) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 22, height: 22)
                        .background(
                            isPasteHovered ? Color.primary.opacity(0.14) : Color.clear,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(!layoutState.isCodexFocused)
                .onHover { isPasteHovered = $0 }
                .help(layoutState.isCodexFocused ? "貼上剪貼簿內容" : "切換回 Codex 後可貼上")

                Button {
                    guard !isPasteAndSubmitInFlight else { return }
                    isPasteAndSubmitInFlight = true
                    pasteAndSubmit { _ in
                        isPasteAndSubmitInFlight = false
                    }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 22, height: 22)
                        .background(
                            isPasteAndSubmitHovered ? Color.primary.opacity(0.14) : Color.clear,
                            in: Circle()
                        )
                        .opacity(isPasteAndSubmitInFlight ? 0.45 : 1)
                }
                .buttonStyle(.plain)
                .disabled(isPasteAndSubmitInFlight || !layoutState.isCodexFocused)
                .onHover { isPasteAndSubmitHovered = $0 }
                .help(layoutState.isCodexFocused ? "貼上並送出" : "切換回 Codex 後可貼上並送出")
            }
            .frame(width: 46, height: 24, alignment: .trailing)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, layoutState.placement == .topRight ? 0 : 2)
        .frame(width: layoutState.size.width, height: layoutState.size.height, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: FloatingHUDLayout.cornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: FloatingHUDLayout.cornerRadius, style: .continuous))
        .overlay {
            if frameOpacity > 0 {
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
                    // A second blurred contour keeps the breathing readable
                    // on light and dark Codex surfaces without changing HUD
                    // geometry or adding a hard gray border.
                    RoundedRectangle(cornerRadius: FloatingHUDLayout.cornerRadius, style: .continuous)
                        .stroke(model.menuBarColor.opacity(min(0.62, frameOpacity * 0.74)), lineWidth: 1.4)
                        .blur(radius: max(2, glowRadius * 0.42))
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Codex 用量")
        .accessibilityValue("\(model.menuBarTitle)，\(model.dataAgeText)。提供重新整理、詳細面板、只貼上與貼上並送出按鈕")
        .animation(.easeOut(duration: 0.18), value: decreaseAmount)
        .onAppear {
            trackedProfileID = model.currentProfileID
            syncLiveBaseline()
        }
        .onChange(of: model.currentProfileID) { _, newProfileID in
            resetTracking(for: newProfileID)
        }
        .onChange(of: model.hudRemainingPercent) { _, _ in
            observePercentChange()
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

    @ViewBuilder
    private var contextMenuContent: some View {
        Section {
            Text(model.currentProfile?.displayName ?? "未識別帳號")
                .font(.headline)
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
            Button(action: requestUpdateCheck) {
                Label("檢查更新", systemImage: "arrow.down.circle")
            }

            switch model.updateState {
            case .available(let release):
                Button {
                    downloadAvailableUpdate()
                } label: {
                    Label("下載並驗證更新 \(release.version)", systemImage: "arrow.down.app")
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
                Button(action: revealDownloadedUpdate) {
                    Label("在 Finder 顯示已下載更新", systemImage: "folder")
                }
                Button(action: showDetails) {
                    Label("開啟更新安裝說明", systemImage: "info.circle")
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
                    Button {
                        selectProfile(profile.id)
                        setAccountScope(.current)
                    } label: {
                        Label {
                            Text(profile.isUnidentified ? "⚠︎ \(profile.displayName)" : profile.displayName)
                        } icon: {
                            Image(systemName: profile.id == model.currentProfileID ? "checkmark" : "person")
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

    private var percentTextView: some View {
        percentLabel(scale: 1)
    }

    private func percentLabel(scale: CGFloat) -> some View {
        Text(percentWithSymbol)
            .font(.system(size: 25, weight: .bold, design: .rounded))
            .foregroundStyle(model.menuBarColor)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .allowsTightening(true)
            .scaleEffect(scale * (accessibilityReduceMotion || !decreaseBounce ? 1 : 1.16))
            .shadow(color: .black.opacity(0.16), radius: 0.8, y: 0.5)
            .animation(
                accessibilityReduceMotion
                    ? .easeOut(duration: 0.18)
                    : .spring(response: 0.25, dampingFraction: 0.58),
                value: decreaseBounce
            )
    }

    private func frameOpacity(at date: Date, profile: HUDFramePulseProfile) -> Double {
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: profile.period) / profile.period
        let wave = (sin(phase * 2 * .pi) + 1) / 2
        return profile.minOpacity + ((profile.maxOpacity - profile.minOpacity) * wave)
    }

    private var hasLiveHUDData: Bool {
        model.connectionState == .connected
            && !model.isStale
            && model.hudRemainingPercent != nil
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

    private var hudResetDescription: String {
        let description = model.resetDescription(model.hudResetTimestamp)
        guard description.hasSuffix("後重置") else { return description }
        return description
            .replacingOccurrences(of: "後重置", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private var percentWithSymbol: String {
        guard let remaining = model.menuBarRemainingPercent else { return "—" }
        return "\(remaining)%"
    }

}

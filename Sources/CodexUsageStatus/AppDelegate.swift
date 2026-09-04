import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var model: UsageViewModel!
    private var modelObservation: AnyCancellable?
    private var statusItemUpdateTask: Task<Void, Never>?
    private var terminationReplyPending = false
    private var floatingHUD: FloatingHUDPanelController!
    private let popoverSelectionController = PopoverSelectionController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            // Keep the status item compact while making the product name and
            // current percentage easy to scan as two centered lines.
            // The two-line title is narrow; keep only a small amount of
            // breathing room so it does not push neighboring menu-bar items.
            statusItem.length = 40
            button.cell?.wraps = true
            button.cell?.isScrollable = false
            button.cell?.truncatesLastVisibleLine = false
            button.alignment = .center
            button.toolTip = "Codex Usage Status"
            button.attributedTitle = NSAttributedString(
                string: "Codex\n—",
                attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)
                ]
            )
        }

        // Make the status item interactive immediately. Model/store/App
        // Server construction is intentionally staged to the next run-loop
        // turn so LaunchServices and menu-bar hit testing are responsive.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.bootstrapModel()
        }
    }

    private func bootstrapModel() {
        guard model == nil else { return }
        model = UsageViewModel()

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentSize = NSSize(width: 430, height: 700)
        popover.contentViewController = NSHostingController(
            rootView: UsagePopoverView(
                model: model,
                selectionController: popoverSelectionController,
                openCodex: { [weak self] in self?.openCodex() },
                resetHUDPosition: { [weak self] in self?.floatingHUD?.resetPosition() },
                quit: { NSApp.terminate(nil) },
                onContentHeightChange: { [weak self] height in
                    self?.resizePopover(toFitContentHeight: height)
                }
            )
        )

        floatingHUD = FloatingHUDPanelController(model: model)
        floatingHUD.onShowDetails = { [weak self] in self?.showPopover(tab: .overview) }
        floatingHUD.onOpenCodex = { [weak self] in self?.openCodex() }
        floatingHUD.onQuit = { NSApp.terminate(nil) }
        floatingHUD.start()

        modelObservation = model.objectWillChange.sink { [weak self] _ in
            self?.scheduleStatusItemUpdate()
        }
        model.start()
        updateStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeOutsideClickMonitor()
        removeLocalClickMonitor()
        statusItemUpdateTask?.cancel()
        statusItemUpdateTask = nil
        floatingHUD?.stop()
        model?.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationReplyPending else { return .terminateNow }
        terminationReplyPending = true
        Task { @MainActor [weak self] in
            await self?.model?.prepareForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model?.refresh()
    }

    @objc private func togglePopover(_ sender: Any?) {
        showPopover(toggle: true, sender: sender)
    }

    private func showPopover(tab: UsagePopoverTab = .overview, toggle: Bool = false, sender: Any? = nil) {
        guard let button = statusItem?.button, let popover, let model else { return }
        popoverSelectionController.select(tab)
        if toggle && popover.isShown {
            popover.performClose(sender)
        } else {
            if popover.isShown { popover.performClose(sender) }
            // Accessory apps can present an inactive NSPopover on its first
            // click from either the status item or the HUD Details action.
            // Activate the app first so AppKit resolves the popover's active
            // material immediately, then pin the appearance before the
            // backing window is created.
            PopoverPresentationPolicy.prepareForPresentation(application: NSApp, popover: popover)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            PopoverPresentationPolicy.apply(to: popover)
            installOutsideClickMonitor()
            model.refresh()
        }
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        removeLocalClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePopoverForOutsideClick()
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.closePopoverForOutsideClick()
            }
            return event
        }
    }

    private func closePopoverForOutsideClick() {
        guard popover?.isShown == true else { return }
        let location = NSEvent.mouseLocation
        let popoverFrame = popover.contentViewController?.view.window?.frame ?? .zero
        let statusFrame: NSRect
        if let button = statusItem.button, let window = button.window {
            let buttonRectInWindow = button.convert(button.bounds, to: nil)
            statusFrame = window.convertToScreen(buttonRectInWindow)
        } else {
            statusFrame = .zero
        }
        guard !popoverFrame.contains(location), !statusFrame.contains(location) else { return }
        popover.performClose(nil)
        removeOutsideClickMonitor()
        removeLocalClickMonitor()
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func removeLocalClickMonitor() {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button, let model else { return }
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        // The menu bar button is only about 22pt tall. Tight line metrics keep
        // both rows visible instead of clipping the first row at the top.
        paragraphStyle.lineSpacing = -3
        paragraphStyle.minimumLineHeight = 7
        paragraphStyle.maximumLineHeight = 9
        let statusFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)
        button.attributedTitle = NSAttributedString(
            string: model.menuBarStackedTitle,
            attributes: [
                .foregroundColor: NSColor(model.menuBarColor),
                .font: statusFont,
                .paragraphStyle: paragraphStyle,
                // Lower the compact title slightly so its top line aligns
                // with neighboring two-line menu-bar widgets.
                .baselineOffset: -2
            ]
        )
        button.toolTip = model.statusTooltip
    }

    /// Coalesce bursts from quota/account updates so AppKit does not rebuild
    /// the attributed status title for every intermediate model publication.
    private func scheduleStatusItemUpdate() {
        guard statusItemUpdateTask == nil else { return }
        statusItemUpdateTask = Task { @MainActor [weak self] in
            defer { self?.statusItemUpdateTask = nil }
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.updateStatusItem()
        }
    }

    private func openCodex() {
        if let running = NSWorkspace.shared.runningApplications.first(where: CodexApplicationPolicy.isCodexApplication) {
            running.activate(options: [])
            return
        }
        let candidates = ["/Applications/Codex.app", "/Applications/ChatGPT.app"]
        if let appPath = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0)
                && CodexApplicationPolicy.isTrustedBundle(at: URL(fileURLWithPath: $0, isDirectory: true))
        }) {
            NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
        }
    }

    private func resizePopover(toFitContentHeight measuredHeight: CGFloat) {
        guard let popover, measuredHeight.isFinite, measuredHeight > 0 else { return }

        let minimumHeight: CGFloat = 280
        let visibleFrame = popover.contentViewController?.view.window?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
        // Leave a small margin for the menu bar/dock.  If a tab is taller than
        // the display, the hidden-indicator ScrollView remains the safe
        // fallback rather than allowing the popover to extend off-screen.
        let maximumHeight = max(minimumHeight, (visibleFrame?.height ?? 900) - 64)
        let targetHeight = min(max(measuredHeight, minimumHeight), maximumHeight)
        guard abs(popover.contentSize.height - targetHeight) > 1 else { return }
        popover.contentSize = NSSize(width: 430, height: ceil(targetHeight))
    }
}

extension AppDelegate: NSPopoverDelegate {
    func popoverDidShow(_ notification: Notification) {
        guard PopoverPresentationPolicy.reappliesAfterPopoverDidShow,
              popover.contentViewController?.view != nil else { return }
        // NSPopover creates its backing window during show(). Reapply after
        // the delegate callback so the real window, rather than a pre-show
        // view with no window, receives the stable appearance on first open.
        PopoverPresentationPolicy.apply(to: popover)
    }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
        removeLocalClickMonitor()
    }
}

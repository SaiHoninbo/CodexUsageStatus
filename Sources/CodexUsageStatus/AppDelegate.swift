import AppKit
import Combine
import SwiftUI

@MainActor
final class DetailsRouter: ObservableObject {
    @Published var destination: DetailsDestination = .overview
    @Published private(set) var requestGeneration = 0

    func route(to destination: DetailsDestination) {
        self.destination = destination
        requestGeneration &+= 1
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var model: UsageViewModel!
    private var modelObservation: AnyCancellable?
    private var floatingHUD: FloatingHUDPanelController!
    private let gitCoordinator = GitWorkspaceCoordinator()
    private let detailsRouter = DetailsRouter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model = UsageViewModel()

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
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentSize = NSSize(width: 430, height: 700)
        popover.contentViewController = NSHostingController(
            rootView: UsagePopoverView(
                model: model,
                gitCoordinator: gitCoordinator,
                detailsRouter: detailsRouter,
                openCodex: { [weak self] in self?.openCodex() },
                resetHUDPosition: { [weak self] in self?.floatingHUD?.resetPosition() },
                quit: { NSApp.terminate(nil) }
            )
        )

        floatingHUD = FloatingHUDPanelController(model: model, gitCoordinator: gitCoordinator)
        floatingHUD.onShowDetails = { [weak self] in self?.showPopover(destination: .overview) }
        floatingHUD.onShowGitWorkspace = { [weak self] in self?.showPopover(destination: .gitWorkspace) }
        floatingHUD.onOpenCodex = { [weak self] in self?.openCodex() }
        floatingHUD.onQuit = { NSApp.terminate(nil) }
        floatingHUD.start()

        modelObservation = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateStatusItem() }
        }
        model.start()
        updateStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeOutsideClickMonitor()
        removeLocalClickMonitor()
        floatingHUD?.stop()
        model?.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model?.refresh()
    }

    @objc private func togglePopover(_ sender: Any?) {
        showPopover(toggle: true, sender: sender)
    }

    private func showPopover(destination: DetailsDestination = .overview, toggle: Bool = false, sender: Any? = nil) {
        guard let button = statusItem.button else { return }
        detailsRouter.route(to: destination)
        if destination == .gitWorkspace { gitCoordinator.refreshNow() }
        if toggle && popover.isShown {
            popover.performClose(sender)
        } else {
            if popover.isShown { popover.performClose(sender) }
            // Accessory apps can present an inactive NSPopover on its first
            // click. Pin the content and popover window to the same dark
            // appearance before showing it so the surface does not change
            // after a second click inside the panel.
            if let popoverView = popover.contentViewController?.view {
                PopoverPresentationPolicy.apply(to: popoverView)
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if let popoverView = popover.contentViewController?.view {
                PopoverPresentationPolicy.apply(to: popoverView)
            }
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

    private func openCodex() {
        if let running = NSWorkspace.shared.runningApplications.first(where: CodexWorkspaceResolver.isCodexApplication) {
            running.activate(options: [])
            return
        }
        let candidates = ["/Applications/Codex.app", "/Applications/ChatGPT.app"]
        if let appPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
        }
    }
}

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
        removeLocalClickMonitor()
    }
}

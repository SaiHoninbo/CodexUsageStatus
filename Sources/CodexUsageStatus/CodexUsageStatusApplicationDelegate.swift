import AppKit

@MainActor
@_spi(CodexUsageStatusApp)
public final class CodexUsageStatusApplicationDelegate: NSObject, NSApplicationDelegate {
    private let appDelegate = AppDelegate()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        appDelegate.applicationDidFinishLaunching(notification)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        appDelegate.applicationWillTerminate(notification)
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        appDelegate.applicationShouldTerminate(sender)
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        appDelegate.applicationDidBecomeActive(notification)
    }

    public func showProductSettings() {
        appDelegate.showProductSettings()
    }
}

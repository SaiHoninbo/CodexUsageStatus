import AppKit

/// Keeps the details popover visually stable while an accessory app is not
/// active.  Without an explicit appearance, AppKit's popover material follows
/// the window active state: the first presentation can render as a pale
/// inactive surface and change to the dark surface only after a second click.
enum PopoverPresentationPolicy {
    static let preferredAppearanceName: NSAppearance.Name = .darkAqua
    static let reappliesAfterPopoverDidShow = true

    static func makeAppearance() -> NSAppearance {
        // .darkAqua is provided by every supported macOS release.
        NSAppearance(named: preferredAppearanceName)!
    }

    static func apply(to view: NSView) {
        let appearance = makeAppearance()
        view.appearance = appearance
        view.window?.appearance = appearance
    }

    static func apply(to popover: NSPopover) {
        let appearance = makeAppearance()
        // NSPopover owns the appearance used to create its backing window.
        // Pin it directly; changing only the content view can be overridden
        // by the popover's default vibrant-light effective appearance.
        popover.appearance = appearance
        if let popoverView = popover.contentViewController?.view {
            popoverView.appearance = appearance
            popoverView.window?.appearance = appearance
        }
    }
}

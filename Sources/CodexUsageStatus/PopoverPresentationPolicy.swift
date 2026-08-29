import AppKit

/// Keeps the details popover visually stable while an accessory app is not
/// active.  Without an explicit appearance, AppKit's popover material follows
/// the window active state: pinning the light appearance keeps the surface and
/// text contrast stable from the first click through subsequent presentations.
enum PopoverPresentationPolicy {
    static let preferredAppearanceName: NSAppearance.Name = .aqua
    static let reappliesAfterPopoverDidShow = true
    /// Status-item apps are normally inactive when their menu extra is clicked.
    /// Activating only for a user-requested popover presentation makes AppKit
    /// resolve the popover's active material on the first click.
    static let activatesApplicationBeforePresentation = true

    static func shouldActivateApplication(isActive: Bool) -> Bool {
        activatesApplicationBeforePresentation && !isActive
    }

    static func prepareForPresentation(application: NSApplication, popover: NSPopover) {
        if shouldActivateApplication(isActive: application.isActive) {
            application.activate(ignoringOtherApps: true)
        }
        apply(to: popover)
    }

    /// NSPopover's backing window contains an NSVisualEffectView whose default
    /// state follows window activity.  A menu-extra app can briefly remain
    /// inactive while the popover is being created, so pin the semantic
    /// popover material to its active appearance instead of waiting for a
    /// second click to make it look selected.
    static func applyActiveMaterial(to view: NSView) {
        if let effectView = view as? NSVisualEffectView {
            effectView.material = .popover
            effectView.state = .active
        }
        for subview in view.subviews {
            applyActiveMaterial(to: subview)
        }
    }

    static func makeAppearance() -> NSAppearance {
        // .aqua is provided by every supported macOS release and keeps the
        // details surface readable with the fixed-light HUD palette.
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
            if let window = popoverView.window {
                window.appearance = appearance
                if let contentView = window.contentView {
                    applyActiveMaterial(to: contentView)
                }
            }
        }
    }
}

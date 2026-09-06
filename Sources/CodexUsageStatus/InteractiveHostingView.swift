import AppKit
import SwiftUI

/// Hosting view used by the menu-extra popover and non-activating HUD.
///
/// AppKit normally lets an inactive window consume the first mouse-down while
/// it becomes key.  That is surprising for a utility surface: the first click
/// on a tab or action should be the click that performs the action.  Keeping
/// this policy at the hosting boundary makes event delivery explicit without
/// changing activation, focus, or the HUD's non-activating panel contract.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PopoverPresentationPolicy.acceptsFirstMouse
    }
}

/// NSHostingController's default view is an NSHostingView.  This controller
/// installs the first-click policy before the popover's backing window is
/// created, so the policy also applies to the first tab/action click.
final class FirstClickHostingController<Content: View>: NSHostingController<Content> {
    override func loadView() {
        let hostingView = FirstClickHostingView(rootView: rootView)
        hostingView.autoresizingMask = [.width, .height]
        view = hostingView
    }
}

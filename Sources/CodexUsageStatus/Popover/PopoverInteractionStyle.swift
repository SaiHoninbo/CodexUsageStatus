import SwiftUI

/// Value-semantic interaction contract shared by the Popover controls.  The
/// constants are kept outside the view tree so hit-target and feedback
/// behavior can be regression-tested without constructing AppKit windows.
enum PopoverInteractionPolicy {
    static let tabCellMinimumHeight: CGFloat = 34
    static let feedbackAffectsContentHeight = false
    static let actionExecutesOnMouseUp = true
}

/// Opening a Popover renders the existing authoritative/cache snapshot first.
/// A background refresh is only needed when the snapshot is unavailable or
/// stale; account management keeps its existing no-fan-out behavior because
/// its compact surface is backed by the local profile/cache projection.
enum PopoverRefreshPolicy {
    static func shouldRefreshOnPresentation(
        tab: UsagePopoverTab,
        hasAuthoritativeSnapshot: Bool = false,
        isStale: Bool = true
    ) -> Bool {
        guard tab != .accounts else { return false }
        return !hasAuthoritativeSnapshot || isStale
    }
}

/// Immediate navigation/disclosure changes are already visible in the
/// selected state or expanded content. Keeping the acknowledgement policy in
/// one place prevents a future call site from reintroducing a transient
/// overlay that adds visual churn without adding information.
enum PopoverAcknowledgementPolicy {
    static func shouldShow(for control: String) -> Bool {
        guard !control.hasPrefix("tab."), !control.hasPrefix("disclosure.") else {
            return false
        }
        return control != "accounts.otherAccountsDisclosure"
    }
}

/// Full account rows are a deliberate opt-in surface. The compact management
/// summary remains visible, while the potentially large profile projection is
/// only evaluated after the user expands the disclosure.
enum AccountManagementDisclosurePolicy {
    static let defaultExpanded = false

    static func showsAllAccounts(isExpanded: Bool) -> Bool {
        isExpanded
    }

    static func includesInOtherAccounts(isCurrent: Bool) -> Bool {
        !isCurrent
    }

    static func otherAccountsLabel(count: Int) -> String {
        "其他帳號 \(max(0, count))"
    }
}

/// Small, local acknowledgement for popover controls. It does not run the
/// action early; it only makes the mouse-down state visible immediately.
struct PopoverImmediateButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.975
    var controlID: String?

    init(pressedScale: CGFloat = 0.975, controlID: String? = nil) {
        self.pressedScale = pressedScale
        self.controlID = controlID
    }

    func makeBody(configuration: Configuration) -> some View {
        PopoverPressedLabel(
            label: configuration.label,
            isPressed: configuration.isPressed,
            controlID: controlID,
            pressedScale: pressedScale
        )
    }
}

/// Adds a mouse-down marker without replacing a native bordered/link/menu
/// style. This keeps AppKit/SwiftUI activation and mouse-up semantics owned by
/// the original control while extending the existing privacy-safe trace.
struct PopoverControlPressProbe: ViewModifier {
    let controlID: String
    @State private var hasLoggedPress = false

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !hasLoggedPress else { return }
                    hasLoggedPress = true
                    PopoverInteractionTrace.pressed(controlID)
                }
                .onEnded { _ in
                    hasLoggedPress = false
                }
        )
    }
}

extension View {
    func popoverControlPressProbe(_ controlID: String) -> some View {
        modifier(PopoverControlPressProbe(controlID: controlID))
    }
}

private struct PopoverPressedLabel<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let controlID: String?
    let pressedScale: CGFloat
    @State private var hasLoggedPress = false

    var body: some View {
        label
            .opacity(isPressed ? 0.82 : 1)
            .scaleEffect(isPressed ? pressedScale : 1)
            .animation(.easeOut(duration: 0.08), value: isPressed)
            .onChange(of: isPressed) { _, pressed in
                guard let controlID else { return }
                if pressed {
                    guard !hasLoggedPress else { return }
                    hasLoggedPress = true
                    PopoverInteractionTrace.pressed(controlID)
                } else {
                    hasLoggedPress = false
                }
            }
    }
}

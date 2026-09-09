import SwiftUI

/// Value-semantic interaction contract shared by the Popover controls.  The
/// constants are kept outside the view tree so hit-target and feedback
/// behavior can be regression-tested without constructing AppKit windows.
enum PopoverInteractionPolicy {
    static let tabCellMinimumHeight: CGFloat = 34
    static let feedbackAffectsContentHeight = false
    static let actionExecutesOnMouseUp = true
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

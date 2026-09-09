import SwiftUI

/// Small, local acknowledgement for popover controls. It does not run the
/// action early; it only makes the mouse-down state visible immediately.
struct PopoverImmediateButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.975

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

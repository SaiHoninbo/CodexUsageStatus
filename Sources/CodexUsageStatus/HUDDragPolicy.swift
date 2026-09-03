import CoreGraphics

/// Pure geometry for a HUD drag session.
///
/// The panel receives the pointer in window coordinates, converts that point
/// to screen coordinates, and keeps the original grab offset while the user
/// drags. Keeping this calculation outside the AppKit event handler makes the
/// drag path deterministic and prevents it from acquiring persistence or
/// layout side effects.
enum HUDDragPolicy {
    static func origin(screenPoint: CGPoint, dragOffset: CGPoint) -> CGPoint? {
        guard screenPoint.x.isFinite,
              screenPoint.y.isFinite,
              dragOffset.x.isFinite,
              dragOffset.y.isFinite else {
            return nil
        }

        let origin = CGPoint(
            x: screenPoint.x - dragOffset.x,
            y: screenPoint.y - dragOffset.y
        )
        guard origin.x.isFinite, origin.y.isFinite else { return nil }
        return origin
    }
}

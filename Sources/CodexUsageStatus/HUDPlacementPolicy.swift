import CoreGraphics
import Foundation

enum HUDPlacement: Int, Equatable {
    case bottomRight = 0
    case topRight = 1
}

struct HUDAnchor: Equatable {
    let rightInset: CGFloat
    let verticalInset: CGFloat
    let placement: HUDPlacement
}

enum HUDPlacementPolicy {
    static let rightEdgeTolerance: CGFloat = 80
    static let rightOverlapTolerance: CGFloat = 20
    static let centerHysteresis: CGFloat = 12

    static func placement(
        targetFrame: CGRect,
        hudFrame: CGRect,
        previous: HUDPlacement?
    ) -> HUDPlacement {
        let rightInset = (targetFrame.origin.x + targetFrame.size.width)
            - (hudFrame.origin.x + hudFrame.size.width)
        guard rightInset >= -rightOverlapTolerance,
              rightInset <= rightEdgeTolerance else {
            return .bottomRight
        }

        let centerDelta = (hudFrame.origin.y + hudFrame.size.height / 2)
            - (targetFrame.origin.y + targetFrame.size.height / 2)
        if centerDelta > centerHysteresis { return .topRight }
        if centerDelta < -centerHysteresis { return .bottomRight }
        return previous ?? .bottomRight
    }

    static func anchor(
        origin: CGPoint,
        targetFrame: CGRect,
        panelSize: CGSize,
        placement: HUDPlacement
    ) -> HUDAnchor {
        let rightInset = targetFrame.origin.x + targetFrame.size.width
            - (origin.x + panelSize.width)
        let verticalInset: CGFloat
        switch placement {
        case .topRight:
            verticalInset = targetFrame.origin.y + targetFrame.size.height
                - (origin.y + panelSize.height)
        case .bottomRight:
            verticalInset = origin.y - targetFrame.origin.y
        }
        return HUDAnchor(
            rightInset: rightInset,
            verticalInset: verticalInset,
            placement: placement
        )
    }

    static func origin(
        for anchor: HUDAnchor,
        targetFrame: CGRect,
        panelSize: CGSize
    ) -> CGPoint {
        let y: CGFloat
        switch anchor.placement {
        case .topRight:
            y = targetFrame.origin.y + targetFrame.size.height
                - anchor.verticalInset - panelSize.height
        case .bottomRight:
            y = targetFrame.origin.y + anchor.verticalInset
        }
        return CGPoint(
            x: targetFrame.origin.x + targetFrame.size.width
                - anchor.rightInset - panelSize.width,
            y: y
        )
    }

    static func resizedOrigin(
        origin point: CGPoint,
        targetFrame: CGRect,
        oldPanelSize: CGSize,
        newPanelSize: CGSize,
        placement: HUDPlacement
    ) -> CGPoint {
        origin(
            for: anchor(
                origin: point,
                targetFrame: targetFrame,
                panelSize: oldPanelSize,
                placement: placement
            ),
            targetFrame: targetFrame,
            panelSize: newPanelSize
        )
    }
}

import CoreGraphics
import Foundation

/// Geometry and typography for the C vertical HUD.  Keeping these values in
/// one pure type makes the five levels auditable and prevents independent
/// rows/cards from accidentally acquiring different scale factors.
struct HUDMetrics: Equatable {
    let scaleLevel: HUDScaleLevel

    static let canonicalPanelSize = CGSize(width: 520, height: 260)
    static let canonicalOuterPadding: CGFloat = 18
    static let canonicalQuotaRowHeight: CGFloat = 50
    static let canonicalQuotaGap: CGFloat = 8
    static let canonicalSectionGap: CGFloat = 14
    static let canonicalActionHeight: CGFloat = 48
    static let canonicalFooterHeight: CGFloat = 40
    static let canonicalActionSpacing: CGFloat = 10
    static let canonicalFooterSpacing: CGFloat = 12
    static let canonicalFooterCommitWidth: CGFloat = 80
    static let canonicalFooterPushWidth: CGFloat = 68
    static let canonicalFooterCommitPushWidth: CGFloat = 116
    static let canonicalCornerRadius: CGFloat = 24

    init(scaleLevel: HUDScaleLevel = .standard) {
        self.scaleLevel = scaleLevel
    }

    var factor: CGFloat { scaleLevel.scaleFactor }
    var panelSize: CGSize {
        CGSize(width: Self.canonicalPanelSize.width * factor,
               height: Self.canonicalPanelSize.height * factor)
    }
    var outerPadding: CGFloat { Self.canonicalOuterPadding * factor }
    var quotaRowHeight: CGFloat { Self.canonicalQuotaRowHeight * factor }
    var quotaGap: CGFloat { Self.canonicalQuotaGap * factor }
    var sectionGap: CGFloat { Self.canonicalSectionGap * factor }
    var actionHeight: CGFloat { Self.canonicalActionHeight * factor }
    var footerHeight: CGFloat { Self.canonicalFooterHeight * factor }
    var actionSpacing: CGFloat { Self.canonicalActionSpacing * factor }
    var footerSpacing: CGFloat { Self.canonicalFooterSpacing * factor }
    var cornerRadius: CGFloat { Self.canonicalCornerRadius * factor }
    var footerCommitWidth: CGFloat { Self.canonicalFooterCommitWidth * factor }
    var footerPushWidth: CGFloat { Self.canonicalFooterPushWidth * factor }
    var footerCommitPushWidth: CGFloat { Self.canonicalFooterCommitPushWidth * factor }
    var footerDividerGap: CGFloat { 4 * factor }
    var footerControlsWidth: CGFloat {
        footerCommitWidth + footerPushWidth + footerCommitPushWidth
            + (3 * 1) + (6 * footerDividerGap)
    }
    var footerEmailWidth: CGFloat {
        max(72 * factor, contentWidth - footerControlsWidth - (footerSpacing * 1.4))
    }

    var contentWidth: CGFloat {
        max(0, panelSize.width - (outerPadding * 2))
    }

    var actionCardWidth: CGFloat {
        (contentWidth - (actionSpacing * 3)) / 4
    }

    var quotaColumnHeight: CGFloat {
        (quotaRowHeight * 2) + quotaGap
    }

    var verticalContentHeight: CGFloat {
        quotaColumnHeight + sectionGap + actionHeight + sectionGap + footerHeight
    }
}

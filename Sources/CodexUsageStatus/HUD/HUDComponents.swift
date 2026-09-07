import Foundation
import SwiftUI

struct HUDQuotaRow: View {
    let kind: HUDQuotaWindowKind
    let presentation: HUDQuotaWindowPresentation?
    let isUpdating: Bool
    let width: CGFloat
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.hudThemePalette) private var palette

    init(
        kind: HUDQuotaWindowKind,
        presentation: HUDQuotaWindowPresentation?,
        isUpdating: Bool,
        width: CGFloat,
        height: CGFloat
    ) {
        self.kind = kind
        self.presentation = presentation
        self.isUpdating = isUpdating
        self.width = width
        self.height = height
    }

    private var accent: Color {
        switch kind {
        case .fiveHour: return palette.fiveHour
        case .sevenDay: return palette.sevenDay
        case .gptReserveWeekly: return palette.gptReserveWeekly
        }
    }

    private var systemImage: String {
        "clock"
    }

    private var fillFraction: CGFloat {
        CGFloat(max(0, min(1, presentation?.fillFraction ?? 0)))
    }

    private var percentText: String {
        presentation.map { "\($0.remainingPercent)%" } ?? "—%"
    }

    private var resetText: String {
        presentation?.resetDescription ?? (isUpdating ? "更新中" : "未提供")
    }

    private var cornerRadius: CGFloat {
        max(4, height * 0.12)
    }

    private var scaleFactor: CGFloat {
        height / HUDMetrics.canonicalQuotaRowHeight
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(palette.elevatedSurface)

            // Keep the quota readable at a glance without turning the HUD
            // into a pair of saturated dashboard bars. The accent is a thin
            // progress rail and a semantic outline; the percentage remains
            // the primary value in the content row below.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Capsule(style: .continuous)
                    .fill(accent.opacity(isUpdating ? 0.34 : 0.86))
                    .frame(width: max(6, (width - (height * 0.56)) * fillFraction), height: max(1.5, 2.2 * scaleFactor))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, height * 0.28)
                    .padding(.bottom, max(2, height * 0.12))
            }

            HStack(spacing: max(5, height * 0.18)) {
                Image(systemName: systemImage)
                    .font(.system(size: height * 0.42, weight: .semibold))
                    .frame(width: height * 0.58)
                Text(kind.label)
                    .font(.system(
                        size: height * HUDMetrics.canonicalQuotaPrimaryTextScale,
                        weight: .semibold,
                        design: .rounded
                    ))
                Text(percentText)
                    .font(.system(size: height * 0.48, weight: .bold, design: .rounded))
                Spacer(minLength: height * 0.12)
                HStack(spacing: height * 0.12) {
                    Text("剩餘")
                    Text(resetText)
                }
                .font(.system(size: height * 0.38, weight: .medium, design: .rounded))
                .foregroundStyle(palette.secondaryText)
            }
            .foregroundStyle(palette.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.52)
            .allowsTightening(true)
            .padding(.horizontal, height * 0.28)
            .frame(width: width, height: height, alignment: .leading)
        }
        .frame(width: width, height: height, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    accent.opacity(isUpdating ? 0.28 : 0.52),
                    lineWidth: max(0.6, 0.8 * scaleFactor)
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind.label)配額")
        .accessibilityValue(
            presentation.map {
                let reset = $0.resetDescription == "更新中" || $0.resetDescription == "已重置"
                    ? $0.resetDescription
                    : "\($0.resetDescription)後重置"
                return "剩餘 \($0.remainingPercent)%，\(reset)"
            } ?? (isUpdating ? "資料更新中" : "此帳號未提供此窗口")
        )
    }
}

/// Purchased Credits and Reset Credits are independent account information,
/// not quota windows. They share one compact row without suggesting either is
/// a fourth progress bar or allowing a destructive Reset action from the HUD.
struct HUDAccountInfoRow: View {
    let credits: CreditsBalance?
    let resetCreditCount: Int?
    let resetCreditCountdownText: String?
    let width: CGFloat
    let sectionHeight: CGFloat
    let rowHeight: CGFloat
    let scaleFactor: CGFloat
    @Environment(\.hudThemePalette) private var palette

    private var balanceText: String {
        credits?.displayBalance ?? "—"
    }

    private var showsCredits: Bool {
        credits?.isDisplayable == true
    }

    private var resetColor: Color {
        (resetCreditCount ?? 0) > 0 ? palette.verificationAction : palette.tertiaryText
    }

    var body: some View {
        VStack(spacing: 0) {
            divider
            HStack(spacing: max(6, 8 * scaleFactor)) {
                if showsCredits {
                    creditsContent
                }
                if showsCredits, resetCreditCount != nil {
                    Rectangle()
                        .fill(palette.divider)
                        .frame(width: max(0.6, 0.8 * scaleFactor), height: rowHeight * 0.62)
                }
                if let resetCreditCount {
                    resetCreditContent(count: resetCreditCount)
                }
            }
            .frame(width: width, height: rowHeight, alignment: .leading)
            divider
        }
        .frame(width: width, height: sectionHeight, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("帳號額度資訊")
        .accessibilityValue(accessibilityValue)
        .help("OpenAI GPT Credits 與 Reset Credit 資訊")
    }

    private var creditsContent: some View {
        HStack(spacing: max(5, 7 * scaleFactor)) {
            Image(systemName: "wallet.pass")
                .font(.system(size: max(14, 19 * scaleFactor), weight: .semibold))
                .foregroundStyle(palette.credits)
            Text("Credits")
                .font(.system(size: max(12, 15 * scaleFactor), weight: .semibold, design: .rounded))
                .foregroundStyle(palette.credits)
            Spacer(minLength: 3)
            Text(balanceText)
                .font(.system(size: max(15, 21 * scaleFactor), weight: .bold, design: .rounded))
                .foregroundStyle(palette.primaryText)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.62)
            Text("餘額")
                .font(.system(size: max(9, 11 * scaleFactor), weight: .medium, design: .rounded))
                .foregroundStyle(palette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resetCreditContent(count: Int) -> some View {
        HStack(spacing: max(5, 7 * scaleFactor)) {
            Image(systemName: "ticket.fill")
                .font(.system(size: max(14, 18 * scaleFactor), weight: .semibold))
                .foregroundStyle(resetColor)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text("重置券")
                        .font(.system(size: max(11, 14 * scaleFactor), weight: .semibold, design: .rounded))
                    Text("\(count) 張")
                        .font(.system(size: max(13, 18 * scaleFactor), weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(resetColor)
                if count > 0, let resetCreditCountdownText {
                    Text(resetCreditCountdownText)
                        .font(.system(size: max(8, 10 * scaleFactor), weight: .medium, design: .rounded))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if showsCredits {
            parts.append(credits?.unlimited == true ? "Credits 無限額度" : "Credits 餘額 \(balanceText)")
        }
        if let resetCreditCount {
            let countdown = resetCreditCountdownText.map { "，\($0)" } ?? ""
            parts.append("重置券 \(resetCreditCount) 張\(countdown)")
        }
        return parts.joined(separator: "；")
    }

    private var divider: some View {
        Rectangle()
            .fill(palette.divider)
            .frame(width: width, height: max(0.6, 0.8 * scaleFactor))
    }
}

struct HUDTokenActivitySummaryView: View, Equatable {
    let summaryMetrics: [TokenActivityMetric]?
    let feedback: TokenHeroUpdateFeedback?
    let width: CGFloat
    let height: CGFloat
    let scaleFactor: CGFloat
    let isStale: Bool
    let reduceMotion: Bool
    @Environment(\.hudThemePalette) private var palette

    private var metrics: [TokenActivityMetric] {
        summaryMetrics ?? TokenActivityPresentation.metrics(for: nil)
    }

    static func == (lhs: HUDTokenActivitySummaryView, rhs: HUDTokenActivitySummaryView) -> Bool {
        lhs.summaryMetrics == rhs.summaryMetrics
            && lhs.feedback == rhs.feedback
            && lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.scaleFactor == rhs.scaleFactor
            && lhs.isStale == rhs.isStale
            && lhs.reduceMotion == rhs.reduceMotion
    }

    var body: some View {
        HStack(spacing: max(6, 8 * scaleFactor)) {
            lifetimeHero(metrics.first ?? TokenActivityMetric(
                label: LocalTokenUsageLedgerPresentation.observedLabel,
                value: "—"
            ))
            Rectangle()
                .fill(palette.divider)
                .frame(width: max(0.6, 0.8 * scaleFactor))
                .padding(.vertical, max(5, 7 * scaleFactor))
            secondaryGrid(Array(metrics.dropFirst().prefix(4)))
        }
        .padding(.horizontal, max(7, 9 * scaleFactor))
        .frame(width: width, height: height)
        .background(palette.elevatedSurface, in: RoundedRectangle(cornerRadius: max(7, height * 0.18), style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: max(7, height * 0.18), style: .continuous)
                .stroke(isStale ? palette.warning.opacity(0.62) : palette.token.opacity(0.32), lineWidth: max(0.6, 0.8 * scaleFactor))
        }
        .opacity(isStale ? 0.88 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("本機 Token 使用與帳號歷史")
        .accessibilityValue(metrics.map { "\($0.label) \($0.value)" }.joined(separator: "；") + (isStale ? "；資料較舊" : ""))
        .help(isStale ? "本機觀測 Token；次要帳號歷史資料較舊" : "本機觀測 Token 與帳號歷史摘要")
    }

    private func lifetimeHero(_ metric: TokenActivityMetric) -> some View {
        VStack(alignment: .leading, spacing: max(2, 3 * scaleFactor)) {
            Label(metric.label, systemImage: "cylinder.split.1x2.fill")
                .font(.system(size: max(8, 11 * scaleFactor), weight: .semibold, design: .rounded))
                .foregroundStyle(palette.token)
            if let feedback {
                HUDTokenOdometerView(
                    feedback: feedback,
                    scaleFactor: scaleFactor,
                    reduceMotion: reduceMotion
                )
            } else {
                HUDTokenStaticOdometerView(
                    value: metric.value,
                    scaleFactor: scaleFactor
                )
            }
        }
        .frame(width: width * 0.56, alignment: .leading)
    }

    private func secondaryGrid(_ secondaryMetrics: [TokenActivityMetric]) -> some View {
        VStack(spacing: max(2, 3 * scaleFactor)) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: max(3, 5 * scaleFactor)) {
                    ForEach(0..<2, id: \.self) { column in
                        let index = row * 2 + column
                        if secondaryMetrics.indices.contains(index) {
                            secondaryMetricCell(secondaryMetrics[index])
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func secondaryMetricCell(_ metric: TokenActivityMetric) -> some View {
        VStack(alignment: .leading, spacing: max(0.5, 1 * scaleFactor)) {
            Text(metric.label)
                .font(.system(size: max(6, 8 * scaleFactor), weight: .medium, design: .rounded))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .allowsTightening(true)
            Text(metric.value)
                .font(.system(size: max(8, 11 * scaleFactor), weight: .bold, design: .rounded))
                .foregroundStyle(palette.primaryText)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.42)
                .allowsTightening(true)
                .scaleEffect(feedback?.changed(metric.label) == true ? 1.025 : 1)
                .animation(
                    .easeOut(duration: reduceMotion ? TokenActivityFeedbackAnimation.reduceMotionDuration : 0.24),
                    value: feedback?.generation ?? 0
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Idle Token values use the same fixed reel cells as a qualifying update, so
/// the mechanical odometer affordance is present before motion begins.
struct HUDTokenStaticOdometerView: View {
    let value: String
    let scaleFactor: CGFloat
    @Environment(\.hudThemePalette) private var palette

    private var characters: [Character] { Array(value) }
    private var fontSize: CGFloat { max(11, 17 * scaleFactor) }
    private var slotHeight: CGFloat { max(18, 24 * scaleFactor) }
    private var slotWidth: CGFloat { max(11, 15 * scaleFactor) }

    var body: some View {
        HStack(spacing: max(0.5, 1 * scaleFactor)) {
            ForEach(Array(characters.enumerated()), id: \.offset) { _, character in
                if character.isNumber {
                    Text(String(character))
                        .font(.system(size: fontSize, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                        .monospacedDigit()
                        .frame(width: slotWidth, height: slotHeight)
                        .background(palette.graphiteControl.opacity(0.82), in: RoundedRectangle(cornerRadius: max(2.5, 4 * scaleFactor), style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: max(2.5, 4 * scaleFactor), style: .continuous)
                                .stroke(palette.token.opacity(0.34), lineWidth: max(0.6, 0.8 * scaleFactor))
                        }
                } else {
                    Text(String(character))
                        .font(.system(size: fontSize, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.secondaryText)
                        .frame(width: max(3, 5 * scaleFactor), height: slotHeight)
                }
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityHidden(true)
    }
}

struct HUDTokenOdometerView: View {
    let feedback: TokenHeroUpdateFeedback
    let scaleFactor: CGFloat
    let reduceMotion: Bool

    private var slots: [TokenOdometerSlot] {
        TokenOdometerPresentation.slots(
            previous: feedback.previousTokens,
            current: feedback.tokens
        )
    }

    private var changedOffsetsFromRight: [Int] {
        slots
            .filter(\.isChangedDigit)
            .map(\.offset)
            .sorted(by: >)
    }

    private func reelPlan(for slot: TokenOdometerSlot) -> TokenOdometerReelPlan? {
        guard slot.isChangedDigit,
              let rank = changedOffsetsFromRight.firstIndex(of: slot.offset) else {
            return nil
        }
        return TokenOdometerReelPlan.make(
            previousCharacter: slot.previousCharacter,
            currentCharacter: slot.currentCharacter,
            startDelay: TokenOdometerReelPlan.startDelay(forChangedRankFromRight: rank)
        )
    }

    var body: some View {
        HStack(spacing: max(0.5, 1 * scaleFactor)) {
            ForEach(slots) { slot in
                HUDTokenOdometerDigit(
                    slot: slot,
                    generation: feedback.generation,
                    scaleFactor: scaleFactor,
                    reduceMotion: reduceMotion,
                    reelPlan: reelPlan(for: slot)
                )
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }
}

struct HUDTokenOdometerDigit: View {
    let slot: TokenOdometerSlot
    let generation: UInt64
    let scaleFactor: CGFloat
    let reduceMotion: Bool
    let reelPlan: TokenOdometerReelPlan?
    @Environment(\.hudThemePalette) private var palette

    @State private var animatedStep = 0

    private var fontSize: CGFloat {
        max(11, 17 * scaleFactor)
    }

    // A fixed viewport prevents the moving strip from bleeding into the
    // adjacent metric row while keeping its final baseline aligned with the
    // static digits in this compact summary.
    private var slotHeight: CGFloat {
        max(18, 24 * scaleFactor)
    }

    private var slotWidth: CGFloat { max(11, 15 * scaleFactor) }
    private var separatorWidth: CGFloat { max(3, 5 * scaleFactor) }

    private var characterText: some View {
        Text(String(slot.currentCharacter == " " ? Character("\u{00A0}") : slot.currentCharacter))
            .font(.system(size: fontSize, weight: .bold, design: .rounded))
            .foregroundStyle(palette.primaryText)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.42)
            .allowsTightening(true)
    }

    private func reelDigitText(_ digit: Int) -> some View {
        Text(String(digit))
            .font(.system(size: fontSize, weight: .bold, design: .rounded))
            .foregroundStyle(palette.primaryText)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.42)
            .allowsTightening(true)
            .frame(height: slotHeight, alignment: .center)
    }

    private var staticCharacterText: some View {
        characterText
            .frame(height: slot.currentCharacter.isNumber ? slotHeight : nil, alignment: .center)
    }

    private func startReel() {
        guard let reelPlan else { return }

        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            animatedStep = 0
        }

        // Let the initial frame render at the old digit before moving the
        // clipped strip. The bounded delay gives rightmost slots a subtle,
        // deterministic mechanical cascade.
        DispatchQueue.main.async {
            withAnimation(
                .easeOut(duration: TokenActivityFeedbackAnimation.normalDuration)
                    .delay(reelPlan.startDelay)
            ) {
                animatedStep = reelPlan.finalLandingIndex
            }
        }
    }

    private var reelViewport: some View {
        VStack(spacing: 0) {
            ForEach(Array((reelPlan?.forwardSequence ?? []).enumerated()), id: \.offset) { _, digit in
                reelDigitText(digit)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .offset(y: -CGFloat(animatedStep) * slotHeight)
        .frame(height: slotHeight, alignment: .top)
        .clipped()
        .onAppear(perform: startReel)
    }

    @ViewBuilder
    private var motionContent: some View {
        if reelPlan != nil, !reduceMotion {
            reelViewport
                .id("\(generation)-\(slot.offset)")
        } else if slot.isChangedDigit {
            staticCharacterText
                .contentTransition(.opacity)
                .animation(
                    .easeOut(duration: TokenActivityFeedbackAnimation.duration(reduceMotion: reduceMotion)),
                    value: generation
                )
        } else {
            staticCharacterText
        }
    }

    @ViewBuilder
    var body: some View {
        if slot.currentCharacter.isNumber {
            motionContent
                .frame(width: slotWidth, height: slotHeight)
                .background(palette.graphiteControl.opacity(0.82), in: RoundedRectangle(cornerRadius: max(2.5, 4 * scaleFactor), style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: max(2.5, 4 * scaleFactor), style: .continuous)
                        .stroke(palette.token.opacity(reelPlan == nil ? 0.34 : 0.72), lineWidth: max(0.6, 0.8 * scaleFactor))
                }
        } else {
            staticCharacterText
                .foregroundStyle(palette.secondaryText)
                .frame(width: separatorWidth, height: slotHeight)
        }
    }
}

struct HUDActionCard: View {
    enum FillStyle {
        case neutral
        case filled(background: Color, foreground: Color)
    }

    let title: String
    let systemImage: String
    let iconSize: CGFloat
    let action: () -> Void
    let isDisabled: Bool
    let helpText: String
    let accessibilityLabel: String
    let iconColor: Color?
    let fillStyle: FillStyle
    let width: CGFloat
    let height: CGFloat
    @Binding var isHovered: Bool
    @Environment(\.hudThemePalette) private var palette

    private var cornerRadius: CGFloat {
        max(5, height * 0.14)
    }

    private var scaleFactor: CGFloat {
        height / HUDMetrics.canonicalActionHeight
    }

    init(
        title: String,
        systemImage: String,
        iconSize: CGFloat,
        action: @escaping () -> Void,
        isDisabled: Bool,
        helpText: String,
        accessibilityLabel: String,
        iconColor: Color? = nil,
        fillStyle: FillStyle = .neutral,
        width: CGFloat,
        height: CGFloat,
        isHovered: Binding<Bool>
    ) {
        self.title = title
        self.systemImage = systemImage
        self.iconSize = iconSize
        self.action = action
        self.isDisabled = isDisabled
        self.helpText = helpText
        self.accessibilityLabel = accessibilityLabel
        self.iconColor = iconColor
        self.fillStyle = fillStyle
        self.width = width
        self.height = height
        self._isHovered = isHovered
    }

    private var imageForegroundColor: Color {
        switch fillStyle {
        case .neutral:
            return (iconColor ?? palette.primaryText).opacity(isHovered ? 0.96 : 0.78)
        case .filled(_, let foreground):
            return foreground.opacity(isHovered ? 0.98 : 0.96)
        }
    }

    private var textForegroundColor: Color {
        switch fillStyle {
        case .neutral:
            return palette.primaryText
        case .filled(_, let foreground):
            return foreground.opacity(isHovered ? 0.98 : 0.96)
        }
    }

    private var backgroundColor: Color {
        switch fillStyle {
        case .neutral:
            return isHovered ? palette.controlSurface : palette.elevatedSurface
        case .filled(let background, _):
            return background.opacity(isHovered ? 0.28 : 0.16)
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Button(action: action) {
            HStack(spacing: 3 * scaleFactor) {
                Image(systemName: systemImage)
                    .font(.system(size: iconSize * scaleFactor, weight: .semibold))
                    .foregroundStyle(imageForegroundColor)
                Text(title)
                    // Keep action labels aligned at every HUD scale.
                    .font(.system(size: 14 * scaleFactor, weight: .semibold, design: .rounded))
                    .foregroundStyle(textForegroundColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .allowsTightening(true)
            }
            // Keep the semantic label and the visible card on the same
            // hit-test rectangle. A max-sized label can otherwise retain an
            // intrinsic Button hit region near the card's rounded edges.
            .frame(width: width, height: height)
            // The card remains visually rounded, but its full rectangular
            // bounds are the intentional action hit target. This keeps
            // corner/edge clicks responsive without changing mouse-up action
            // semantics.
            .contentShape(Rectangle())
        }
        .buttonStyle(HUDImmediateButtonStyle(cornerRadius: cornerRadius))
        .frame(width: width, height: height)
        .background(backgroundColor, in: shape)
        .overlay {
            switch fillStyle {
            case .neutral:
                shape.stroke(palette.border, lineWidth: 0.8 * scaleFactor)
            case .filled(let background, _):
                shape.stroke(background.opacity(isHovered ? 0.78 : 0.5), lineWidth: 0.8 * scaleFactor)
            }
        }
        .contentShape(Rectangle())
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
        .help(helpText)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(helpText)
    }
}

/// Keeps the existing mouse-up action semantics while making acceptance
/// visible on the first mouse-down. This is intentionally a presentation-only
/// style: it does not invoke the action early or bypass any in-flight gate.
struct HUDImmediateButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0))
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct HUDUpdateBadge: View {
    let state: HUDUpdateBadgeState
    let height: CGFloat
    let action: () -> Void
    @Environment(\.hudThemePalette) private var palette

    private var isActionable: Bool { state.isActionable }

    private var title: String {
        switch state {
        case .version(let version): return "v\(version)"
        case .available: return "有新版本"
        case .checking: return "檢查中…"
        case .error(let version): return "v\(version)"
        }
    }

    private var icon: String {
        switch state {
        case .version: return "number.circle"
        case .available: return "circle.fill"
        case .checking: return "arrow.triangle.2.circlepath"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var iconColor: Color {
        switch state {
        case .available: return palette.update
        case .error: return palette.error
        default: return palette.secondaryText
        }
    }

    private var accessibilityValue: String {
        switch state {
        case .version(let version): return "目前版本 \(version)"
        case .available(let version): return "有新版本 \(version)，點擊開啟更新詳情"
        case .checking: return "正在檢查更新"
        case .error(let version): return "目前版本 \(version)，更新檢查失敗，點擊重新檢查"
        }
    }

    private func badgeContent(spacing: CGFloat, iconSize: CGFloat, titleSize: CGFloat) -> AnyView {
        AnyView(HStack(spacing: spacing) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(iconColor)
            Text(title)
                .font(.system(size: titleSize, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .allowsTightening(true)
        })
    }

    private func badgeButtonLabel(
        spacing: CGFloat,
        iconSize: CGFloat,
        titleSize: CGFloat,
        minimumWidth: CGFloat,
        horizontalPadding: CGFloat
    ) -> AnyView {
        let content = badgeContent(spacing: spacing, iconSize: iconSize, titleSize: titleSize)
        return AnyView(
            content
                .frame(minWidth: minimumWidth, minHeight: self.height, maxHeight: self.height)
                .padding(.horizontal, horizontalPadding)
        )
    }

    var body: some View {
        let spacing = max(CGFloat(3), height * 0.12)
        let iconSize = max(CGFloat(9), height * 0.42)
        let titleSize = max(CGFloat(9), height * HUDMetrics.canonicalQuotaPrimaryTextScale)
        let minimumWidth = max(CGFloat(76), height * 4.4)
        let horizontalPadding = max(CGFloat(6), height * 0.2)
        Button(action: action) {
            badgeButtonLabel(
                spacing: spacing,
                iconSize: iconSize,
                titleSize: titleSize,
                minimumWidth: minimumWidth,
                horizontalPadding: horizontalPadding
            )
        }
        .buttonStyle(.plain)
        .disabled(!isActionable)
        .background(palette.controlSurface, in: Capsule())
        .overlay { Capsule().stroke(palette.border, lineWidth: 0.6) }
        .help(isActionable ? (state.isAvailable ? "開啟更新詳情" : "重新檢查更新") : accessibilityValue)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }
}

/// Compact account-plan badge shown beside the in-memory Email identity. The
/// badge is informational only; plan data continues to come from the existing
/// account-health/snapshot publication and is never persisted by the HUD.
struct HUDPlanBadge: View {
    let plan: String
    let height: CGFloat
    @Environment(\.hudThemePalette) private var palette

    private var normalizedPlan: String {
        plan.lowercased().replacingOccurrences(of: "_", with: " ")
    }

    private var tint: Color {
        if normalizedPlan.contains("pro") { return palette.verificationAction }
        if normalizedPlan.contains("plus") { return palette.sevenDay }
        if normalizedPlan.contains("business") { return palette.fiveHour }
        if normalizedPlan.contains("team") { return palette.token }
        if normalizedPlan.contains("enterprise") { return palette.token }
        if normalizedPlan.contains("free") { return palette.secondaryText }
        return palette.secondaryText
    }

    var body: some View {
        Text(plan)
            .font(.system(size: max(9, height * HUDMetrics.canonicalQuotaPrimaryTextScale), weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .allowsTightening(true)
            .padding(.horizontal, max(7, height * 0.28))
            .frame(minWidth: max(46, height * 2.15), minHeight: height, maxHeight: height)
            .background(tint.opacity(0.13), in: Capsule())
            .overlay { Capsule().stroke(tint.opacity(0.35), lineWidth: max(0.6, height * 0.025)) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("帳號方案")
            .accessibilityValue(plan)
    }
}

struct HUDPresentationBoundary<Content: View>: View, Equatable {
    let presentation: HUDPresentation
    /// Theme is a stable render input, not an identity reset. Including it in
    /// equality guarantees palette repaint while preserving child state such
    /// as an in-flight Token Reel generation.
    let theme: HUDTheme
    private let content: (HUDPresentation) -> Content

    init(
        presentation: HUDPresentation,
        theme: HUDTheme = .neonPurple,
        @ViewBuilder content: @escaping (HUDPresentation) -> Content
    ) {
        self.presentation = presentation
        self.theme = theme
        self.content = content
    }

    static func == (lhs: HUDPresentationBoundary<Content>, rhs: HUDPresentationBoundary<Content>) -> Bool {
        lhs.presentation == rhs.presentation && lhs.theme == rhs.theme
    }

    var body: some View { content(presentation) }
}

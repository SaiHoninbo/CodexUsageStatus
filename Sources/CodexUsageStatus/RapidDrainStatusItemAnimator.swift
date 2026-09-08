import AppKit
import QuartzCore

@MainActor
final class RapidDrainStatusItemAnimator {
    private weak var statusItem: NSStatusItem?
    private var sequenceTask: Task<Void, Never>?
    private var canonicalPresentation = StatusItemPresentation.placeholder
    private var activeEventID: UUID?

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
    }

    func updateCanonical(_ presentation: StatusItemPresentation) {
        canonicalPresentation = presentation
        guard sequenceTask == nil else { return }
        renderCanonical()
    }

    func animate(event: ObservedRapidDrainEvent, reduceMotion: Bool) {
        sequenceTask?.cancel()
        cleanupTransientLayers()
        activeEventID = event.id
        let plan = RapidDrainAnimationPlan.make(
            severity: event.severity,
            reduceMotion: reduceMotion,
            drop: event.observedDropPercent
        )
        sequenceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.run(event: event, plan: plan)
        }
    }

    func stop() {
        sequenceTask?.cancel()
        sequenceTask = nil
        activeEventID = nil
        cleanupTransientLayers()
        renderCanonical()
    }

    private func run(event: ObservedRapidDrainEvent, plan: RapidDrainAnimationPlan) async {
        defer {
            if activeEventID == event.id {
                sequenceTask = nil
                activeEventID = nil
                cleanupTransientLayers()
                renderCanonical()
            }
        }

        let content = RapidDrainStatusItemContent(event: event)
        let alertTitle = content.title
        let alertTooltip = content.tooltip

        guard !Task.isCancelled else { return }
        if plan.showsScan {
            renderTemporary(title: canonicalPresentation.stackedTitle, tooltip: alertTooltip, width: 40)
            addUnderline()
            await pause(seconds: 0.16)
            guard !Task.isCancelled else { return }
            addScanBeam()
            await pause(seconds: 0.24)
            guard !Task.isCancelled else { return }
            addShake()
            await pause(seconds: 0.30)
            guard !Task.isCancelled else { return }
        } else {
            renderTemporary(title: alertTitle, tooltip: alertTooltip, width: plan.expandedWidth)
            addUnderline()
        }

        if plan.showsScan {
            renderTemporary(title: alertTitle, tooltip: alertTooltip, width: plan.expandedWidth)
        }
        if plan.showsShake {
            addScalePulse(count: plan.pulseCount, scale: plan.scale)
        }
        await pause(seconds: max(0, plan.holdDuration))
    }

    private func pause(seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    private func renderCanonical() {
        renderTemporary(
            title: canonicalPresentation.stackedTitle,
            tooltip: canonicalPresentation.tooltip,
            width: 40,
            color: canonicalPresentation.color
        )
    }

    private func renderTemporary(
        title: String,
        tooltip: String,
        width: CGFloat,
        color: StatusItemColor = .red
    ) {
        guard let statusItem, let button = statusItem.button else { return }
        statusItem.length = width
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineSpacing = -3
        paragraphStyle.minimumLineHeight = 7
        paragraphStyle.maximumLineHeight = 9
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: nsColor(for: color),
                .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium),
                .paragraphStyle: paragraphStyle,
                .baselineOffset: -2
            ]
        )
        button.toolTip = tooltip
        button.wantsLayer = true
        button.layer?.masksToBounds = true
    }

    private func addUnderline() {
        guard let layer = statusItem?.button?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.borderColor = NSColor.systemRed.cgColor
        layer.borderWidth = 2
        CATransaction.commit()
    }

    private func addScanBeam() {
        guard let layer = statusItem?.button?.layer else { return }
        let beam = CAGradientLayer()
        beam.name = "rapid-drain-scan-beam"
        beam.colors = [
            NSColor.clear.cgColor,
            NSColor.systemRed.withAlphaComponent(0.75).cgColor,
            NSColor.clear.cgColor
        ]
        beam.startPoint = CGPoint(x: 0, y: 0.5)
        beam.endPoint = CGPoint(x: 1, y: 0.5)
        beam.frame = CGRect(x: -layer.bounds.width, y: 0, width: layer.bounds.width, height: layer.bounds.height)
        layer.addSublayer(beam)
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = -layer.bounds.width
        animation.toValue = layer.bounds.width * 2
        animation.duration = 0.24
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        beam.add(animation, forKey: "rapid-drain-scan")
    }

    private func addShake() {
        guard let layer = statusItem?.button?.layer else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, -2, 2, -1, 1, 0]
        animation.duration = 0.30
        animation.calculationMode = .linear
        layer.add(animation, forKey: "rapid-drain-shake")
    }

    private func addScalePulse(count: Int, scale: CGFloat) {
        guard let layer = statusItem?.button?.layer else { return }
        let boundedCount = max(1, min(3, count))
        var values: [NSNumber] = [1]
        for _ in 0..<boundedCount {
            values.append(NSNumber(value: Double(scale)))
            values.append(1)
        }
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = values
        animation.duration = Double(boundedCount) * 0.32
        animation.calculationMode = .linear
        layer.add(animation, forKey: "rapid-drain-pulse")
    }

    private func cleanupTransientLayers() {
        guard let layer = statusItem?.button?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.borderWidth = 0
        layer.borderColor = nil
        layer.removeAllAnimations()
        layer.sublayers?.removeAll { $0.name == "rapid-drain-scan-beam" }
        CATransaction.commit()
    }

    private func nsColor(for color: StatusItemColor) -> NSColor {
        switch color {
        case .secondary: return .secondaryLabelColor
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .green: return .systemGreen
        }
    }
}

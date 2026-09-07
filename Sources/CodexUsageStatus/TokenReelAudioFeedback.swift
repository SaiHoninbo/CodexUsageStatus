import AppKit
import Foundation

/// The Token Reel has its own sound preference and event policy.  Keeping it
/// separate from notification sounds means a user can enjoy the small
/// accounting cue without enabling quota/Turn notifications.
enum TokenReelSoundPreference {
    static let key = "ui.tokenReel.soundEnabled"
    static let defaultValue = true

    static func load(from defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }
}

enum TokenReelAudioSound: Equatable {
    case pop
    case morse
    case tink
    case glass
    case beep

    var systemSoundName: String? {
        switch self {
        case .pop: return "Pop"
        case .morse: return "Morse"
        case .tink: return "Tink"
        case .glass: return "Glass"
        case .beep: return nil
        }
    }
}

struct TokenReelAudioEvent: Equatable {
    enum Role: Equatable {
        case rollingTick
        case landing
    }

    let offset: Double
    let role: Role
    let volume: Double
}

/// A value-semantic audio schedule shared by production playback and tests.
/// The visual Reel starts at time zero; rolling ticks are deliberately quiet,
/// while the landing chime is the single clear completion cue.
struct TokenReelAudioPlan: Equatable {
    /// Keep audio landing synchronized with the authoritative visual Reel.
    /// These aliases intentionally do not duplicate timing literals.
    static let normalDuration = TokenActivityFeedbackAnimation.normalDuration
    static let reduceMotionDuration = TokenActivityFeedbackAnimation.reduceMotionDuration
    static let rollingTickOffsets: [Double] = [0.03, 0.10, 0.19, 0.31, 0.46]
    static let rollingTickVolume = 0.17
    static let landingVolume = 0.48

    let events: [TokenReelAudioEvent]
    let duration: Double

    static func make(reduceMotion: Bool) -> TokenReelAudioPlan {
        if reduceMotion {
            return TokenReelAudioPlan(
                events: [TokenReelAudioEvent(
                    offset: reduceMotionDuration,
                    role: .landing,
                    volume: landingVolume
                )],
                duration: reduceMotionDuration
            )
        }

        let ticks = rollingTickOffsets.map {
            TokenReelAudioEvent(offset: $0, role: .rollingTick, volume: rollingTickVolume)
        }
        return TokenReelAudioPlan(
            events: ticks + [TokenReelAudioEvent(
                offset: normalDuration,
                role: .landing,
                volume: landingVolume
            )],
            duration: normalDuration
        )
    }

    var isBounded: Bool {
        guard events.allSatisfy({ $0.offset >= 0 && $0.offset <= duration }) else { return false }
        return events == events.sorted { $0.offset < $1.offset }
    }
}

enum TokenReelAudioSelectionPolicy {
    static func rollingTick(popAvailable: Bool, morseAvailable: Bool) -> TokenReelAudioSound? {
        if popAvailable { return .pop }
        if morseAvailable { return .morse }
        return nil
    }

    static func landing(tinkAvailable: Bool, glassAvailable: Bool) -> TokenReelAudioSound {
        if tinkAvailable { return .tink }
        if glassAvailable { return .glass }
        return .beep
    }
}

/// Production Token Reel playback.  A new qualifying generation cancels all
/// pending events and stops any active system sound before starting its own
/// bounded sequence, so two generations can never produce overlapping reels.
@MainActor
final class TokenReelAudioFeedbackPlayer {
    typealias SoundLoader = (String) -> NSSound?

    private let soundLoader: SoundLoader
    private let beep: () -> Void
    private var scheduledTasks: [Task<Void, Never>] = []
    private var activeSounds: [NSSound] = []
    private var sequenceID = UUID()

    init(
        soundLoader: @escaping SoundLoader = { NSSound(named: NSSound.Name($0)) },
        beep: @escaping () -> Void = { NSSound.beep() }
    ) {
        self.soundLoader = soundLoader
        self.beep = beep
    }

    func play(reduceMotion: Bool) {
        schedule(TokenReelAudioPlan.make(reduceMotion: reduceMotion))
    }

    /// Settings preview intentionally uses this exact production schedule and
    /// has no model, history, account, notification, or Reset Credit side
    /// effects.
    func preview(reduceMotion: Bool) {
        play(reduceMotion: reduceMotion)
    }

    func cancel() {
        scheduledTasks.forEach { $0.cancel() }
        scheduledTasks.removeAll()
        activeSounds.forEach { $0.stop() }
        activeSounds.removeAll()
        sequenceID = UUID()
    }

    private func schedule(_ plan: TokenReelAudioPlan) {
        cancel()
        let id = UUID()
        sequenceID = id
        scheduledTasks = plan.events.map { event in
            let nanoseconds = UInt64(max(0, event.offset) * 1_000_000_000)
            return Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.play(event: event, sequenceID: id)
            }
        }
    }

    private func play(event: TokenReelAudioEvent, sequenceID: UUID) {
        guard self.sequenceID == sequenceID else { return }
        switch event.role {
        case .rollingTick:
            let popAvailable = soundLoader("Pop") != nil
            let morseAvailable = soundLoader("Morse") != nil
            guard let selected = TokenReelAudioSelectionPolicy.rollingTick(
                popAvailable: popAvailable,
                morseAvailable: morseAvailable
            ) else { return }
            if !play(named: selected.systemSoundName, volume: event.volume), selected == .pop {
                _ = play(named: "Morse", volume: event.volume)
            }
        case .landing:
            let tinkAvailable = soundLoader("Tink") != nil
            let glassAvailable = soundLoader("Glass") != nil
            let selected = TokenReelAudioSelectionPolicy.landing(
                tinkAvailable: tinkAvailable,
                glassAvailable: glassAvailable
            )
            if !play(named: selected.systemSoundName, volume: event.volume) {
                if selected == .tink, !play(named: "Glass", volume: event.volume) {
                    _ = play(named: nil, volume: event.volume)
                } else if selected == .glass {
                    _ = play(named: nil, volume: event.volume)
                }
            }
        }
    }

    @discardableResult
    private func play(named name: String?, volume: Double) -> Bool {
        guard let name else {
            beep()
            return true
        }
        guard let sound = soundLoader(name) else { return false }
        sound.volume = Float(volume)
        guard sound.play() else { return false }
        activeSounds.append(sound)
        return true
    }
}

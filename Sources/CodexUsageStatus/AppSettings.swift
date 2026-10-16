import Foundation

/// Versioned, bundle-stable preferences shared by the menu-bar app, popover,
/// HUD, and updater.  UserDefaults is deliberately used instead of a file
/// beside the app bundle so an in-place Release replacement keeps the same
/// settings domain across versions.
enum AppSettingsSchema {
    static let versionKey = "settings.schemaVersion"
    static let currentVersion = 1
    static let stableBundleIdentifier = "com.openai.codex-usage-status"

    static func migrate(defaults: UserDefaults = .standard) {
        let storedVersion = defaults.integer(forKey: versionKey)
        guard storedVersion < currentVersion else { return }

        // The shipped "播放提示音" preference was the original app-wide
        // sound gate. It must win over any newer alias so an existing OFF
        // choice cannot become ON after an upgrade. Preserve all old keys
        // rather than deleting them so an older build can still be launched
        // during an update rollback.
        if defaults.object(forKey: GlobalSoundPreference.key) == nil {
            for legacyKey in GlobalSoundPreference.legacyKeys {
                if let value = defaults.object(forKey: legacyKey) as? Bool {
                    defaults.set(value, forKey: GlobalSoundPreference.key)
                    break
                }
            }
        }

        defaults.set(currentVersion, forKey: versionKey)
    }
}

/// A master audio gate. Feature-specific preferences remain independent so a
/// user can keep notifications quiet while retaining the Token Reel cue; this
/// switch is the final authority for every sound-producing path.
enum GlobalSoundPreference {
    /// The shipped "播放提示音" key remains the only persisted master. This
    /// avoids creating a second user-facing sound preference during upgrade.
    static let key = "usage.notifications.soundEnabled"
    static let defaultValue = false
    static let legacyNotificationSoundKey = key
    static let legacyKeys = ["ui.sound.enabled", "sound.enabled", "usage.sound.enabled"]

    static func load(from defaults: UserDefaults = .standard) -> Bool {
        AppSettingsSchema.migrate(defaults: defaults)
        return defaults.object(forKey: key) as? Bool ?? defaultValue
    }

    static func persist(_ enabled: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
        defaults.set(AppSettingsSchema.currentVersion, forKey: AppSettingsSchema.versionKey)
    }

    static func effective(masterEnabled: Bool, featureEnabled: Bool) -> Bool {
        masterEnabled && featureEnabled
    }
}

enum CodexLocalUsageRootMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case defaultHome
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "自動偵測"
        case .defaultHome: "預設 ~/.codex"
        case .custom: "自訂位置…"
        }
    }
}

/// The observation root is runtime data. Automatic mode preserves the
/// existing CODEX_HOME behavior, while the other modes let the user choose a
/// stable local or mounted home without changing the observer implementation.
struct CodexLocalUsageRootPreference: Equatable, Sendable {
    static let modeKey = "usage.localObservationRoot.mode"
    static let customPathKey = "usage.localObservationRoot.customPath"

    var mode: CodexLocalUsageRootMode
    var customPath: String?

    static func load(from defaults: UserDefaults = .standard) -> CodexLocalUsageRootPreference {
        let storedMode = defaults.string(forKey: modeKey).flatMap(CodexLocalUsageRootMode.init(rawValue:))
        let storedPath = defaults.string(forKey: customPathKey)
        let mode = storedMode == .custom && (storedPath?.isEmpty ?? true) ? .automatic : (storedMode ?? .automatic)
        return CodexLocalUsageRootPreference(mode: mode, customPath: storedPath)
    }

    func resolveHomeURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        switch mode {
        case .automatic:
            if let configured = environment["CODEX_HOME"], !configured.isEmpty {
                return URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
            }
            return Self.defaultHomeURL(fileManager: fileManager)
        case .defaultHome:
            return Self.defaultHomeURL(fileManager: fileManager)
        case .custom:
            guard let customPath, !customPath.isEmpty else { return Self.defaultHomeURL(fileManager: fileManager) }
            return URL(fileURLWithPath: customPath, isDirectory: true).standardizedFileURL
        }
    }

    func persist(to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: Self.modeKey)
        if let customPath, !customPath.isEmpty {
            defaults.set(customPath, forKey: Self.customPathKey)
        } else {
            defaults.removeObject(forKey: Self.customPathKey)
        }
        defaults.set(AppSettingsSchema.currentVersion, forKey: AppSettingsSchema.versionKey)
    }

    private static func defaultHomeURL(fileManager: FileManager) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL
    }
}

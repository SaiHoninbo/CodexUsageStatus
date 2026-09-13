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

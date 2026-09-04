import Foundation

/// Seven proportional HUD sizes centered on the current C layout: four
/// compact levels, standard, and two larger levels. The standard level is
/// the 416x306 reference used by the current HUD.
enum HUDScaleLevel: Int, CaseIterable, Codable, Equatable {
    // New compact levels use additive raw identities so existing persisted
    // raw values 1...5 retain their historical physical meaning.
    case smaller4 = 6
    case smaller3 = 7
    case smaller2 = 1
    case smaller1 = 2
    case standard = 3
    case larger1 = 4
    case larger2 = 5

    static let userDefaultsKey = "ui.floatingHUD.scaleLevel"
    static let schemaVersionKey = "ui.floatingHUD.scaleLevel.schemaVersion"
    static let currentSchemaVersion = 6

    var scaleFactor: CGFloat {
        switch self {
        case .smaller4: return 0.64
        case .smaller3: return 0.72
        case .smaller2: return 0.80
        case .smaller1: return 0.90
        case .standard: return 1.00
        case .larger1: return 1.15
        case .larger2: return 1.30
        }
    }

    var displayName: String {
        switch self {
        case .smaller4: return "小 4 級"
        case .smaller3: return "小 3 級"
        case .smaller2: return "小 2 級"
        case .smaller1: return "小 1 級"
        case .standard: return "標準"
        case .larger1: return "大 1 級"
        case .larger2: return "大 2 級"
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> HUDScaleLevel {
        guard let rawValue = defaults.object(forKey: userDefaultsKey) as? Int,
              let storedLevel = HUDScaleLevel(rawValue: rawValue) else {
            return .standard
        }

        let schemaVersion = defaults.integer(forKey: schemaVersionKey)
        if schemaVersion >= currentSchemaVersion {
            return storedLevel
        }

        if schemaVersion == 4 {
            // Schema 4 briefly treated the former 520x260 draft as the
            // canonical 100% size. Its level 1 was the historical 416x208
            // UI; map that logical level into the current 416x306 scale
            // space rather than carrying forward the retired geometry.
            let migrated: HUDScaleLevel
            switch rawValue {
            case 1: migrated = .standard
            case 2: migrated = .larger1
            case 3, 4, 5: migrated = .larger2
            default: migrated = .standard
            }
            migrated.persist(to: defaults)
            return migrated
        }

        if schemaVersion == 3 {
            // Schema 3 used 520x260 as 100%. The user's currently visible
            // smallest HUD was schema-3 level 1 (416x208); map that logical
            // level into the current 416x306 scale space.
            let migrated: HUDScaleLevel
            switch rawValue {
            case 1: migrated = .standard
            case 2: migrated = .larger1
            case 3, 4, 5: migrated = .larger2
            default: migrated = .standard
            }
            migrated.persist(to: defaults)
            return migrated
        }

        if schemaVersion == 2 {
            // A short-lived build temporarily used level 1 as standard and
            // shifted every larger level upward. Map that representation to
            // the final centered seven-level contract by preserving size.
            let migrated: HUDScaleLevel
            switch rawValue {
            case 1: migrated = .standard
            case 2: migrated = .larger1
            case 3: migrated = .larger2
            default: migrated = .standard
            }
            migrated.persist(to: defaults)
            return migrated
        }

        // v1 already used the desired raw ordering. With no schema marker,
        // preserve the stored logical level and mark it as migrated.
        defaults.set(currentSchemaVersion, forKey: schemaVersionKey)
        return storedLevel
    }

    func persist(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.userDefaultsKey)
        defaults.set(Self.currentSchemaVersion, forKey: Self.schemaVersionKey)
    }
}

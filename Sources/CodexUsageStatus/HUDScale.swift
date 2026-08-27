import Foundation

/// Five proportional HUD sizes centered on the current smallest C layout:
/// two below, standard, and two above. The standard level is the 416x208
/// reference shown by the current smallest UI.
enum HUDScaleLevel: Int, CaseIterable, Codable, Equatable {
    case smaller2 = 1
    case smaller1 = 2
    case standard = 3
    case larger1 = 4
    case larger2 = 5

    static let userDefaultsKey = "ui.floatingHUD.scaleLevel"
    static let schemaVersionKey = "ui.floatingHUD.scaleLevel.schemaVersion"
    static let currentSchemaVersion = 5

    var scaleFactor: CGFloat {
        switch self {
        case .smaller2: return 0.80
        case .smaller1: return 0.90
        case .standard: return 1.00
        case .larger1: return 1.15
        case .larger2: return 1.30
        }
    }

    var displayName: String {
        switch self {
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
            // canonical 100% size. Its level 1 was the 416x208 UI now used
            // as the standard reference, so preserve that visible size.
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
            // smallest HUD was schema-3 level 1 (416x208), so preserve that
            // physical size as the new standard and map larger legacy levels
            // to the nearest available level in the new 416x208 scale space.
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
            // the final centered five-level contract by preserving size.
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

import CryptoKit
import Foundation
import Combine

struct AccountProfile: Codable, Equatable, Identifiable {
    let id: UUID
    let fingerprint: String
    var displayName: String
    var accountType: String?
    var authMode: String?
    var lastSeen: Date
    /// True when the user explicitly supplied a name.
    var isDisplayNameCustom: Bool
    /// True when App Server did not provide a stable account identifier (for
    /// example API-key or Bedrock auth). Such data must not be presented as a
    /// confidently identified account.
    var isUnidentified: Bool
    var isManaged: Bool
    var workerEnabled: Bool
    var syncIntervalSeconds: Int

    init(
        id: UUID,
        fingerprint: String,
        displayName: String,
        accountType: String?,
        authMode: String? = nil,
        lastSeen: Date,
        isDisplayNameCustom: Bool = false,
        isUnidentified: Bool = false,
        isManaged: Bool = false,
        workerEnabled: Bool = true,
        syncIntervalSeconds: Int = 300
    ) {
        self.id = id
        self.fingerprint = fingerprint
        self.displayName = displayName
        self.accountType = accountType
        self.authMode = authMode
        self.lastSeen = lastSeen
        self.isDisplayNameCustom = isDisplayNameCustom
        self.isUnidentified = isUnidentified
        self.isManaged = isManaged
        self.workerEnabled = workerEnabled
        self.syncIntervalSeconds = max(60, min(3600, syncIntervalSeconds))
    }

    enum CodingKeys: String, CodingKey {
        case id, fingerprint, displayName, accountType, authMode, lastSeen, isDisplayNameCustom, isUnidentified, isManaged, workerEnabled, syncIntervalSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        fingerprint = try container.decode(String.self, forKey: .fingerprint)
        displayName = try container.decode(String.self, forKey: .displayName)
        accountType = try container.decodeIfPresent(String.self, forKey: .accountType)
        authMode = try container.decodeIfPresent(String.self, forKey: .authMode)
        lastSeen = try container.decode(Date.self, forKey: .lastSeen)
        let storedCustomName = try container.decodeIfPresent(Bool.self, forKey: .isDisplayNameCustom)
        isDisplayNameCustom = storedCustomName ?? !AccountProfile.isGenericDisplayName(displayName)
        isUnidentified = try container.decodeIfPresent(Bool.self, forKey: .isUnidentified) ?? fingerprint.hasPrefix("unknown-")
        isManaged = try container.decodeIfPresent(Bool.self, forKey: .isManaged) ?? false
        workerEnabled = try container.decodeIfPresent(Bool.self, forKey: .workerEnabled) ?? true
        syncIntervalSeconds = max(60, min(3600, try container.decodeIfPresent(Int.self, forKey: .syncIntervalSeconds) ?? 300))
    }

    static func isGenericDisplayName(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == "ChatGPT 帳號" || normalized == "未識別帳號" { return true }
        for prefix in ["ChatGPT 帳號 ", "未識別帳號 "] {
            if normalized.hasPrefix(prefix), Int(normalized.dropFirst(prefix.count)) != nil { return true }
        }
        return false
    }
}

private struct AccountProfileIndex: Codable {
    let schemaVersion: Int
    let profiles: [AccountProfile]
}

struct AccountProfileSelection: Equatable {
    let profile: AccountProfile
    let identity: AccountIdentity
    let switched: Bool
}

enum AccountScope: String, CaseIterable, Identifiable {
    case current
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .current: return "目前帳號"
        case .all: return "全部帳號"
        }
    }
}

struct ProfileQuotaSummary: Identifiable {
    let profile: AccountProfile
    let latestSample: HistorySample?

    var id: UUID { profile.id }
    var primaryRemainingPercent: Int? {
        latestSample?.primaryUsedPercent.map { max(0, min(100, 100 - $0)) }
    }

    var isStale: Bool {
        guard let sample = latestSample else { return true }
        return sample.connectionState != .connected || Date().timeIntervalSince(sample.receivedAt) > 2 * 60
    }
}

struct ProfileQuotaPoint: Identifiable {
    let profileID: UUID
    let profileName: String
    let date: Date
    let usedPercent: Int

    var id: String { "\(profileID.uuidString)-\(date.timeIntervalSince1970)" }
}

final class AccountProfileStore: ObservableObject {
    @Published private(set) var profiles: [AccountProfile] = []
    @Published private(set) var errorMessage: String?

    let containerURL: URL
    let indexURL: URL
    private let fileManager: FileManager
    private let asynchronousPersistence: Bool
    private let saltURL: URL
    private var salt: Data
    private var currentProfileID: UUID?

    init(
        fileManager: FileManager = .default,
        applicationSupportURL: URL? = nil,
        loadOnInit: Bool = true,
        asynchronousPersistence: Bool = false
    ) {
        self.fileManager = fileManager
        self.asynchronousPersistence = asynchronousPersistence
        let base = applicationSupportURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        containerURL = base.appendingPathComponent("com.openai.codex-usage-status", isDirectory: true)
        indexURL = containerURL.appendingPathComponent("profiles.json")
        saltURL = containerURL.appendingPathComponent("profile-salt")
        salt = Data()
        if loadOnInit { load() }
    }

    /// Performs the legacy profile/index read away from the main actor. The
    /// synchronous implementation remains available for deterministic tests
    /// and migration callers; startup uses this entry point.
    func loadAsynchronously(completion: (() -> Void)? = nil) {
        let fileManager = self.fileManager
        let containerURL = self.containerURL
        let indexURL = self.indexURL
        let saltURL = self.saltURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var loadedSalt = Data()
            var loadedProfiles: [AccountProfile] = []
            var loadError: String?
            do {
                try fileManager.createDirectory(at: containerURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                if fileManager.fileExists(atPath: saltURL.path) {
                    loadedSalt = try Data(contentsOf: saltURL)
                    guard loadedSalt.count == 32 else {
                        throw NSError(domain: "CodexUsageStatus.ProfileStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "profile salt 長度無效"])
                    }
                    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: saltURL.path)
                } else {
                    loadedSalt = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
                    try loadedSalt.write(to: saltURL, options: [.atomic])
                    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: saltURL.path)
                }
                if fileManager.fileExists(atPath: indexURL.path) {
                    let data = try Data(contentsOf: indexURL)
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .secondsSince1970
                    do {
                        if let envelope = try? decoder.decode(AccountProfileIndex.self, from: data) {
                            loadedProfiles = envelope.profiles
                        } else {
                            loadedProfiles = try decoder.decode([AccountProfile].self, from: data)
                        }
                    } catch {
                        let backup = indexURL.deletingPathExtension()
                            .appendingPathExtension("corrupt.\(Int(Date().timeIntervalSince1970))")
                        try? fileManager.moveItem(at: indexURL, to: backup)
                        loadError = "帳號 profile 索引損壞，已保留副本：\(backup.lastPathComponent)"
                    }
                }
            } catch {
                loadError = "帳號 profile 索引無法讀取，將保留目前可用資料。"
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !loadedSalt.isEmpty { self.salt = loadedSalt }
                self.profiles = loadedProfiles
                self.errorMessage = loadError
                completion?()
            }
        }
    }

    func load() {
        do {
            try fileManager.createDirectory(at: containerURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if fileManager.fileExists(atPath: saltURL.path) {
                salt = try Data(contentsOf: saltURL)
                guard salt.count == 32 else {
                    throw NSError(domain: "CodexUsageStatus.ProfileStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "profile salt 長度無效"])
                }
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: saltURL.path)
            } else {
                salt = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
                try salt.write(to: saltURL, options: [.atomic])
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: saltURL.path)
            }
            guard fileManager.fileExists(atPath: indexURL.path) else { return }
            let data = try Data(contentsOf: indexURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            do {
                if let envelope = try? decoder.decode(AccountProfileIndex.self, from: data) {
                    profiles = envelope.profiles
                } else {
                    profiles = try decoder.decode([AccountProfile].self, from: data)
                }
            } catch {
                // Preserve the corrupt index for recovery instead of allowing
                // the next profile selection to silently overwrite it.
                let backup = indexURL.deletingPathExtension()
                    .appendingPathExtension("corrupt.\(Int(Date().timeIntervalSince1970))")
                try? fileManager.moveItem(at: indexURL, to: backup)
                profiles = []
                errorMessage = "帳號 profile 索引損壞，已保留副本：\(backup.lastPathComponent)"
            }
        } catch {
            errorMessage = "帳號 profile 索引無法讀取，將保留目前可用資料。"
        }
    }

    func select(identity: AccountIdentity, forceNewUnidentified: Bool = false) -> AccountProfileSelection {
        let fingerprint = makeFingerprint(identity)
        let previousID = currentProfileID
        let profile: AccountProfile
        if !forceNewUnidentified, identity.email == nil,
                  let currentID = currentProfileID,
                  let current = profiles.first(where: {
                      $0.id == currentID && $0.isUnidentified && ($0.accountType == nil || $0.accountType == identity.accountType)
                  }) {
            profile = current
        } else if !forceNewUnidentified, identity.email == nil,
                  let recentUnknown = profiles
                    .filter({ $0.isUnidentified && $0.accountType == identity.accountType })
                    .max(by: { $0.lastSeen < $1.lastSeen }) {
            // No stable server identity exists here. Prefer the most recently
            // selected manual profile after relaunch and keep the limitation
            // visible instead of silently merging it with a known account.
            profile = recentUnknown
        } else if !forceNewUnidentified, let existing = profiles.first(where: { $0.fingerprint == fingerprint }) {
            profile = existing
        } else {
            let typeName = identity.accountType == "chatgpt" ? "ChatGPT 帳號" : "未識別帳號"
            profile = AccountProfile(id: UUID(), fingerprint: fingerprint, displayName: typeName, accountType: identity.accountType, lastSeen: Date(), isUnidentified: identity.email == nil)
            profiles.append(profile)
        }
        currentProfileID = profile.id
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index].lastSeen = Date()
            profiles[index].accountType = identity.accountType ?? profiles[index].accountType
            // A stable Email supersedes an old unidentified fallback. If a
            // response temporarily omits Email, keep the existing identity
            // classification instead of downgrading a known profile.
            if identity.email != nil {
                profiles[index].isUnidentified = false
            }
        }
        persist()
        return AccountProfileSelection(profile: profile, identity: identity, switched: previousID != profile.id)
    }

    func profileDirectory(for profile: AccountProfile) -> URL {
        let directory = containerURL.appendingPathComponent("accounts", isDirectory: true).appendingPathComponent(profile.id.uuidString, isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }

    func codexHomeURL(for profile: AccountProfile) -> URL {
        let directory = profileDirectory(for: profile).appendingPathComponent("codex-home", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }

    func credentialsURL(for profile: AccountProfile) -> URL {
        codexHomeURL(for: profile).appendingPathComponent("auth.json")
    }

    func hasCredentials(for profile: AccountProfile) -> Bool {
        fileManager.isReadableFile(atPath: credentialsURL(for: profile).path)
    }

    func historyURL(for profile: AccountProfile) -> URL {
        profileDirectory(for: profile).appendingPathComponent("history.json")
    }

    func tokenActivityURL(for profile: AccountProfile) -> URL {
        profileDirectory(for: profile).appendingPathComponent("token-activity.json")
    }

    func accountProfiles() -> [AccountProfile] { profiles.sorted { $0.lastSeen > $1.lastSeen } }

    func renameProfile(id: UUID, displayName: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        profiles[index].displayName = String(trimmed.prefix(80))
        profiles[index].isDisplayNameCustom = true
        persist()
    }

    func updateProfile(_ id: UUID, authMode: String? = nil, accountType: String? = nil) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        if let authMode { profiles[index].authMode = authMode }
        if let accountType { profiles[index].accountType = accountType }
        profiles[index].lastSeen = Date()
        persist()
    }

    func setWorkerEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].workerEnabled = enabled
        persist()
    }

    func setManaged(_ managed: Bool, for id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].isManaged = managed
        persist()
    }

    func setSyncInterval(_ seconds: Int, for id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].syncIntervalSeconds = max(60, min(3600, seconds))
        persist()
    }

    @discardableResult
    func createManualProfile(displayName: String? = nil) -> AccountProfile {
        let ordinal = profiles.filter(\.isUnidentified).count + 1
        let profile = AccountProfile(
            id: UUID(),
            fingerprint: "manual-\(UUID().uuidString)",
            displayName: displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? String(displayName!.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
                : "未識別帳號 \(ordinal)",
            accountType: nil,
            lastSeen: Date(),
            isDisplayNameCustom: displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            isUnidentified: true,
            isManaged: true
        )
        profiles.append(profile)
        currentProfileID = profile.id
        persist()
        return profile
    }

    @discardableResult
    func createManagedProfile(displayName: String? = nil) -> AccountProfile {
        createManualProfile(displayName: displayName)
    }

    func importCodexHome(from sourceURL: URL, into profile: AccountProfile) throws {
        let manager = fileManager
        let sourceHome = sourceURL.standardizedFileURL
        let sourceAuth = sourceHome.lastPathComponent == "auth.json"
            ? sourceHome
            : sourceHome.appendingPathComponent("auth.json")
        let authValues = try sourceAuth.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard authValues.isRegularFile == true, authValues.isSymbolicLink != true,
              manager.isReadableFile(atPath: sourceAuth.path) else {
            throw NSError(domain: "CodexUsageStatus.ProfileStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "選取的 profile 找不到可讀取的 auth.json。"])
        }
        let authObject = try JSONSerialization.jsonObject(with: Data(contentsOf: sourceAuth))
        guard let authDictionary = authObject as? [String: Any], !authDictionary.isEmpty else {
            throw NSError(domain: "CodexUsageStatus.ProfileStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "auth.json 不是有效的 Codex JSON object。"])
        }
        let destination = codexHomeURL(for: profile)
        let profileDirectory = profileDirectory(for: profile)
        let staging = profileDirectory.appendingPathComponent("codex-home.staging-\(UUID().uuidString)", isDirectory: true)
        let backup = profileDirectory.appendingPathComponent("codex-home.backup-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            try manager.copyItem(at: sourceAuth, to: staging.appendingPathComponent("auth.json"))
            let sourceDirectory = sourceHome.lastPathComponent == "auth.json" ? sourceHome.deletingLastPathComponent() : sourceHome
            let sourceConfig = sourceDirectory.appendingPathComponent("config.toml")
            let configValues = try? sourceConfig.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if configValues?.isRegularFile == true, configValues?.isSymbolicLink != true, manager.isReadableFile(atPath: sourceConfig.path) {
                try manager.copyItem(at: sourceConfig, to: staging.appendingPathComponent("config.toml"))
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.appendingPathComponent("auth.json").path)
            if manager.fileExists(atPath: staging.appendingPathComponent("config.toml").path) {
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.appendingPathComponent("config.toml").path)
            }
            if manager.fileExists(atPath: destination.path) {
                try manager.moveItem(at: destination, to: backup)
            }
            try manager.moveItem(at: staging, to: destination)
            try? manager.removeItem(at: backup)
        } catch {
            if !manager.fileExists(atPath: destination.path), manager.fileExists(atPath: backup.path) {
                try? manager.moveItem(at: backup, to: destination)
            }
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    func profile(for id: UUID) -> AccountProfile? { profiles.first { $0.id == id } }

    @discardableResult
    func deleteProfile(id: UUID) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
        let profile = profiles[index]
        do {
            let directory = profileDirectory(for: profile)
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
            profiles.remove(at: index)
            if currentProfileID == id { currentProfileID = profiles.first?.id }
            persist()
            return true
        } catch {
            errorMessage = "帳號 profile 無法刪除：\(error.localizedDescription)"
            return false
        }
    }

    private func makeFingerprint(_ identity: AccountIdentity) -> String {
        if let email = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !email.isEmpty {
            let data = Data(("email|" + email).utf8)
            return "email-" + SHA256.hash(data: salt + data).map { String(format: "%02x", $0) }.joined()
        }
        if let accountType = identity.accountType {
            return "unknown-" + accountType
        }
        return "unknown-account"
    }

    private func persist() {
        if asynchronousPersistence {
            do {
                let envelope = AccountProfileIndex(schemaVersion: 1, profiles: profiles)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .secondsSince1970
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(envelope)
                Task { await PersistenceWriteCoordinator.shared.enqueue(url: indexURL, data: data, fileManager: fileManager) }
                errorMessage = nil
            } catch {
                errorMessage = "帳號 profile 索引無法保存：\(error.localizedDescription)"
            }
            return
        }
        do {
            try fileManager.createDirectory(at: containerURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(AccountProfileIndex(schemaVersion: 1, profiles: profiles))
            try data.write(to: indexURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
            errorMessage = nil
        } catch {
            errorMessage = "帳號 profile 無法保存：\(error.localizedDescription)"
        }
    }
}

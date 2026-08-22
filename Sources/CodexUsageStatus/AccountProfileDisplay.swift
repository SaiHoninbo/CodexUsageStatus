import Foundation

/// The single, non-persistent identity presentation used by the HUD and
/// detail panel. Email is accepted only from the in-memory health snapshot
/// and is never written to a profile, history, preference, log, or
/// notification payload. The UI intentionally shows the complete address so
/// managed accounts can be distinguished without relying on an opaque number.
struct AccountProfileDisplay: Equatable {
    let title: String
    let subtitle: String
    let isWarning: Bool

    static func make(profile: AccountProfile, among profiles: [AccountProfile], health: AccountHealthSnapshot?) -> AccountProfileDisplay {
        let identity = health?.identity
        let email = fullEmail(identity?.email)
        let title: String
        if let email {
            // A complete Email is the most useful stable, user-recognisable
            // label. Keep custom names in the metadata line rather than
            // hiding the identity that the user asked to distinguish.
            title = email
        } else if profile.isDisplayNameCustom {
            title = profile.displayName
        } else {
            let peers = profiles.filter { $0.isUnidentified == profile.isUnidentified && !$0.isDisplayNameCustom }
                .sorted { $0.id.uuidString < $1.id.uuidString }
            let ordinal = (peers.firstIndex(where: { $0.id == profile.id }) ?? 0) + 1
            title = "\(profile.isUnidentified ? "未識別帳號" : "ChatGPT 帳號") \(ordinal)"
        }

        let plan = normalized(identity?.planType)
        let auth = friendlyAuthMode(identity?.authMode ?? profile.authMode, accountType: identity?.accountType ?? profile.accountType)
        let accountState = health?.connectionState
        var parts: [String] = []
        if email != nil {
            if let plan { parts.append(plan) }
            if let auth { parts.append(auth) }
        } else {
            parts.append(auth ?? (profile.isUnidentified ? "未識別登入" : "待同步"))
            parts.append(plan ?? "未提供方案")
        }
        if let accountState, accountState != .connected, accountState != .connecting {
            parts.append(accountState == .offline ? "離線" : accountState.displayName)
        }
        // A profile can have been created as an unidentified fallback before
        // the first account/read response. Once a stable Email is available,
        // present it as identified immediately instead of leaving a warning
        // icon beside a now-distinguishable account.
        return AccountProfileDisplay(title: title, subtitle: parts.joined(separator: " · "), isWarning: email == nil && profile.isUnidentified)
    }

    /// Returns a complete, presentation-ready Email from the in-memory
    /// account snapshot. This must not be used as a persisted identity key.
    static func fullEmail(_ rawEmail: String?) -> String? {
        guard let rawEmail else { return nil }
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = email.lastIndex(of: "@"), at > email.startIndex else { return nil }
        let local = email[..<at]
        let domain = email[email.index(after: at)...]
        guard !local.isEmpty, !domain.isEmpty, !domain.contains(" ") else { return nil }
        return email
    }

    /// Retained for compatibility with older callers and migration tests. New
    /// account UI uses `fullEmail(_:)` by design.
    static func maskEmail(_ rawEmail: String?) -> String? {
        guard let rawEmail else { return nil }
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let at = email.lastIndex(of: "@"), at > email.startIndex else { return nil }
        let local = String(email[..<at])
        let domain = String(email[email.index(after: at)...])
        guard !local.isEmpty, !domain.isEmpty else { return nil }
        let stars = String(repeating: "*", count: max(1, local.count - 1))
        return "\(local.prefix(1))\(stars)@\(domain)"
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func friendlyAuthMode(_ value: String?, accountType: String?) -> String? {
        let rawValue = normalized(value)
        let normalizedAccountType = normalized(accountType)
        if rawValue?.lowercased() == "managed", normalizedAccountType?.lowercased() == "chatgpt" {
            return "ChatGPT"
        }
        let candidate = rawValue ?? normalizedAccountType
        guard let candidate else { return nil }
        switch candidate.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "") {
        case "apikey", "api": return "API Key"
        case "chatgpt", "chatgptauth", "chatgpttoken": return "ChatGPT"
        case "bedrock": return "Bedrock"
        default: return candidate
        }
    }
}

import Foundation

/// The single, non-persistent identity presentation used by the HUD and
/// detail panel. Raw email is accepted only from the in-memory health snapshot
/// and is immediately reduced to a masked display value.
struct AccountProfileDisplay: Equatable {
    let title: String
    let subtitle: String
    let isWarning: Bool

    static func make(profile: AccountProfile, among profiles: [AccountProfile], health: AccountHealthSnapshot?) -> AccountProfileDisplay {
        let title: String
        if profile.isDisplayNameCustom {
            title = profile.displayName
        } else {
            let peers = profiles.filter { $0.isUnidentified == profile.isUnidentified && !$0.isDisplayNameCustom }
                .sorted { $0.id.uuidString < $1.id.uuidString }
            let ordinal = (peers.firstIndex(where: { $0.id == profile.id }) ?? 0) + 1
            title = "\(profile.isUnidentified ? "未識別帳號" : "ChatGPT 帳號") \(ordinal)"
        }

        let identity = health?.identity
        let email = maskEmail(identity?.email)
        let plan = normalized(identity?.planType)
        let auth = friendlyAuthMode(identity?.authMode ?? profile.authMode, accountType: identity?.accountType ?? profile.accountType)
        let accountState = health?.connectionState
        var parts: [String] = []
        if let email {
            parts.append(email)
            if let plan { parts.append(plan) }
            if let auth { parts.append(auth) }
        } else {
            parts.append(auth ?? (profile.isUnidentified ? "未識別登入" : "待同步"))
            parts.append(plan ?? "未提供方案")
        }
        if let accountState, accountState != .connected, accountState != .connecting {
            parts.append(accountState == .offline ? "離線" : accountState.displayName)
        }
        return AccountProfileDisplay(title: title, subtitle: parts.joined(separator: " · "), isWarning: profile.isUnidentified)
    }

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

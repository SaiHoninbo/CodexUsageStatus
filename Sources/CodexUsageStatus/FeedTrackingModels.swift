import Foundation
import CryptoKit

enum InferenceConfidence: String, Codable, Equatable, Comparable {
    case low
    case medium
    case high

    private var rank: Int {
        switch self { case .low: return 0; case .medium: return 1; case .high: return 2 }
    }

    static func < (lhs: InferenceConfidence, rhs: InferenceConfidence) -> Bool { lhs.rank < rhs.rank }
}

enum PredictionCorroboration: String, Codable, Equatable {
    case unverified
    case appServerConfirmed
    case appServerMismatch
}

struct FeedPost: Codable, Equatable, Identifiable {
    let id: String
    let canonicalURL: URL?
    let publishedAt: Date?
    let updatedAt: Date?
    let firstSeenAt: Date
    let title: String
    let plainTextSnippet: String
    let feedURL: URL

    var effectiveActivityAt: Date { publishedAt ?? updatedAt ?? firstSeenAt }

    var normalizedEffectiveContent: String {
        let titlePart = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let snippetPart = plainTextSnippet.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return [titlePart, snippetPart, canonicalURL?.absoluteString ?? "",
                publishedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                updatedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                feedURL.absoluteString].joined(separator: "\u{1F}")
    }
}

struct ResetPrediction: Codable, Equatable {
    let windowStart: Date?
    let windowEnd: Date?
    let inferenceConfidence: InferenceConfidence
    var corroboration: PredictionCorroboration
    let reason: String
    let sourcePostID: String
    let sourceURL: URL?
    let interpretedTimeZoneIdentifier: String?
    let interpretedTimeZoneLabel: String?
    let detectedAt: Date

    var hasValidWindow: Bool {
        guard let start = windowStart, let end = windowEnd else { return false }
        return end >= start
    }
}

struct FeedTrackingEnvelope: Codable, Equatable {
    let configuredFeedURL: URL?
    var feedTitle: String?
    var feedLink: URL?
    var etag: String?
    var lastModified: String?
    var posts: [FeedPost]
    var predictionsByPostID: [String: ResetPrediction]
    var sentNotificationPostIDs: Set<String>
    var lastSuccessfulFetch: Date?

    init(configuredFeedURL: URL? = nil,
         feedTitle: String? = nil,
         feedLink: URL? = nil,
         etag: String? = nil,
         lastModified: String? = nil,
         posts: [FeedPost] = [],
         predictionsByPostID: [String: ResetPrediction] = [:],
         sentNotificationPostIDs: Set<String> = [],
         lastSuccessfulFetch: Date? = nil) {
        self.configuredFeedURL = configuredFeedURL
        self.feedTitle = feedTitle
        self.feedLink = feedLink
        self.etag = etag
        self.lastModified = lastModified
        self.posts = posts
        self.predictionsByPostID = predictionsByPostID
        self.sentNotificationPostIDs = sentNotificationPostIDs
        self.lastSuccessfulFetch = lastSuccessfulFetch
    }

    mutating func normalizeInvariants() {
        let ids = Set(posts.map(\.id))
        predictionsByPostID = predictionsByPostID.filter { ids.contains($0.key) }
        sentNotificationPostIDs = sentNotificationPostIDs.filter { ids.contains($0) }
        posts.sort { $0.effectiveActivityAt == $1.effectiveActivityAt ? $0.id < $1.id : $0.effectiveActivityAt < $1.effectiveActivityAt }
    }
}

enum FeedTrackingState: Equatable {
    case disabled
    case notConfigured
    case idle
    case fetching
    case loaded
    case notModified
    case error(String)
}

enum FeedPollingCadence: Int, CaseIterable, Codable, Equatable, Hashable {
    case manual = 0
    case quarterHour = 900
    case hour = 3600
    case sixHours = 21600
    case daily = 86400

    var displayName: String {
        switch self { case .manual: return "手動"; case .quarterHour: return "每 15 分鐘"; case .hour: return "每小時"; case .sixHours: return "每 6 小時"; case .daily: return "每天" }
    }
}

enum FeedURLPolicy {
    static func validate(_ url: URL) -> Result<URL, FeedURLPolicyError> {
        guard url.scheme?.lowercased() == "https" else { return .failure(.httpsRequired) }
        guard url.user == nil && url.password == nil else { return .failure(.userinfoNotAllowed) }
        guard let host = url.host, !host.isEmpty else { return .failure(.hostRequired) }
        let lowered = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard lowered != "localhost" else { return .failure(.privateAddressNotAllowed) }
        if let address = IPv4Address(lowered), address.isPrivateOrSpecial { return .failure(.privateAddressNotAllowed) }
        if let address = IPv6Address(lowered), address.isPrivateOrSpecial { return .failure(.privateAddressNotAllowed) }
        return .success(url)
    }
}

enum FeedURLPolicyError: Error, Equatable, CustomStringConvertible {
    case httpsRequired
    case userinfoNotAllowed
    case hostRequired
    case privateAddressNotAllowed
    case dnsPreflightFailed
    var description: String {
        switch self { case .httpsRequired: return "Feed URL 必須使用 HTTPS"; case .userinfoNotAllowed: return "Feed URL 不得包含帳號或密碼"; case .hostRequired: return "Feed URL 缺少主機"; case .privateAddressNotAllowed: return "Feed URL 不得指向本機、私有或 link-local 位址"; case .dnsPreflightFailed: return "無法安全驗證 Feed 主機" }
    }
}

private struct IPv4Address {
    let octets: [Int]
    init?(_ value: String) {
        let parts = value.split(separator: ".")
        let nums = parts.compactMap { Int($0) }
        guard parts.count == 4, nums.count == 4, nums.allSatisfy({ (0...255).contains($0) }) else { return nil }
        octets = nums
    }
    var isPrivateOrSpecial: Bool {
        let a = octets[0], b = octets[1]
        return a == 127 || a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 169 && b == 254) || a == 0
    }
}

private struct IPv6Address {
    let value: String
    init?(_ value: String) { guard value.contains(":"), value.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else { return nil }; self.value = value }
    var isPrivateOrSpecial: Bool {
        let lower = value.lowercased()
        if lower.hasPrefix("::ffff:") { return true }
        return lower == "::1" || lower == "::" || lower.hasPrefix("fe8") || lower.hasPrefix("fe9") || lower.hasPrefix("fea") || lower.hasPrefix("feb") || lower.hasPrefix("fc") || lower.hasPrefix("fd")
    }
}

enum FeedStableID {
    static func fallback(title: String, snippet: String, publishedAt: Date?, updatedAt: Date?, feedURL: URL) -> String {
        let formatter = ISO8601DateFormatter()
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let normalizedSnippet = snippet.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let normalized = [feedURL.absoluteString, normalizedTitle, normalizedSnippet, publishedAt.map { formatter.string(from: $0) } ?? "", updatedAt.map { formatter.string(from: $0) } ?? ""].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        return "fallback-" + digest
    }
}

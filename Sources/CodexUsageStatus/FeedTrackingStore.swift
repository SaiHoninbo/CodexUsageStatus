import Foundation

final class FeedTrackingStore {
    private(set) var envelope: FeedTrackingEnvelope
    let fileURL: URL
    private(set) var errorMessage: String?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL? = nil) {
        let resolved = fileURL ?? Self.defaultURL()
        self.fileURL = resolved
        encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: resolved), let decoded = try? decoder.decode(FeedTrackingEnvelope.self, from: data) {
            envelope = decoded; envelope.normalizeInvariants(); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: resolved.path)
        } else if FileManager.default.fileExists(atPath: resolved.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = resolved.deletingLastPathComponent().appendingPathComponent("\(resolved.lastPathComponent).corrupt.\(stamp)")
            try? FileManager.default.moveItem(at: resolved, to: backup)
            envelope = FeedTrackingEnvelope(); errorMessage = "Feed state 已隔離並重設"
        } else { envelope = FeedTrackingEnvelope() }
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("com.openai.codex-usage-status", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory.appendingPathComponent("feed-tracking.json")
    }

    @discardableResult
    func configure(feedURL: URL?) -> Bool {
        guard envelope.configuredFeedURL != feedURL else { return false }
        envelope = FeedTrackingEnvelope(configuredFeedURL: feedURL)
        try? save()
        return true
    }

    @discardableResult
    func upsert(post incoming: FeedPost, prediction: ResetPrediction?) -> Bool {
        let existing = envelope.posts.first(where: { $0.id == incoming.id })
        let preserved = existing.map { FeedPost(id: incoming.id, canonicalURL: incoming.canonicalURL, publishedAt: incoming.publishedAt, updatedAt: incoming.updatedAt, firstSeenAt: $0.firstSeenAt, title: incoming.title, plainTextSnippet: incoming.plainTextSnippet, feedURL: incoming.feedURL) } ?? incoming
        if let existing, existing.normalizedEffectiveContent == preserved.normalizedEffectiveContent {
            return false
        }
        envelope.posts.removeAll { $0.id == incoming.id }
        envelope.posts.append(preserved)
        if let prediction { envelope.predictionsByPostID[incoming.id] = prediction } else { envelope.predictionsByPostID.removeValue(forKey: incoming.id) }
        envelope.normalizeInvariants()
        return true
    }
    func post(id: String) -> FeedPost? { envelope.posts.first(where: { $0.id == id }) }

    func replaceMetadata(title: String?, link: URL?, etag: String?, lastModified: String?, successfulAt: Date?) {
        envelope.feedTitle = title; envelope.feedLink = link
        envelope.etag = etag; envelope.lastModified = lastModified
        envelope.lastSuccessfulFetch = successfulAt
    }

    func prune(now: Date, retention: TimeInterval = 30 * 24 * 3600, maxPosts: Int = 200) {
        let cutoff = now.addingTimeInterval(-retention)
        envelope.posts = envelope.posts.filter { $0.effectiveActivityAt >= cutoff }
        envelope.posts.sort { $0.effectiveActivityAt == $1.effectiveActivityAt ? $0.id < $1.id : $0.effectiveActivityAt > $1.effectiveActivityAt }
        if envelope.posts.count > maxPosts { envelope.posts = Array(envelope.posts.prefix(maxPosts)) }
        envelope.normalizeInvariants()
    }

    func hasNotified(postID: String) -> Bool { envelope.sentNotificationPostIDs.contains(postID) }
    func markNotified(postID: String) { envelope.sentNotificationPostIDs.insert(postID) }
    func updatePrediction(postID: String, prediction: ResetPrediction?) {
        guard envelope.posts.contains(where: { $0.id == postID }) else { return }
        if let prediction { envelope.predictionsByPostID[postID] = prediction } else { envelope.predictionsByPostID.removeValue(forKey: postID) }
    }

    func save() throws {
        envelope.normalizeInvariants()
        let data = try encoder.encode(envelope)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if FileManager.default.fileExists(atPath: fileURL.path) { _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: fileURL) }
    }
}

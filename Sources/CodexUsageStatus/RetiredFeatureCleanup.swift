import Foundation
import UserNotifications

protocol RetiredFeatureNotificationCenter {
    func getPendingNotificationIdentifiers(completionHandler: @Sendable @escaping ([String]) -> Void)
    func getDeliveredNotificationIdentifiers(completionHandler: @Sendable @escaping ([String]) -> Void)
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: RetiredFeatureNotificationCenter {
    func getPendingNotificationIdentifiers(completionHandler: @Sendable @escaping ([String]) -> Void) {
        getPendingNotificationRequests { requests in completionHandler(requests.map(\.identifier)) }
    }

    func getDeliveredNotificationIdentifiers(completionHandler: @Sendable @escaping ([String]) -> Void) {
        getDeliveredNotifications { notifications in completionHandler(notifications.map { $0.request.identifier }) }
    }
}

enum RetiredFeatureCleanup {
    private static let retiredFeedDefaults = ["feed.enabled", "feed.url", "feed.cadence"]

    static func run(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        applicationSupportDirectory: URL? = nil,
        notificationCenter: RetiredFeatureNotificationCenter = UNUserNotificationCenter.current(),
        now: Date = Date()
    ) {
        retiredFeedDefaults.forEach { defaults.removeObject(forKey: $0) }
        let base = applicationSupportDirectory ??
            (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory)
        let appDirectory = base.appendingPathComponent("com.openai.codex-usage-status", isDirectory: true)
        quarantineFeedFile(
            appDirectory.appendingPathComponent("feed-tracking.json"),
            appDirectory: appDirectory,
            fileManager: fileManager,
            now: now
        )
        removeRetiredFeedNotifications(notificationCenter)
    }

    private static func quarantineFeedFile(_ feedFile: URL, appDirectory: URL, fileManager: FileManager, now: Date) {
        guard fileManager.fileExists(atPath: feedFile.path) else { return }
        let retiredDirectory = appDirectory.appendingPathComponent("retired", isDirectory: true).appendingPathComponent("feed", isDirectory: true)
        do {
            try fileManager.createDirectory(at: retiredDirectory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: retiredDirectory.path)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            let stamp = formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
            var destination = retiredDirectory.appendingPathComponent("feed-tracking.\(stamp).json")
            var suffix = 1
            while fileManager.fileExists(atPath: destination.path) {
                destination = retiredDirectory.appendingPathComponent("feed-tracking.\(stamp)-\(suffix).json")
                suffix += 1
            }
            try fileManager.moveItem(at: feedFile, to: destination)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            // Leave the original bytes untouched so cleanup can be retried.
        }
    }

    private static func removeRetiredFeedNotifications(_ center: RetiredFeatureNotificationCenter) {
        center.getPendingNotificationIdentifiers { identifiers in
            let feedIDs = identifiers.filter { $0.hasPrefix("feed-") }
            if !feedIDs.isEmpty { center.removePendingNotificationRequests(withIdentifiers: feedIDs) }
        }
        center.getDeliveredNotificationIdentifiers { identifiers in
            let feedIDs = identifiers.filter { $0.hasPrefix("feed-") }
            if !feedIDs.isEmpty { center.removeDeliveredNotifications(withIdentifiers: feedIDs) }
        }
    }
}

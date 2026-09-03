import Foundation
import UserNotifications

/// One-time, non-destructive retirement of the removed Feed subsystem.
/// Existing bytes are moved without decoding or re-serializing so an operator
/// can recover them if the feature is ever reintroduced.  No quota, turn or
/// updater notification identifiers are touched.
enum RetiredFeatureCleanup {
    private static let defaultsKeys = ["feed.enabled", "feed.url", "feed.cadence"]

    static func run(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        notificationCenter: UNUserNotificationCenter = .current()
    ) {
        defaultsKeys.forEach { defaults.removeObject(forKey: $0) }
        quarantineFeedStore(fileManager: fileManager)
        notificationCenter.getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix("feed-") }
            guard !ids.isEmpty else { return }
            notificationCenter.removePendingNotificationRequests(withIdentifiers: ids)
        }
        notificationCenter.getDeliveredNotifications { notifications in
            let ids = notifications.map { $0.request.identifier }.filter { $0.hasPrefix("feed-") }
            guard !ids.isEmpty else { return }
            notificationCenter.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    @discardableResult
    static func quarantineFeedStore(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil,
        now: Date = Date()
    ) -> Bool {
        let root = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let appDirectory = root.appendingPathComponent("com.openai.codex-usage-status", isDirectory: true)
        let source = appDirectory.appendingPathComponent("feed-tracking.json")
        guard fileManager.fileExists(atPath: source.path) else { return false }

        let quarantineDirectory = appDirectory
            .appendingPathComponent("retired", isDirectory: true)
            .appendingPathComponent("feed", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: quarantineDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: quarantineDirectory.path)
            let stamp = ISO8601DateFormatter()
            stamp.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            let filename = "feed-tracking.\(stamp.string(from: now).replacingOccurrences(of: ":", with: "-")).json"
            let destination = quarantineDirectory.appendingPathComponent(filename)
            try fileManager.moveItem(at: source, to: destination)
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: destination.path)
            return true
        } catch {
            // Fail safely: the source remains in place when quarantine cannot
            // be completed, and no replacement or deletion is attempted.
            return false
        }
    }
}

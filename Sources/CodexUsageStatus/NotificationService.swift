import Foundation
import UserNotifications

final class UsageNotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private let sentKeysDefaultsKey = "usage.notification.sentKeys"

    override init() {
        super.init()
        center.delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func refreshAuthorization(completion: @escaping (UNAuthorizationStatus) -> Void) {
        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                completion(settings.authorizationStatus)
            }
        }
    }

    func requestAuthorization(completion: @escaping (UNAuthorizationStatus) -> Void) {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            self.refreshAuthorization(completion: completion)
        }
    }

    func evaluate(
        snapshot: UsageSnapshot,
        now: Date,
        thresholds: [Int],
        separateWindows: Bool,
        soundEnabled: Bool,
        profileID: UUID? = nil
    ) {
        guard now.timeIntervalSince(snapshot.receivedAt) <= 2 * 60 else { return }

        var windows: [(name: String, window: RateLimitWindow?)] = [("Primary", snapshot.primary)]
        if separateWindows {
            windows.append(("Secondary", snapshot.secondary))
        }

        let normalizedThresholds = thresholds
            .map { max(1, min(99, $0)) }
            .sorted()

        for entry in windows {
            guard let window = entry.window else { continue }
            let bucket = "\(profileID?.uuidString ?? "unknown")|\(snapshot.limitId ?? "unknown")|\(entry.name)"
            let sentThresholds = Set(normalizedThresholds.filter { threshold in
                hasSent(bucket: bucket, threshold: threshold, resetsAt: window.resetsAt)
            })
            let pendingThresholds = UsageThresholdPolicy.pendingThresholds(
                remainingPercent: window.remainingPercent,
                thresholds: normalizedThresholds,
                sentThresholds: sentThresholds
            )
            guard !pendingThresholds.isEmpty else { continue }

            let thresholdText = pendingThresholds
                .sorted(by: >)
                .map { "\($0)%" }
                .joined(separator: "、")
            let content = UNMutableNotificationContent()
            content.title = "Codex 用量提醒"
            content.body = "\(entry.name) 剩餘 \(window.remainingPercent)%，低於 \(thresholdText) 門檻。"
            content.sound = soundEnabled ? .default : nil

            let request = UNNotificationRequest(
                identifier: "codex-usage-\(entry.name.lowercased())-\(window.resetsAt ?? 0)-\(pendingThresholds.min() ?? 0)",
                content: content,
                trigger: nil
            )
            center.add(request) { [weak self] error in
                guard error == nil else { return }
                for threshold in pendingThresholds {
                    self?.markSent(bucket: bucket, threshold: threshold, resetsAt: window.resetsAt)
                }
            }
        }
    }

    private func hasSent(bucket: String, threshold: Int, resetsAt: Int64?) -> Bool {
        sentKeys.contains(key(bucket: bucket, threshold: threshold, resetsAt: resetsAt))
    }

    private func markSent(bucket: String, threshold: Int, resetsAt: Int64?) {
        var keys = sentKeys
        keys.insert(key(bucket: bucket, threshold: threshold, resetsAt: resetsAt))
        defaults.set(Array(keys.sorted().suffix(500)), forKey: sentKeysDefaultsKey)
    }

    private var sentKeys: Set<String> {
        Set(defaults.stringArray(forKey: sentKeysDefaultsKey) ?? [])
    }

    private func key(bucket: String, threshold: Int, resetsAt: Int64?) -> String {
        let reset = resetsAt.map(String.init) ?? "unknown"
        return "\(bucket)|\(threshold)|\(reset)"
    }
}

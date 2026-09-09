import Foundation
import UserNotifications

struct TurnNotificationPreferences: Equatable {
    var notifyOnSuccess: Bool
    var notifyOnFailure: Bool
    var notifyOnInterrupted: Bool
    var notifyOnLongRunning: Bool
    var longRunningThresholdMinutes: Int
    var showContentInNotifications: Bool
    var soundEnabled: Bool
}

final class TurnNotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private let sentKey = "turn.notification.sentKeys"
    /// `UNUserNotificationCenter.add` completes asynchronously.  Reserve a
    /// terminal notification key before enqueueing so repeated evaluations of
    /// the same Turn cannot race the completion callback and enqueue multiple
    /// banners.  The reservation is process-local only; the existing
    /// persisted `sentKeys` remains the cross-launch dedupe authority.
    private var pendingKeys = Set<String>()
    private let pendingKeysLock = NSLock()

    override init() {
        super.init()
        center.delegate = self
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func evaluate(event: TurnActivitySnapshot, profileID: UUID?, preferences: TurnNotificationPreferences, now: Date = Date()) {
        let eventType: String?
        switch event.state {
        case .completed: eventType = preferences.notifyOnSuccess ? "completed" : nil
        case .failed: eventType = preferences.notifyOnFailure ? "failed" : nil
        case .interrupted: eventType = preferences.notifyOnInterrupted ? "interrupted" : nil
        default: eventType = nil
        }
        if let eventType, let turnID = event.turnID,
           let reservation = reserveIfNeeded(profileID: profileID, turnID: turnID, eventType: eventType) {
            let content = UNMutableNotificationContent()
            content.title = TurnNotificationContentPolicy.title(state: event.state, programName: event.programName)
            content.body = TurnNotificationContentPolicy.body(
                elapsedSeconds: event.elapsedSeconds,
                tokenTotal: event.tokenTotal,
                content: event.content,
                errorMessage: event.errorMessage,
                contentEnabled: preferences.showContentInNotifications
            )
            content.sound = preferences.soundEnabled ? .default : nil
            let request = UNNotificationRequest(identifier: "codex-turn-\(turnID)-\(eventType)", content: content, trigger: nil)
            center.add(request) { [weak self] error in
                guard let self else { return }
                if error == nil {
                    self.markSent(profileID: profileID, turnID: turnID, eventType: eventType)
                }
                self.releaseReservation(reservation)
            }
        }

        if preferences.notifyOnLongRunning, event.state == .active,
           let startedAt = event.startedAt,
           now.timeIntervalSince(startedAt) >= TimeInterval(preferences.longRunningThresholdMinutes * 60),
           let turnID = event.turnID,
           let reservation = reserveIfNeeded(profileID: profileID, turnID: turnID, eventType: "longRunning") {
            let content = UNMutableNotificationContent()
            content.title = "Codex Turn 執行較久"
            content.body = "目前 turn 已執行 \(max(1, Int(now.timeIntervalSince(startedAt) / 60))) 分鐘。"
            content.sound = preferences.soundEnabled ? .default : nil
            center.add(UNNotificationRequest(identifier: "codex-turn-\(turnID)-long", content: content, trigger: nil)) { [weak self] error in
                guard let self else { return }
                if error == nil {
                    self.markSent(profileID: profileID, turnID: turnID, eventType: "longRunning")
                }
                self.releaseReservation(reservation)
            }
        }
    }

    func notifyAccountSwitch(profileID: UUID, displayName: String, soundEnabled: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = "Codex 帳號已切換"
        content.body = "目前使用：\(displayName)"
        content.sound = soundEnabled ? .default : nil
        let request = UNNotificationRequest(identifier: "codex-account-switch-\(profileID.uuidString)-\(Int(Date().timeIntervalSince1970))", content: content, trigger: nil)
        center.add(request)
    }

    /// Atomically checks the existing persisted dedupe key and reserves it for
    /// this process.  The returned key is released when UserNotifications
    /// accepts or rejects the request.  Keeping the reservation separate from
    /// `sentKeys` avoids changing the existing persistence or delivery
    /// semantics while closing the async enqueue race.
    private func reserveIfNeeded(profileID: UUID?, turnID: String, eventType: String) -> String? {
        let notificationKey = key(profileID: profileID, turnID: turnID, eventType: eventType)
        pendingKeysLock.lock()
        defer { pendingKeysLock.unlock() }
        guard !sentKeys.contains(notificationKey), pendingKeys.insert(notificationKey).inserted else {
            return nil
        }
        return notificationKey
    }

    private func releaseReservation(_ notificationKey: String) {
        pendingKeysLock.lock()
        pendingKeys.remove(notificationKey)
        pendingKeysLock.unlock()
    }

    private func markSent(profileID: UUID?, turnID: String, eventType: String) {
        var keys = sentKeys
        keys.insert(key(profileID: profileID, turnID: turnID, eventType: eventType))
        defaults.set(Array(keys.sorted().suffix(1000)), forKey: sentKey)
    }

    private var sentKeys: Set<String> { Set(defaults.stringArray(forKey: sentKey) ?? []) }

    private func key(profileID: UUID?, turnID: String, eventType: String) -> String {
        "\(profileID?.uuidString ?? "unknown")|\(turnID)|\(eventType)"
    }
}

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
        if let eventType, let turnID = event.turnID, !hasSent(profileID: profileID, turnID: turnID, eventType: eventType) {
            let body = makeBody(event: event, contentEnabled: preferences.showContentInNotifications)
            let content = UNMutableNotificationContent()
            content.title = "Codex Turn \(event.state.displayName)"
            content.body = body
            content.sound = preferences.soundEnabled ? .default : nil
            let request = UNNotificationRequest(identifier: "codex-turn-\(turnID)-\(eventType)", content: content, trigger: nil)
            center.add(request) { [weak self] error in
                guard error == nil else { return }
                self?.markSent(profileID: profileID, turnID: turnID, eventType: eventType)
            }
        }

        if preferences.notifyOnLongRunning, event.state == .active,
           let startedAt = event.startedAt,
           now.timeIntervalSince(startedAt) >= TimeInterval(preferences.longRunningThresholdMinutes * 60),
           let turnID = event.turnID,
           !hasSent(profileID: profileID, turnID: turnID, eventType: "longRunning") {
            let content = UNMutableNotificationContent()
            content.title = "Codex Turn 執行較久"
            content.body = "目前 turn 已執行 \(max(1, Int(now.timeIntervalSince(startedAt) / 60))) 分鐘。"
            content.sound = preferences.soundEnabled ? .default : nil
            center.add(UNNotificationRequest(identifier: "codex-turn-\(turnID)-long", content: content, trigger: nil)) { [weak self] error in
                guard error == nil else { return }
                self?.markSent(profileID: profileID, turnID: turnID, eventType: "longRunning")
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

    private func makeBody(event: TurnActivitySnapshot, contentEnabled: Bool) -> String {
        var parts: [String] = []
        if let elapsed = event.elapsedSeconds { parts.append("耗時 \(elapsed) 秒") }
        if let tokenTotal = event.tokenTotal { parts.append("\(tokenTotal.formatted()) tokens") }
        if contentEnabled, let content = event.content, !content.isEmpty { parts.append(content) }
        if let error = event.errorMessage, !error.isEmpty { parts.append(error) }
        return parts.joined(separator: " · ")
    }

    private func hasSent(profileID: UUID?, turnID: String, eventType: String) -> Bool {
        sentKeys.contains(key(profileID: profileID, turnID: turnID, eventType: eventType))
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

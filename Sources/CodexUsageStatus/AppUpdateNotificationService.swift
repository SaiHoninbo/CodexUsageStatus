import Foundation
import UserNotifications

final class AppUpdateNotificationService {
    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private let sentVersionKey = "app.update.notification.sentVersion"

    func notifyIfNeeded(for release: AppUpdateRelease, soundEnabled: Bool) {
        guard defaults.string(forKey: sentVersionKey) != release.version else { return }
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "Codex Usage Status 有新版本"
            content.body = "版本 \(release.version) 已可用。請在 App 內按「立即更新並重新啟動」。"
            content.sound = soundEnabled ? .default : nil
            let request = UNNotificationRequest(
                identifier: "codex-update-\(release.version)",
                content: content,
                trigger: nil
            )
            self?.center.add(request) { error in
                guard error == nil else { return }
                self?.defaults.set(release.version, forKey: self?.sentVersionKey ?? "app.update.notification.sentVersion")
            }
        }
    }
}

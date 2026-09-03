import Foundation
import UserNotifications

final class FeedNotificationService: FeedNotificationSubmitting {
    private let submit: (UNNotificationRequest, @escaping (Error?) -> Void) -> Void

    init(submit: @escaping (UNNotificationRequest, @escaping (Error?) -> Void) -> Void = { request, completion in
        UNUserNotificationCenter.current().add(request, withCompletionHandler: completion)
    }) { self.submit = submit }

    func send(post: FeedPost, prediction: ResetPrediction?, postCount: Int = 1, completion: @escaping (Result<Void, Error>) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = "可能重置時間"
        if let prediction, let start = prediction.windowStart {
            content.body = "預估 \(Self.format(start, prediction: prediction)) · \(postCount) 則"
        } else { content.body = "偵測到新的使用量重置公告 · \(postCount) 則" }
        content.sound = .default
        let request = UNNotificationRequest(identifier: "feed-\(post.id)", content: content, trigger: nil)
        submit(request) { error in
            if let error { completion(.failure(error)) } else { completion(.success(())) }
        }
    }

    private static func format(_ date: Date, prediction: ResetPrediction) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "M/d HH:mm"
        if let identifier = prediction.interpretedTimeZoneIdentifier { formatter.timeZone = TimeZone(identifier: identifier) ?? (prediction.interpretedTimeZoneLabel == "PST" ? TimeZone(secondsFromGMT: -8 * 3600) : prediction.interpretedTimeZoneLabel == "PDT" ? TimeZone(secondsFromGMT: -7 * 3600) : prediction.interpretedTimeZoneLabel == "UTC" ? TimeZone(secondsFromGMT: 0) : nil) }
        let label = prediction.interpretedTimeZoneLabel.map { " \($0)" } ?? ""
        return formatter.string(from: date) + label
    }
}

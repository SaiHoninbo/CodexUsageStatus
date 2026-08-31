import Foundation

enum ResetPredictionPolicy {
    static let resetKeywords = ["reset", "rate limit", "usage limit", "quota", "window", "limit"]
    static let continuationKeywords = ["update", "follow-up", "follow up", "moved to tomorrow", "button was pressed", "landing", "still working", "time changed", "delayed"]

    static func predict(post: FeedPost, now: Date, systemTimeZone: TimeZone, calendar: Calendar) -> ResetPrediction? {
        let source = [post.title, post.plainTextSnippet].joined(separator: " ")
        let lower = source.lowercased()
        guard resetKeywords.contains(where: { lower.contains($0) }) || isContinuation(post) else { return nil }
        let timeZoneInfo = timezone(in: source, fallback: systemTimeZone, at: now)
        let zone = timeZoneInfo.timeZone
        var localCalendar = calendar; localCalendar.timeZone = zone
        guard let range = findWindow(in: source, now: now, calendar: localCalendar, timeZone: zone) else {
            return ResetPrediction(windowStart: nil, windowEnd: nil,
                                   inferenceConfidence: .low,
                                   corroboration: .unverified,
                                   reason: source.trimmingCharacters(in: .whitespacesAndNewlines),
                                   sourcePostID: post.id, sourceURL: post.canonicalURL,
                                   interpretedTimeZoneIdentifier: timeZoneInfo.identifier,
                                   interpretedTimeZoneLabel: timeZoneInfo.label,
                                   detectedAt: now)
        }
        let confidence: InferenceConfidence = timeZoneInfo.isExplicit ? .medium : .low
        return ResetPrediction(windowStart: range.start, windowEnd: range.end,
                               inferenceConfidence: confidence,
                               corroboration: .unverified,
                               reason: source.trimmingCharacters(in: .whitespacesAndNewlines),
                               sourcePostID: post.id, sourceURL: post.canonicalURL,
                               interpretedTimeZoneIdentifier: timeZoneInfo.identifier,
                               interpretedTimeZoneLabel: timeZoneInfo.label,
                               detectedAt: now)
    }

    static func isContinuation(_ post: FeedPost) -> Bool {
        let source = (post.title + " " + post.plainTextSnippet).lowercased()
        return continuationKeywords.contains(where: { source.contains($0) })
    }

    static func isResetRelated(_ post: FeedPost) -> Bool {
        let source = (post.title + " " + post.plainTextSnippet).lowercased()
        return resetKeywords.contains(where: { source.contains($0) }) || isContinuation(post)
    }

    static func corroborated(_ prediction: ResetPrediction, officialResetDates: [Date]) -> ResetPrediction {
        var copy = prediction
        guard !officialResetDates.isEmpty else { copy.corroboration = .unverified; return copy }
        guard let start = prediction.windowStart, let end = prediction.windowEnd else { copy.corroboration = .unverified; return copy }
        copy.corroboration = officialResetDates.contains(where: { $0 >= start && $0 <= end }) ? .appServerConfirmed : .appServerMismatch
        return copy
    }

    private static func timezone(in source: String, fallback: TimeZone, at date: Date) -> (timeZone: TimeZone, identifier: String?, label: String?, isExplicit: Bool) {
        let upper = source.uppercased()
        if upper.range(of: "\\bPST\\b", options: .regularExpression) != nil { return (TimeZone(secondsFromGMT: -8 * 3600)!, "GMT-0800", "PST", true) }
        if upper.range(of: "\\bPDT\\b", options: .regularExpression) != nil { return (TimeZone(secondsFromGMT: -7 * 3600)!, "GMT-0700", "PDT", true) }
        if upper.range(of: "\\bUTC\\b", options: .regularExpression) != nil { return (TimeZone(secondsFromGMT: 0)!, "UTC", "UTC", true) }
        return (fallback, fallback.identifier, fallback.identifier == "Asia/Taipei" ? "GMT+8" : fallback.abbreviation(for: date), false)
    }

    private static func findWindow(in source: String, now: Date, calendar: Calendar, timeZone: TimeZone) -> (start: Date, end: Date)? {
        let pattern = #"(?i)(?:(today|tomorrow)\s+)?(?:(\d{1,2})[/-](\d{1,2})\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*(?:-|–|—|to)\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)?"#
        guard let expression = try? NSRegularExpression(pattern: pattern), let match = expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else { return nil }
        func value(_ index: Int) -> String? { let r = match.range(at: index); guard r.location != NSNotFound, let rr = Range(r, in: source) else { return nil }; return String(source[rr]) }
        let relative = value(1)?.lowercased(); let month = Int(value(2) ?? ""); let day = Int(value(3) ?? "")
        guard let hour1 = Int(value(4) ?? ""), let hour2 = Int(value(7) ?? "") else { return nil }
        let minute1 = Int(value(5) ?? "0") ?? 0; let minute2 = Int(value(8) ?? "0") ?? 0
        let meridiem1 = value(6)?.lowercased(); let meridiem2 = value(9)?.lowercased()
        func hour(_ raw: Int, _ meridiem: String?) -> Int { guard let meridiem else { return raw }; if meridiem == "pm" { return raw == 12 ? 12 : raw + 12 }; return raw == 12 ? 0 : raw }
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        if relative == "tomorrow" { components.day = (components.day ?? 0) + 1 }
        if let month, let day { components.month = month; components.day = day; if month < (calendar.component(.month, from: now) - 6) { components.year = (components.year ?? 0) + 1 } }
        components.hour = hour(hour1, meridiem1); components.minute = minute1; components.second = 0
        guard let start = calendar.date(from: components) else { return nil }
        var endComponents = components; endComponents.hour = hour(hour2, meridiem2); endComponents.minute = minute2
        if endComponents.hour! < components.hour! || (endComponents.hour == components.hour && endComponents.minute! < components.minute!) { endComponents.day = (endComponents.day ?? 0) + 1 }
        guard let end = calendar.date(from: endComponents) else { return nil }
        return (start, end)
    }
}

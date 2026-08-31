import Foundation

struct AnnouncementEvent: Identifiable, Equatable {
    let id: String
    let posts: [FeedPost]
    let latestPost: FeedPost
    let postCount: Int
    let latestPrediction: ResetPrediction?
    let bestKnownPrediction: ResetPrediction?
    let latestActivityAt: Date
    let hasConflictingPredictions: Bool
}

enum HUDAnnouncementLayoutMode: Equatable {
    case compact
    case regular

    static func mode(for scaleLevel: HUDScaleLevel) -> HUDAnnouncementLayoutMode {
        switch scaleLevel { case .smaller3, .smaller4: return .compact; default: return .regular }
    }
}

enum FeedAnnouncementPolicy {
    static func events(posts input: [FeedPost], predictions: [String: ResetPrediction]) -> [AnnouncementEvent] {
        let posts = input.filter(ResetPredictionPolicy.isResetRelated).sorted { lhs, rhs in
            lhs.effectiveActivityAt == rhs.effectiveActivityAt ? lhs.id < rhs.id : lhs.effectiveActivityAt < rhs.effectiveActivityAt
        }
        struct Bucket { var root: FeedPost; var posts: [FeedPost]; var conflict = false }
        var buckets: [Bucket] = []
        for post in posts {
            let newPrediction = predictions[post.id]
            let postText = (post.title + " " + post.plainTextSnippet).lowercased()
            let hasResetTopic = ResetPredictionPolicy.resetKeywords.contains(where: { postText.contains($0) })
            let candidate = buckets.indices.reversed().first { index in
                let bucket = buckets[index]
                let continuation = ResetPredictionPolicy.isContinuation(post)
                guard sameResetTopic(root: bucket.root, candidate: post, candidateHasResetKeyword: hasResetTopic) else { return false }
                if continuation { return post.effectiveActivityAt.timeIntervalSince(bucket.posts.last?.effectiveActivityAt ?? bucket.root.effectiveActivityAt) <= 48 * 3600 }
                guard let newWindow = interval(for: newPrediction), let best = bestWindow(in: bucket.posts, predictions: predictions) else {
                    return post.effectiveActivityAt.timeIntervalSince(bucket.root.effectiveActivityAt) <= 24 * 3600
                }
                return newWindow.intersects(best)
            }
            if let index = candidate {
                let old = buckets[index]
                if ResetPredictionPolicy.isContinuation(post), let newWindow = interval(for: newPrediction), let oldPrediction = bestWindowPrediction(in: old.posts, predictions: predictions), (newWindow.start != oldPrediction.windowStart || newWindow.end != oldPrediction.windowEnd) { buckets[index].conflict = true }
                buckets[index].posts.append(post)
                buckets[index].posts.sort { $0.effectiveActivityAt == $1.effectiveActivityAt ? $0.id < $1.id : $0.effectiveActivityAt < $1.effectiveActivityAt }
            } else if hasResetTopic || ResetPredictionPolicy.isContinuation(post) { buckets.append(Bucket(root: post, posts: [post])) }
        }
        return buckets.map { bucket in
            let sorted = bucket.posts.sorted { $0.effectiveActivityAt == $1.effectiveActivityAt ? $0.id < $1.id : $0.effectiveActivityAt < $1.effectiveActivityAt }
            let latest = sorted.last!
            let latestPrediction = predictions[latest.id]
            let best = bestWindowPrediction(in: sorted, predictions: predictions)
            let allWindows = sorted.compactMap { predictions[$0.id].flatMap(interval(for:)) }
            let overlapping = allWindows.count <= 1 || allWindows.dropFirst().allSatisfy { allWindows[0].intersects($0) }
            return AnnouncementEvent(id: bucket.root.id, posts: sorted, latestPost: latest, postCount: sorted.count, latestPrediction: latestPrediction, bestKnownPrediction: best, latestActivityAt: latest.effectiveActivityAt, hasConflictingPredictions: bucket.conflict || !overlapping && sorted.contains { ResetPredictionPolicy.isContinuation($0) })
        }.sorted { $0.latestActivityAt == $1.latestActivityAt ? $0.id < $1.id : $0.latestActivityAt > $1.latestActivityAt }
    }

    static func filter(events: [AnnouncementEvent], range: HistoryRange, now: Date, calendar: Calendar = .current) -> [AnnouncementEvent] {
        let duration: TimeInterval
        switch range { case .day: duration = 24 * 3600; case .week: duration = 7 * 24 * 3600; case .month: duration = 30 * 24 * 3600 }
        let cutoff = now.addingTimeInterval(-duration)
        return events.filter { $0.latestActivityAt >= cutoff }
    }

    private static func interval(for prediction: ResetPrediction?) -> DateInterval? {
        guard let prediction, let start = prediction.windowStart, let end = prediction.windowEnd, end >= start else { return nil }
        return DateInterval(start: start, end: end)
    }
    private static func bestWindow(in posts: [FeedPost], predictions: [String: ResetPrediction]) -> DateInterval? { bestWindowPrediction(in: posts, predictions: predictions).flatMap(interval(for:)) }
    private static func bestWindowPrediction(in posts: [FeedPost], predictions: [String: ResetPrediction]) -> ResetPrediction? {
        posts.reversed().compactMap { predictions[$0.id] }.first(where: { interval(for: $0) != nil })
    }

    private static func sameResetTopic(root: FeedPost, candidate: FeedPost, candidateHasResetKeyword: Bool) -> Bool {
        guard ResetPredictionPolicy.isResetRelated(root) else { return false }
        // A continuation is only eligible when it is anchored to a reset-related
        // root. Explicit reset keywords on the candidate make the topic direct;
        // temporal reset language is the bounded equivalent for updates such as
        // “moved to tomorrow” that omit the word reset. Generic updates (for
        // example, “landing page is live”) must never join a reset event.
        if candidateHasResetKeyword { return true }
        guard ResetPredictionPolicy.isContinuation(candidate) else { return false }
        let text = (candidate.title + " " + candidate.plainTextSnippet).lowercased()
        let resetTemporalContext = [
            "moved to tomorrow", "time changed", "delayed", "reset window",
            "quota window", "usage window", "rate limit window"
        ]
        return resetTemporalContext.contains(where: { text.contains($0) })
    }
}

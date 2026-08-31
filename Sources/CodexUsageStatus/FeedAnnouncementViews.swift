import SwiftUI

struct FeedAnnouncementBanner: View {
    let event: AnnouncementEvent
    let scaleLevel: HUDScaleLevel
    let showAll: () -> Void
    var olderCount: Int = 0

    var body: some View {
        let mode = HUDAnnouncementLayoutMode.mode(for: scaleLevel)
        Button(action: showAll) {
            if mode == .compact { compact } else { regular }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, mode == .compact ? 4 : 7)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.orange.opacity(0.4), lineWidth: 1))
    }

    private var compact: some View {
        HStack(spacing: 6) { Image(systemName: "clock.arrow.circlepath"); Text("可能重置 \(formattedWindow) · \(event.postCount) 則 · 詳細").lineLimit(1) }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
    }
    private var regular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("可能重置時間").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.orange)
            Text(formattedWindow).font(.system(size: 14, weight: .bold, design: .rounded)).lineLimit(1)
            HStack(spacing: 5) {
                Text(statusText).font(.system(size: 10, weight: .medium, design: .rounded))
                Text("最近事件 · \(event.postCount) 則").font(.system(size: 10, weight: .medium, design: .rounded))
                if olderCount > 0 { Text("另有 \(olderCount) 個較早事件").font(.system(size: 10, weight: .medium, design: .rounded)) }
                if event.hasConflictingPredictions { Text("時間線索有更新").foregroundStyle(.orange) }
                Spacer(); Text("查看全部").font(.system(size: 10, weight: .bold, design: .rounded))
            }.lineLimit(1)
            Text("僅供參考，正式倒數以 App Server 為準").font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
    private var formattedWindow: String {
        guard let prediction = event.bestKnownPrediction, let start = prediction.windowStart else { return "尚無明確時間" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "M/d HH:mm"
        if let identifier = prediction.interpretedTimeZoneIdentifier { formatter.timeZone = TimeZone(identifier: identifier) ?? (prediction.interpretedTimeZoneLabel == "PST" ? TimeZone(secondsFromGMT: -8 * 3600) : prediction.interpretedTimeZoneLabel == "PDT" ? TimeZone(secondsFromGMT: -7 * 3600) : prediction.interpretedTimeZoneLabel == "UTC" ? TimeZone(secondsFromGMT: 0) : nil) }
        let end = prediction.windowEnd.map { formatter.string(from: $0) } ?? ""
        let label = prediction.interpretedTimeZoneLabel.map { " \($0)" } ?? ""
        return end.isEmpty ? formatter.string(from: start) + label : "\(formatter.string(from: start))–\(end)\(label)"
    }
    private var statusText: String {
        guard let prediction = event.bestKnownPrediction else { return "尚無時間推論" }
        switch prediction.corroboration { case .appServerConfirmed: return "\(prediction.inferenceConfidence.rawValue.capitalized) 推論 · App Server 已確認"; case .appServerMismatch: return "\(prediction.inferenceConfidence.rawValue.capitalized) 推論 · 與 App Server 不一致"; case .unverified: return "\(prediction.inferenceConfidence.rawValue.capitalized) 推論 · 尚未由 App Server 確認" }
    }
}

struct FeedAnnouncementListView: View {
    let events: [AnnouncementEvent]
    let predictionsByPostID: [String: ResetPrediction]
    @State private var expandedID: String?
    var body: some View {
        LazyVStack(spacing: 10) { ForEach(events) { event in eventRow(event) } }
            .padding(.horizontal, 16).padding(.vertical, 12)
        .onAppear { if expandedID == nil { expandedID = events.first?.id } }
        .onChange(of: events) { old, updated in
            if let first = updated.first, old.first?.id != first.id || !updated.contains(where: { $0.id == expandedID }) { expandedID = first.id }
        }
    }
    @ViewBuilder private func eventRow(_ event: AnnouncementEvent) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { expandedID == event.id }, set: { expandedID = $0 ? event.id : nil })) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(event.posts) { post in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(post.title.isEmpty ? "重置公告" : post.title).font(.system(size: 12, weight: .semibold))
                        Text("活動：\(post.effectiveActivityAt.formatted(date: .abbreviated, time: .shortened))" + (post.publishedAt.map { " · 發布 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "") + (post.updatedAt.map { " · 更新 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")).font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(post.plainTextSnippet).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                        if let prediction = predictionsByPostID[post.id] {
                            Text(prediction.hasValidWindow ? "\(prediction.inferenceConfidence.rawValue.capitalized) 推論" : "此貼文本身沒有新的時間資訊").font(.system(size: 10)).foregroundStyle(.secondary)
                            if let label = prediction.interpretedTimeZoneLabel { Text("時區：\(label)").font(.system(size: 10)).foregroundStyle(.secondary) }
                            Text(corroborationLabel(prediction.corroboration)).font(.system(size: 10)).foregroundStyle(.secondary)
                            if let url = prediction.sourceURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { Link("查看原文", destination: url) }
                        }
                    }.padding(.vertical, 3)
                }
            }.padding(.top, 6)
        } label: { VStack(alignment: .leading, spacing: 3) {
            Text(event.latestPost.title.isEmpty ? "重置公告" : event.latestPost.title).font(.system(size: 13, weight: .bold))
            Text("\(event.postCount) 則 · \(event.latestActivityAt.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 10)).foregroundStyle(.secondary)
            if let prediction = event.bestKnownPrediction { Text("\(windowLabel(prediction)) · \(prediction.inferenceConfidence.rawValue.capitalized) 推論 · \(corroborationLabel(prediction.corroboration))").font(.system(size: 10)).foregroundStyle(.secondary) }
            if event.hasConflictingPredictions { Text("時間線索有更新").font(.system(size: 10)).foregroundStyle(.orange) }
        } }
    }
    private func corroborationLabel(_ value: PredictionCorroboration) -> String { switch value { case .appServerConfirmed: return "App Server 已確認"; case .appServerMismatch: return "與 App Server 不一致"; case .unverified: return "尚未由 App Server 確認" } }
    private func windowLabel(_ prediction: ResetPrediction) -> String {
        guard let start = prediction.windowStart else { return "尚無明確時間" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "M/d HH:mm"
        if let identifier = prediction.interpretedTimeZoneIdentifier { formatter.timeZone = TimeZone(identifier: identifier) ?? (prediction.interpretedTimeZoneLabel == "PST" ? TimeZone(secondsFromGMT: -8 * 3600) : prediction.interpretedTimeZoneLabel == "PDT" ? TimeZone(secondsFromGMT: -7 * 3600) : TimeZone(secondsFromGMT: 0)) }
        let label = prediction.interpretedTimeZoneLabel.map { " \($0)" } ?? ""
        return "\(formatter.string(from: start))\(prediction.windowEnd.map { "–\(formatter.string(from: $0))" } ?? "")\(label)"
    }
}

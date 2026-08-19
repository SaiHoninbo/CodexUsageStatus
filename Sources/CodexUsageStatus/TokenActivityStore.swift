import Foundation
import Combine

enum TokenActivityRange: String, CaseIterable, Identifiable {
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: return "7 天"
        case .month: return "30 天"
        }
    }

    var days: Int {
        switch self {
        case .week: return 7
        case .month: return 30
        }
    }
}

enum TokenActivityState: Equatable {
    case idle
    case loading
    case loaded
    case offline
    case unsupported
    case error

    var displayName: String {
        switch self {
        case .idle: return "尚未取得"
        case .loading: return "讀取中…"
        case .loaded: return "已更新"
        case .offline: return "離線，保留最後資料"
        case .unsupported: return "此登入模式不支援 Token Activity"
        case .error: return "Token Activity 讀取錯誤"
        }
    }
}

struct DailyTokenUsage: Codable, Equatable, Identifiable {
    let startDate: String
    let tokens: Int64

    var id: String { startDate }
}

struct TokenActivitySnapshot: Codable, Equatable {
    let fetchedAt: Date
    let lifetimeTokens: Int64?
    let peakDailyTokens: Int64?
    let longestRunningTurnSec: Int64?
    let currentStreakDays: Int64?
    let longestStreakDays: Int64?
    let dailyUsageBuckets: [DailyTokenUsage]?
}

enum TokenActivityCodec {
    enum CodecError: Error, LocalizedError {
        case invalidObject
        case invalidSummary

        var errorDescription: String? {
            switch self {
            case .invalidObject: return "Token Activity 回應不是有效的 JSON object"
            case .invalidSummary: return "Token Activity summary 格式無法解析"
            }
        }
    }

    static func decode(from result: Any, fetchedAt: Date = Date()) throws -> TokenActivitySnapshot {
        guard let object = result as? [String: Any] else { throw CodecError.invalidObject }
        var summary: [String: Any] = [:]
        if let rawSummary = object["summary"], !(rawSummary is NSNull) {
            guard let decodedSummary = rawSummary as? [String: Any] else { throw CodecError.invalidSummary }
            summary = decodedSummary
        }

        var buckets: [DailyTokenUsage]? = nil
        if let rawBuckets = object["dailyUsageBuckets"], !(rawBuckets is NSNull) {
            guard let array = rawBuckets as? [Any] else { throw CodecError.invalidObject }
            buckets = array.compactMap { raw in
                guard let bucket = raw as? [String: Any],
                      let startDate = bucket["startDate"] as? String,
                      !startDate.isEmpty,
                      Self.isValidDateString(startDate),
                      let tokens = int64(bucket["tokens"]) else { return nil }
                return DailyTokenUsage(startDate: startDate, tokens: max(0, tokens))
            }
        }

        return TokenActivitySnapshot(
            fetchedAt: fetchedAt,
            lifetimeTokens: nonNegative(summary["lifetimeTokens"]),
            peakDailyTokens: nonNegative(summary["peakDailyTokens"]),
            longestRunningTurnSec: nonNegative(summary["longestRunningTurnSec"]),
            currentStreakDays: nonNegative(summary["currentStreakDays"]),
            longestStreakDays: nonNegative(summary["longestStreakDays"]),
            dailyUsageBuckets: buckets
        )
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }

    private static func nonNegative(_ value: Any?) -> Int64? {
        guard let value = int64(value) else { return nil }
        return max(0, value)
    }

    private static func isValidDateString(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }
}

final class TokenActivityStore: ObservableObject {
    @Published private(set) var snapshot: TokenActivitySnapshot?
    @Published private(set) var errorMessage: String?

    let fileURL: URL
    private let fileManager: FileManager
    private let calendar: Calendar
    private let retentionDays = 30

    init(fileManager: FileManager = .default, applicationSupportURL: URL? = nil) {
        self.fileManager = fileManager
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar = utc
        let base = applicationSupportURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        fileURL = base
            .appendingPathComponent("com.openai.codex-usage-status", isDirectory: true)
            .appendingPathComponent("token-activity.json")
        load()
    }

    init(fileManager: FileManager = .default, fileURL: URL) {
        self.fileManager = fileManager
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        self.calendar = utc
        self.fileURL = fileURL
        load()
    }

    func load(now: Date = Date()) {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let loaded = try decoder.decode(TokenActivitySnapshot.self, from: data)
            snapshot = prune(loaded, now: now)
            errorMessage = nil
            if snapshot != loaded { persist() }
        } catch {
            errorMessage = "Token Activity 資料無法讀取，已保留目前記憶體中的資料。"
        }
    }

    @discardableResult
    func update(incoming: TokenActivitySnapshot, now: Date = Date()) -> TokenActivitySnapshot {
        let old = snapshot
        let merged = TokenActivitySnapshot(
            fetchedAt: incoming.fetchedAt,
            lifetimeTokens: incoming.lifetimeTokens ?? old?.lifetimeTokens,
            peakDailyTokens: incoming.peakDailyTokens ?? old?.peakDailyTokens,
            longestRunningTurnSec: incoming.longestRunningTurnSec ?? old?.longestRunningTurnSec,
            currentStreakDays: incoming.currentStreakDays ?? old?.currentStreakDays,
            longestStreakDays: incoming.longestStreakDays ?? old?.longestStreakDays,
            dailyUsageBuckets: incoming.dailyUsageBuckets ?? old?.dailyUsageBuckets
        )
        let retained = prune(merged, now: now)
        snapshot = retained
        persist()
        return retained
    }

    func buckets(for range: TokenActivityRange, now: Date = Date()) -> [DailyTokenUsage] {
        guard let buckets = snapshot?.dailyUsageBuckets else { return [] }
        let cutoff = calendar.date(byAdding: .day, value: -(range.days - 1), to: calendar.startOfDay(for: now)) ?? now
        let cutoffString = Self.dateString(cutoff)
        return buckets.filter { $0.startDate >= cutoffString }.sorted { $0.startDate < $1.startDate }
    }

    func clear() {
        snapshot = nil
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            errorMessage = nil
        } catch {
            errorMessage = "Token Activity 無法清除：\(error.localizedDescription)"
        }
    }

    private func prune(_ value: TokenActivitySnapshot, now: Date) -> TokenActivitySnapshot {
        guard let buckets = value.dailyUsageBuckets else { return value }
        let cutoff = calendar.date(byAdding: .day, value: -(retentionDays - 1), to: calendar.startOfDay(for: now)) ?? now
        let cutoffString = Self.dateString(cutoff)
        var latest: [String: DailyTokenUsage] = [:]
        for bucket in buckets where bucket.startDate >= cutoffString {
            latest[bucket.startDate] = bucket
        }
        return TokenActivitySnapshot(
            fetchedAt: value.fetchedAt,
            lifetimeTokens: value.lifetimeTokens,
            peakDailyTokens: value.peakDailyTokens,
            longestRunningTurnSec: value.longestRunningTurnSec,
            currentStreakDays: value.currentStreakDays,
            longestStreakDays: value.longestStreakDays,
            dailyUsageBuckets: latest.values.sorted { $0.startDate < $1.startDate }
        )
    }

    private func persist() {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            guard let snapshot else {
                if fileManager.fileExists(atPath: fileURL.path) { try fileManager.removeItem(at: fileURL) }
                errorMessage = nil
                return
            }
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            errorMessage = nil
        } catch {
            errorMessage = "Token Activity 無法保存：\(error.localizedDescription)"
        }
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

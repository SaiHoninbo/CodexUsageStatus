import Foundation

struct LocalTokenUsageLedgerThread: Codable, Equatable {
    let profileID: UUID?
    let threadID: String
    var turnID: String
    var observedCumulativeTokens: Int64
    var updatedAt: Date
}

struct LocalTokenUsageLedgerSnapshot: Codable, Equatable {
    var totalObservedTokens: Int64
    var threads: [LocalTokenUsageLedgerThread]
    var dailyUsageBuckets: [DailyTokenUsage]
    var longestObservedTurnSec: Int64?
    var lastObservedAt: Date?

    static let empty = LocalTokenUsageLedgerSnapshot(
        totalObservedTokens: 0,
        threads: [],
        dailyUsageBuckets: [],
        longestObservedTurnSec: nil,
        lastObservedAt: nil
    )

    private enum CodingKeys: String, CodingKey {
        case totalObservedTokens
        case threads
        case dailyUsageBuckets
        case longestObservedTurnSec
        case lastObservedAt
    }

    init(
        totalObservedTokens: Int64,
        threads: [LocalTokenUsageLedgerThread],
        dailyUsageBuckets: [DailyTokenUsage],
        longestObservedTurnSec: Int64?,
        lastObservedAt: Date?
    ) {
        self.totalObservedTokens = totalObservedTokens
        self.threads = threads
        self.dailyUsageBuckets = dailyUsageBuckets
        self.longestObservedTurnSec = longestObservedTurnSec
        self.lastObservedAt = lastObservedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        totalObservedTokens = try values.decodeIfPresent(Int64.self, forKey: .totalObservedTokens) ?? 0
        threads = try values.decodeIfPresent([LocalTokenUsageLedgerThread].self, forKey: .threads) ?? []
        dailyUsageBuckets = try values.decodeIfPresent([DailyTokenUsage].self, forKey: .dailyUsageBuckets) ?? []
        longestObservedTurnSec = try values.decodeIfPresent(Int64.self, forKey: .longestObservedTurnSec)
        lastObservedAt = try values.decodeIfPresent(Date.self, forKey: .lastObservedAt)
    }
}

struct LocalTokenUsageLedgerUpdate: Equatable {
    let previousTotalObservedTokens: Int64
    let totalObservedTokens: Int64
    let delta: Int64
}

/// One installation-scoped ledger built only from Codex events observed on
/// this Mac. Profile identity attributes high-water marks but never scopes or
/// deletes the machine total. Account Token Activity is deliberately not an
/// input.
final class LocalTokenUsageLedgerStore {
    private(set) var snapshot: LocalTokenUsageLedgerSnapshot
    private(set) var errorMessage: String?

    let fileURL: URL
    private let fileManager: FileManager
    private let asynchronousPersistence: Bool
    private let retainedTurnLimit = 512
    private var calendar: Calendar

    init(
        fileManager: FileManager = .default,
        fileURL: URL,
        loadOnInit: Bool = true,
        asynchronousPersistence: Bool = false
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL
        self.asynchronousPersistence = asynchronousPersistence
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        snapshot = .empty
        if loadOnInit { load() }
    }

    func loadAsynchronously(completion: (() -> Void)? = nil) {
        let fileURL = self.fileURL
        let fileManager = self.fileManager
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var loaded: LocalTokenUsageLedgerSnapshot?
            var loadError: String?
            if fileManager.fileExists(atPath: fileURL.path) {
                do {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .secondsSince1970
                    loaded = try decoder.decode(
                        LocalTokenUsageLedgerSnapshot.self,
                        from: Data(contentsOf: fileURL)
                    )
                } catch {
                    loadError = "本機 Token ledger 無法讀取，已保留目前記憶體資料。"
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let loaded {
                    self.snapshot = self.normalized(loaded)
                    self.errorMessage = nil
                } else if let loadError {
                    self.errorMessage = loadError
                }
                completion?()
            }
        }
    }

    func load() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            snapshot = normalized(try decoder.decode(
                LocalTokenUsageLedgerSnapshot.self,
                from: Data(contentsOf: fileURL)
            ))
            errorMessage = nil
        } catch {
            errorMessage = "本機 Token ledger 無法讀取，已保留目前記憶體資料。"
        }
    }

    @discardableResult
    func record(
        profileID: UUID?,
        threadID: String,
        turnID: String,
        cumulativeTokenTotal: Int64?,
        lastCallTokenTotal: Int64?,
        at now: Date = Date()
    ) -> LocalTokenUsageLedgerUpdate? {
        guard !threadID.isEmpty, !turnID.isEmpty,
              let cumulativeTokenTotal,
              cumulativeTokenTotal >= 0 else { return nil }

        let previousLedgerTotal = snapshot.totalObservedTokens
        let index = snapshot.threads.firstIndex {
            $0.profileID == profileID && $0.threadID == threadID
        }
        let previousThreadTotal = index.map { snapshot.threads[$0].observedCumulativeTokens }
        let delta: Int64
        if let previousThreadTotal, let index {
            if cumulativeTokenTotal > previousThreadTotal {
                delta = cumulativeTokenTotal - previousThreadTotal
            } else if cumulativeTokenTotal < previousThreadTotal,
                      snapshot.threads[index].turnID != turnID,
                      let lastCallTokenTotal,
                      lastCallTokenTotal > 0 {
                // Codex can restart a persisted thread from a reset cumulative
                // counter. The caller admits only the currently active turn,
                // so the new turn's `last` value is the safe observed delta.
                delta = lastCallTokenTotal
            } else {
                return nil
            }
        } else {
            // A first event can be a replay when a stored thread resumes.
            // `total` includes the whole thread; `last` is the only consumption
            // newly observed in this callback and is therefore the safe seed.
            guard let lastCallTokenTotal, lastCallTokenTotal > 0 else {
                snapshot.threads.append(LocalTokenUsageLedgerThread(
                    profileID: profileID,
                    threadID: threadID,
                    turnID: turnID,
                    observedCumulativeTokens: cumulativeTokenTotal,
                    updatedAt: now
                ))
                snapshot = normalized(snapshot)
                persist()
                return nil
            }
            delta = lastCallTokenTotal
        }
        let (sum, overflow) = previousLedgerTotal.addingReportingOverflow(delta)
        snapshot.totalObservedTokens = overflow ? Int64.max : sum
        if let index {
            snapshot.threads[index].observedCumulativeTokens = cumulativeTokenTotal
            snapshot.threads[index].turnID = turnID
            snapshot.threads[index].updatedAt = now
        } else {
            snapshot.threads.append(LocalTokenUsageLedgerThread(
                profileID: profileID,
                threadID: threadID,
                turnID: turnID,
                observedCumulativeTokens: cumulativeTokenTotal,
                updatedAt: now
            ))
        }
        add(delta: delta, toLocalDayContaining: now)
        snapshot.lastObservedAt = max(snapshot.lastObservedAt ?? now, now)
        snapshot = normalized(snapshot)
        persist()
        return LocalTokenUsageLedgerUpdate(
            previousTotalObservedTokens: previousLedgerTotal,
            totalObservedTokens: snapshot.totalObservedTokens,
            delta: snapshot.totalObservedTokens - previousLedgerTotal
        )
    }

    @discardableResult
    func recordCompletedTurn(
        profileID: UUID?,
        threadID: String,
        turnID: String,
        durationSeconds: Int64?,
        at now: Date = Date()
    ) -> Bool {
        guard !threadID.isEmpty, !turnID.isEmpty,
              let durationSeconds,
              durationSeconds >= 0,
              durationSeconds > (snapshot.longestObservedTurnSec ?? -1) else { return false }
        snapshot.longestObservedTurnSec = durationSeconds
        snapshot.lastObservedAt = max(snapshot.lastObservedAt ?? now, now)
        persist()
        return true
    }

    private func add(delta: Int64, toLocalDayContaining date: Date) {
        let key = Self.localDateString(date, calendar: calendar)
        if let index = snapshot.dailyUsageBuckets.firstIndex(where: { $0.startDate == key }) {
            let current = snapshot.dailyUsageBuckets[index].tokens
            let (sum, overflow) = current.addingReportingOverflow(delta)
            snapshot.dailyUsageBuckets[index] = DailyTokenUsage(
                startDate: key,
                tokens: overflow ? Int64.max : sum
            )
        } else {
            snapshot.dailyUsageBuckets.append(DailyTokenUsage(startDate: key, tokens: delta))
        }
    }

    private func normalized(_ value: LocalTokenUsageLedgerSnapshot) -> LocalTokenUsageLedgerSnapshot {
        LocalTokenUsageLedgerSnapshot(
            totalObservedTokens: max(0, value.totalObservedTokens),
            threads: Array(value.threads
                .filter { !$0.threadID.isEmpty && !$0.turnID.isEmpty && $0.observedCumulativeTokens >= 0 }
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(retainedTurnLimit)),
            dailyUsageBuckets: Dictionary(grouping: value.dailyUsageBuckets, by: \.startDate)
                .map { key, buckets in
                    DailyTokenUsage(startDate: key, tokens: buckets.reduce(into: Int64(0)) { total, bucket in
                        let (sum, overflow) = total.addingReportingOverflow(max(0, bucket.tokens))
                        total = overflow ? Int64.max : sum
                    })
                }
                .sorted { $0.startDate < $1.startDate },
            longestObservedTurnSec: value.longestObservedTurnSec.map { max(0, $0) },
            lastObservedAt: value.lastObservedAt
        )
    }

    private static func localDateString(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            if asynchronousPersistence {
                Task {
                    await PersistenceWriteCoordinator.shared.enqueue(
                        url: fileURL,
                        data: data,
                        fileManager: fileManager
                    )
                }
            } else {
                try fileManager.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try data.write(to: fileURL, options: [.atomic])
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            }
            errorMessage = nil
        } catch {
            errorMessage = "本機 Token ledger 無法保存。"
        }
    }
}

enum LocalTokenUsageLedgerPresentation {
    static let observedLabel = "本機觀測 token"
    static let dailyPeakLabel = "本機單日峰值"
    static let longestTurnLabel = "本機最長 Turn"
    static let currentStreakLabel = "本機目前連續"
    static let longestStreakLabel = "本機最長連續"

    static func metrics(snapshot: LocalTokenUsageLedgerSnapshot) -> [TokenActivityMetric] {
        let streaks = streaks(from: snapshot.dailyUsageBuckets)
        return [
            TokenActivityMetric(
                label: observedLabel,
                value: TokenActivityPresentation.tokenCount(snapshot.totalObservedTokens)
            ),
            TokenActivityMetric(
                label: dailyPeakLabel,
                value: TokenActivityPresentation.tokenCount(snapshot.dailyUsageBuckets.map(\.tokens).max())
            ),
            TokenActivityMetric(
                label: longestTurnLabel,
                value: TokenActivityPresentation.durationText(snapshot.longestObservedTurnSec)
            ),
            TokenActivityMetric(
                label: currentStreakLabel,
                value: TokenActivityPresentation.daysText(Int64(streaks.current))
            ),
            TokenActivityMetric(
                label: longestStreakLabel,
                value: TokenActivityPresentation.daysText(Int64(streaks.longest))
            )
        ]
    }

    static func snapshotForHistory(
        _ ledger: LocalTokenUsageLedgerSnapshot,
        fetchedAt: Date = Date()
    ) -> TokenActivitySnapshot {
        let streakValues = streaks(from: ledger.dailyUsageBuckets)
        return TokenActivitySnapshot(
            fetchedAt: ledger.lastObservedAt ?? fetchedAt,
            lifetimeTokens: ledger.totalObservedTokens,
            peakDailyTokens: ledger.dailyUsageBuckets.map(\.tokens).max(),
            longestRunningTurnSec: ledger.longestObservedTurnSec,
            currentStreakDays: Int64(streakValues.current),
            longestStreakDays: Int64(streakValues.longest),
            dailyUsageBuckets: ledger.dailyUsageBuckets
        )
    }

    static func buckets(
        from snapshot: LocalTokenUsageLedgerSnapshot,
        range: TokenActivityRange,
        now: Date,
        calendar: Calendar = .current
    ) -> [DailyTokenUsage] {
        guard let cutoff = calendar.date(byAdding: .day, value: -(range.days - 1), to: calendar.startOfDay(for: now)) else {
            return snapshot.dailyUsageBuckets
        }
        let components = calendar.dateComponents([.year, .month, .day], from: cutoff)
        let cutoffKey = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        return snapshot.dailyUsageBuckets.filter { $0.startDate >= cutoffKey }.sorted { $0.startDate < $1.startDate }
    }

    static func streaks(from buckets: [DailyTokenUsage], calendar: Calendar = .current) -> (current: Int, longest: Int) {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let days = Set(buckets.filter { $0.tokens > 0 }.compactMap { formatter.date(from: $0.startDate).map(calendar.startOfDay(for:)) }).sorted()
        guard !days.isEmpty else { return (0, 0) }
        var run = 1
        var longest = 1
        for index in 1..<days.count {
            if calendar.dateComponents([.day], from: days[index - 1], to: days[index]).day == 1 {
                run += 1
                longest = max(longest, run)
            } else {
                run = 1
            }
        }
        return (run, longest)
    }

    static func feedback(
        for update: LocalTokenUsageLedgerUpdate,
        generation: UInt64
    ) -> TokenHeroUpdateFeedback {
        TokenHeroUpdateFeedback(
            generation: generation,
            previousTokens: update.previousTotalObservedTokens,
            tokens: update.totalObservedTokens,
            changedMetricLabels: [observedLabel]
        )
    }
}

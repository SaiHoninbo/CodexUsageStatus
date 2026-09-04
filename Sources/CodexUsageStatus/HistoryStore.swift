import Foundation
import Combine

enum HistoryRange: String, CaseIterable, Identifiable {
    case day
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return "24 小時"
        case .week: return "7 天"
        case .month: return "30 天"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .day: return 24 * 60 * 60
        case .week: return 7 * 24 * 60 * 60
        case .month: return 30 * 24 * 60 * 60
        }
    }
}

final class HistoryStore: ObservableObject {
    @Published private(set) var samples: [HistorySample] = []
    @Published private(set) var errorMessage: String?

    let fileURL: URL

    private let fileManager: FileManager
    private let loadOnInit: Bool
    private let asynchronousPersistence: Bool
    private let retention: TimeInterval = 30 * 24 * 60 * 60
    private let minimumSampleInterval: TimeInterval = 5 * 60

    init(
        fileManager: FileManager = .default,
        applicationSupportURL: URL? = nil,
        loadOnInit: Bool = true,
        asynchronousPersistence: Bool = false
    ) {
        self.fileManager = fileManager
        self.loadOnInit = loadOnInit
        self.asynchronousPersistence = asynchronousPersistence
        let baseURL = applicationSupportURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        fileURL = baseURL
            .appendingPathComponent("com.openai.codex-usage-status", isDirectory: true)
            .appendingPathComponent("history.json")
        if loadOnInit { load() }
    }

    init(
        fileManager: FileManager = .default,
        fileURL: URL,
        loadOnInit: Bool = true,
        asynchronousPersistence: Bool = false
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL
        self.loadOnInit = loadOnInit
        self.asynchronousPersistence = asynchronousPersistence
        if loadOnInit { load() }
    }

    /// Loads the persisted history off the main actor. The completion runs on
    /// the caller's queue and receives only decoded presentation data.
    func loadAsynchronously(now: Date = Date(), completion: (() -> Void)? = nil) {
        let fileURL = self.fileURL
        let fileManager = self.fileManager
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var loaded: [HistorySample] = []
            var loadError: String?
            if fileManager.fileExists(atPath: fileURL.path) {
                do {
                    let data = try Data(contentsOf: fileURL)
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .secondsSince1970
                    loaded = try decoder.decode([HistorySample].self, from: data).sorted { $0.receivedAt < $1.receivedAt }
                } catch {
                    loadError = "歷史資料無法讀取，已保留目前記憶體中的資料。"
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard loadError == nil else {
                    self.errorMessage = loadError
                    completion?()
                    return
                }
                self.samples = loaded
                self.errorMessage = nil
                if self.purgeExpired(now: now) { self.persist() }
                completion?()
            }
        }
    }

    func load(now: Date = Date()) {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            samples = try decoder.decode([HistorySample].self, from: data)
                .sorted { $0.receivedAt < $1.receivedAt }
            errorMessage = nil
            if purgeExpired(now: now) {
                persist()
            }
        } catch {
            // Do not overwrite a corrupt file or clear valid in-memory samples.
            errorMessage = "歷史資料無法讀取，已保留目前記憶體中的資料。"
        }
    }

    @discardableResult
    func record(
        snapshot: UsageSnapshot,
        connectionState: ConnectionState,
        now: Date = Date(),
        force: Bool = false
    ) -> Bool {
        var changed = purgeExpired(now: now)
        let sample = HistorySample(snapshot: snapshot, connectionState: connectionState, receivedAt: now)

        if !force, let last = samples.last,
           isDuplicate(last, sample),
           now.timeIntervalSince(last.receivedAt) < minimumSampleInterval {
            if changed { persist() }
            return changed
        }

        samples.append(sample)
        samples.sort { $0.receivedAt < $1.receivedAt }
        changed = true
        persist()
        return changed
    }

    func samples(for range: HistoryRange, now: Date = Date()) -> [HistorySample] {
        let cutoff = now.addingTimeInterval(-range.duration)
        return samples.filter { $0.receivedAt >= cutoff }
    }

    func clear() {
        samples = []
        persist()
    }

    func flushPendingWrites() async {
        await PersistenceWriteCoordinator.shared.flush()
    }

    private func isDuplicate(_ lhs: HistorySample, _ rhs: HistorySample) -> Bool {
        lhs.limitId == rhs.limitId
            && lhs.primaryUsedPercent == rhs.primaryUsedPercent
            && lhs.secondaryUsedPercent == rhs.secondaryUsedPercent
            && lhs.primaryResetsAt == rhs.primaryResetsAt
            && lhs.secondaryResetsAt == rhs.secondaryResetsAt
            && lhs.connectionState == rhs.connectionState
    }

    private func purgeExpired(now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-retention)
        let retained = samples.filter { $0.receivedAt >= cutoff }
        guard retained.count != samples.count else { return false }
        samples = retained
        return true
    }

    private func persist() {
        if asynchronousPersistence {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .secondsSince1970
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(samples)
                Task { await PersistenceWriteCoordinator.shared.enqueue(url: fileURL, data: data, fileManager: fileManager) }
                errorMessage = nil
            } catch {
                errorMessage = "歷史資料無法保存：\(error.localizedDescription)"
            }
            return
        }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(samples)
            try data.write(to: fileURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            errorMessage = nil
        } catch {
            errorMessage = "歷史資料無法保存：\(error.localizedDescription)"
        }
    }
}

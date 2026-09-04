import Foundation

enum TerminationFlushPolicy {
    static let timeoutNanoseconds: UInt64 = 500_000_000
}

/// Serializes local persistence without blocking the main actor. Writes are
/// keyed by their destination, so a burst of model publications keeps only
/// the newest payload for each file while an earlier write is in flight.
actor PersistenceWriteCoordinator {
    static let shared = PersistenceWriteCoordinator()

    private struct Pending: Sendable {
        let url: URL
        let data: Data?
        let fileManager: PersistenceFileManager
    }

    private var pending: [String: Pending] = [:]
    private var active: Set<String> = []

    func enqueue(url: URL, data: Data?, fileManager: FileManager = .default) {
        let key = url.standardizedFileURL.path
        pending[key] = Pending(url: url, data: data, fileManager: PersistenceFileManager(fileManager))
        startIfNeeded(key: key)
    }

    /// Waits briefly for queued writes to finish. The timeout is deliberately
    /// bounded so app termination can never wait on disk indefinitely.
    func flush(timeoutNanoseconds: UInt64 = TerminationFlushPolicy.timeoutNanoseconds) async {
        let deadline = ContinuousClock.now.advanced(by: .nanoseconds(Int64(timeoutNanoseconds)))
        while !pending.isEmpty || !active.isEmpty {
            if ContinuousClock.now >= deadline { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func startIfNeeded(key: String) {
        guard !active.contains(key), let item = pending.removeValue(forKey: key) else { return }
        active.insert(key)
        Task.detached(priority: .utility) { [weak self] in
            item.fileManager.write(data: item.data, to: item.url)
            await self?.finish(key: key)
        }
    }

    private func finish(key: String) {
        active.remove(key)
        startIfNeeded(key: key)
    }
}

/// FileManager is not annotated Sendable, but each operation is independent
/// and the coordinator serializes writes per destination.
struct PersistenceFileManager: @unchecked Sendable {
    let fileManager: FileManager

    init(_ fileManager: FileManager = .default) { self.fileManager = fileManager }

    func write(data: Data?, to url: URL) {
        do {
            let directory = url.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard let data else {
                if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
                return
            }
            try data.write(to: url, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Persistence errors are intentionally fail-safe. The in-memory
            // snapshot remains authoritative until the next successful write.
        }
    }
}

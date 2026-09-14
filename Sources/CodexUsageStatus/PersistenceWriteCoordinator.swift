import Foundation

/// Coordinates the termination reply across AppKit's main-thread handshake
/// and the independent watchdog queue. AppKit can wait inside a nested
/// termination run loop, so a main-queue watchdog is not reliable here.
final class TerminationReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didReply = false
    private let reply: @Sendable () -> Void

    init(reply: @escaping @Sendable () -> Void) {
        self.reply = reply
    }

    @discardableResult
    func replyOnce() -> Bool {
        lock.lock()
        guard !didReply else {
            lock.unlock()
            return false
        }
        didReply = true
        lock.unlock()
        reply()
        return true
    }
}

enum TerminationFlushPolicy {
    static let timeoutNanoseconds: UInt64 = 500_000_000
    /// AppKit must receive a termination reply even if an unrelated shutdown
    /// callback or persistence task stalls. The replacement helper observes
    /// the process exit independently, so this watchdog fails closed after a
    /// short bounded grace period instead of holding the old bundle forever.
    static let replyTimeoutNanoseconds: UInt64 = 2_000_000_000
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

    /// Encodes on this actor instead of the caller's actor, then uses the
    /// same keyed newest-write-wins queue as other local persistence.
    func enqueueJSON<Value: Encodable & Sendable>(
        url: URL,
        value: Value,
        fileManager: FileManager = .default
    ) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        enqueue(url: url, data: data, fileManager: fileManager)
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

#if CODEX_USAGE_TESTING
    private static let testCounterLock = NSLock()
    nonisolated(unsafe) static var testDiskWriteCount = 0
    nonisolated(unsafe) static var testMainActorDiskWriteCount = 0

    static func resetTestCounters() {
        testCounterLock.lock()
        testDiskWriteCount = 0
        testMainActorDiskWriteCount = 0
        testCounterLock.unlock()
    }
#endif

    init(_ fileManager: FileManager = .default) { self.fileManager = fileManager }

    func write(data: Data?, to url: URL) {
#if CODEX_USAGE_TESTING
        Self.testCounterLock.lock()
        Self.testDiskWriteCount += 1
        if Thread.isMainThread { Self.testMainActorDiskWriteCount += 1 }
        Self.testCounterLock.unlock()
#endif
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

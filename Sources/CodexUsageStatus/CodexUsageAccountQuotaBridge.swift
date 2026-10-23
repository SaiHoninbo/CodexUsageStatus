import CoreFoundation
import Darwin
import Foundation

/// Temporary migration seam. PlanLoop Desktop is the long-term product owner;
/// this bridge keeps the existing CodexUsageStatus account session as the
/// only credential-bearing owner until acquisition moves into shared Core.
public enum CodexUsageAccountQuotaBridgePathError: Error, Equatable {
    case invalidProfileID
}

public enum CodexUsageAccountQuotaBridgePaths {
    public static let profileEnvironmentKey = "PLANLOOP_STAGING_PROFILE_ID"
    public static let socketFileName = "codex-account-quota-v1.sock"

    public static func production(
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        let supportDirectory = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let productSocket = canonicalExistingDirectory(supportDirectory)
            .appendingPathComponent("PlanLoop", isDirectory: true)
            .appendingPathComponent("CodexUsage", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent(socketFileName, isDirectory: false)
            .standardizedFileURL
        guard fitsUnixSocketPath(productSocket) else {
            return compactSocketPath(
                fileName: "p-\(getuid()).sock",
                temporaryDirectory: fileManager.temporaryDirectory
            )
        }
        return productSocket
    }

    public static func staging(
        profileID: UUID,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> URL {
        let canonicalTemporaryDirectory = canonicalExistingDirectory(temporaryDirectory)
        let profileSocket = canonicalTemporaryDirectory
            .appendingPathComponent("PlanLoop Desktop Staging", isDirectory: true)
            .appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("PlanLoop Desktop", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent(socketFileName, isDirectory: false)
            .standardizedFileURL
        if fitsUnixSocketPath(profileSocket) { return profileSocket }

        // Darwin's sockaddr_un.sun_path is short. When the complete profile
        // runtime path cannot fit, retain profile isolation in a compact socket
        // filename under the user's private temporary directory. The Desktop
        // profile records this exact URL for cleanup.
        let compactProfileID = profileID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return compactSocketPath(
            fileName: "s-\(compactProfileID).sock",
            temporaryDirectory: canonicalTemporaryDirectory
        )
    }

    /// The donor defaults to the production endpoint. A staging profile must
    /// be selected explicitly so it cannot accidentally publish into the
    /// production socket namespace.
    public static func selected(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportDirectory: URL? = nil,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        if let rawProfileID = environment[profileEnvironmentKey] {
            guard let profileID = UUID(uuidString: rawProfileID) else {
                throw CodexUsageAccountQuotaBridgePathError.invalidProfileID
            }
            return staging(profileID: profileID, temporaryDirectory: temporaryDirectory)
        }
        return production(applicationSupportDirectory: applicationSupportDirectory)
    }

    private static func compactSocketPath(fileName: String, temporaryDirectory: URL) -> URL {
        let privateTemporaryDirectory = canonicalExistingDirectory(temporaryDirectory)
            .appendingPathComponent("plq", isDirectory: true)
        let temporarySocket = privateTemporaryDirectory
            .appendingPathComponent(fileName, isDirectory: false)
            .standardizedFileURL
        if fitsUnixSocketPath(temporarySocket) { return temporarySocket }

        let shortPrivateDirectory = canonicalExistingDirectory(
            URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        ).appendingPathComponent("plq-\(getuid())", isDirectory: true)
        return shortPrivateDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    private static func fitsUnixSocketPath(_ url: URL) -> Bool {
        url.path.utf8.count + 1 <= MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    }

    private static func canonicalExistingDirectory(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        let result = path.withCString { pathPointer in
            resolved.withUnsafeMutableBufferPointer { buffer in
                realpath(pathPointer, buffer.baseAddress)
            }
        }
        guard result != nil, let terminator = resolved.firstIndex(of: 0) else {
            return url.standardizedFileURL
        }
        let canonicalPath = String(decoding: resolved[..<terminator].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: canonicalPath, isDirectory: true)
    }
}

public enum CodexUsageAccountQuotaBridgeError: Error, Equatable, Sendable {
    case invalidRequest
    case invalidResponse
    case unsupportedVersion
    case unsafeProjection
}

/// Exact, credential-free protocol V1 for the temporary account/quota seam.
public enum CodexUsageAccountQuotaBridgeCodec {
    public static let protocolVersion = 1
    public static let maximumFrameSize = 8 * 1024

    private static let requestKeys: Set<String> = ["operation", "protocolVersion"]
    private static let responseKeys: Set<String> = ["protocolVersion", "snapshot"]
    private static let snapshotKeys: Set<String> = [
        "availability",
        "observedAt",
        "accountDisplayIdentity",
        "plan",
        "appVersion",
        "rollingQuotaPercent",
        "quotaWindowLabel",
        "quotaRemainingDuration",
        "resetAt",
        "resetCredits",
        "resetCreditExpiry",
    ]

    private struct Response: Codable {
        let protocolVersion: Int
        let snapshot: CodexUsageAccountQuotaSnapshot
    }

    public static func snapshotRequest() -> Data {
        Data("{\"operation\":\"snapshot\",\"protocolVersion\":1}".utf8)
    }

    public static func isSnapshotRequest(_ data: Data) -> Bool {
        guard let object = try? jsonObject(data) as? [String: Any],
              Set(object.keys) == requestKeys,
              object["operation"] as? String == "snapshot",
              let version = object["protocolVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID() else {
            return false
        }
        return version.intValue == protocolVersion
    }

    public static func encodeSnapshotResponse(
        _ snapshot: CodexUsageAccountQuotaSnapshot
    ) throws -> Data {
        guard isSafe(snapshot) else { throw CodexUsageAccountQuotaBridgeError.unsafeProjection }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(Response(protocolVersion: protocolVersion, snapshot: snapshot))
    }

    public static func encodeFailure(_ code: String) -> Data {
        let safeCode = ["INVALID_REQUEST", "FRAME_TOO_LARGE", "BRIDGE_NOT_READY"].contains(code)
            ? code
            : "BRIDGE_NOT_READY"
        return Data("{\"errorCode\":\"\(safeCode)\",\"protocolVersion\":1}".utf8)
    }

    public static func decodeSnapshotResponse(_ data: Data) throws -> CodexUsageAccountQuotaSnapshot {
        guard let object = try? jsonObject(data) as? [String: Any],
              let version = object["protocolVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID() else {
            throw CodexUsageAccountQuotaBridgeError.invalidResponse
        }
        guard version.intValue == protocolVersion else {
            throw CodexUsageAccountQuotaBridgeError.unsupportedVersion
        }
        if object["errorCode"] != nil {
            guard Set(object.keys) == ["errorCode", "protocolVersion"],
                  object["errorCode"] is String else {
                throw CodexUsageAccountQuotaBridgeError.invalidResponse
            }
            throw CodexUsageAccountQuotaBridgeError.invalidResponse
        }
        guard Set(object.keys) == responseKeys,
              let snapshotObject = object["snapshot"] as? [String: Any],
              Set(snapshotObject.keys) == snapshotKeys else {
            throw CodexUsageAccountQuotaBridgeError.invalidResponse
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let response = try decoder.decode(Response.self, from: data)
        guard isSafe(response.snapshot) else {
            throw CodexUsageAccountQuotaBridgeError.unsafeProjection
        }
        return response.snapshot
    }

    private static func jsonObject(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private static func isSafe(_ snapshot: CodexUsageAccountQuotaSnapshot) -> Bool {
        guard snapshot.rollingQuotaPercent.map({ (0...100).contains($0) }) ?? true,
              snapshot.resetCredits.map({ $0 >= 0 }) ?? true,
              snapshot.accountDisplayIdentity.map({ $0.utf8.count <= 320 }) ?? true,
              snapshot.plan.map({ $0.utf8.count <= 128 }) ?? true,
              snapshot.appVersion.map({ $0.utf8.count <= 64 }) ?? true,
              snapshot.quotaWindowLabel.map({ $0.utf8.count <= 96 }) ?? true,
              snapshot.quotaRemainingDuration.map({ $0.utf8.count <= 96 }) ?? true else {
            return false
        }
        if snapshot.availability == .available, snapshot.observedAt == nil {
            return false
        }
        return true
    }
}

/// Producer endpoint hosted by the existing account-session owner.
@MainActor
public final class CodexUsageAccountQuotaBridgeServer {
    public let socketURL: URL
    private let transport: SecureUnixRequestResponseTransport
    private weak var source: (any CodexUsageAccountQuotaProjectionSource)?

    public init(socketURL: URL, source: any CodexUsageAccountQuotaProjectionSource) {
        self.socketURL = socketURL
        self.source = source
        self.transport = SecureUnixRequestResponseTransport(
            path: socketURL,
            maximumFrameSize: CodexUsageAccountQuotaBridgeCodec.maximumFrameSize
        )
    }

    public func start() throws {
        try transport.start(
            handler: { [weak self] data in
                await self?.handle(data) ?? CodexUsageAccountQuotaBridgeCodec.encodeFailure("BRIDGE_NOT_READY")
            },
            failureResponse: { failure in
                switch failure {
                case .frameTooLarge:
                    CodexUsageAccountQuotaBridgeCodec.encodeFailure("FRAME_TOO_LARGE")
                case .handlerUnavailable:
                    CodexUsageAccountQuotaBridgeCodec.encodeFailure("BRIDGE_NOT_READY")
                }
            }
        )
    }

    public func stop() {
        transport.stop()
    }

    private func handle(_ data: Data) -> Data {
        guard CodexUsageAccountQuotaBridgeCodec.isSnapshotRequest(data) else {
            return CodexUsageAccountQuotaBridgeCodec.encodeFailure("INVALID_REQUEST")
        }
        guard let source else {
            return (try? CodexUsageAccountQuotaBridgeCodec.encodeSnapshotResponse(.notProven))
                ?? CodexUsageAccountQuotaBridgeCodec.encodeFailure("BRIDGE_NOT_READY")
        }
        return (try? CodexUsageAccountQuotaBridgeCodec.encodeSnapshotResponse(source.accountQuotaSnapshot))
            ?? CodexUsageAccountQuotaBridgeCodec.encodeFailure("BRIDGE_NOT_READY")
    }
}

/// PlanLoop's read-only reconnecting consumer. It polls the local producer and
/// retains the last observation timestamp when the donor is unavailable.
@MainActor
public final class CodexUsageAccountQuotaBridgeClient: CodexUsageAccountQuotaProjectionSource,
    CodexUsageAccountQuotaProjectionLifecycle {
    public let socketURL: URL
    public private(set) var accountQuotaSnapshot: CodexUsageAccountQuotaSnapshot

    private let refreshInterval: TimeInterval
    private var timer: Timer?
    private var inFlight = false
    private var stopped = false
    private var lastKnownSnapshot: CodexUsageAccountQuotaSnapshot?

    public init(
        socketURL: URL,
        refreshInterval: TimeInterval = 3,
        automaticallyRefresh: Bool = true
    ) {
        self.socketURL = socketURL
        self.refreshInterval = max(1, refreshInterval)
        self.accountQuotaSnapshot = .notProven
        if automaticallyRefresh { start() }
    }

    public func start() {
        guard !stopped, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshNow() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        Task { @MainActor [weak self] in await self?.refreshNow() }
    }

    public func refreshNow() async {
        guard !stopped, !inFlight else { return }
        inFlight = true
        let socketURL = self.socketURL
        let received = await Task.detached(priority: .utility) { () -> CodexUsageAccountQuotaSnapshot? in
            do {
                let response = try SecureUnixRequestResponseTransport.roundTrip(
                    request: CodexUsageAccountQuotaBridgeCodec.snapshotRequest(),
                    to: socketURL,
                    maximumFrameSize: CodexUsageAccountQuotaBridgeCodec.maximumFrameSize,
                    timeout: 1
                )
                return try CodexUsageAccountQuotaBridgeCodec.decodeSnapshotResponse(response)
            } catch {
                return nil
            }
        }.value
        inFlight = false
        guard !stopped else { return }
        if let received {
            apply(received)
        } else {
            accountQuotaSnapshot = unavailablePreservingLastObservation()
        }
    }

    public func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
    }

    private func apply(_ received: CodexUsageAccountQuotaSnapshot) {
        switch received.availability {
        case .available:
            guard received.observedAt != nil else {
                accountQuotaSnapshot = unavailablePreservingLastObservation()
                return
            }
            lastKnownSnapshot = received
            accountQuotaSnapshot = received
        case .unavailable:
            if received.observedAt != nil { lastKnownSnapshot = received }
            if let lastKnownSnapshot {
                accountQuotaSnapshot = withAvailability(.unavailable, basedOn: lastKnownSnapshot)
            } else {
                accountQuotaSnapshot = .notProven
            }
        case .notProven:
            if let lastKnownSnapshot {
                accountQuotaSnapshot = withAvailability(.unavailable, basedOn: lastKnownSnapshot)
            } else {
                accountQuotaSnapshot = received
            }
        case .checking:
            accountQuotaSnapshot = withAvailability(.checking, basedOn: lastKnownSnapshot ?? received)
        }
    }

    private func unavailablePreservingLastObservation() -> CodexUsageAccountQuotaSnapshot {
        guard let lastKnownSnapshot else { return .notProven }
        return withAvailability(.unavailable, basedOn: lastKnownSnapshot)
    }

    private func withAvailability(
        _ availability: CodexUsageAccountQuotaAvailability,
        basedOn snapshot: CodexUsageAccountQuotaSnapshot
    ) -> CodexUsageAccountQuotaSnapshot {
        CodexUsageAccountQuotaSnapshot(
            availability: availability,
            observedAt: snapshot.observedAt,
            accountDisplayIdentity: snapshot.accountDisplayIdentity,
            plan: snapshot.plan,
            appVersion: snapshot.appVersion,
            rollingQuotaPercent: snapshot.rollingQuotaPercent,
            quotaWindowLabel: snapshot.quotaWindowLabel,
            quotaRemainingDuration: snapshot.quotaRemainingDuration,
            resetAt: snapshot.resetAt,
            resetCredits: snapshot.resetCredits,
            resetCreditExpiry: snapshot.resetCreditExpiry
        )
    }
}

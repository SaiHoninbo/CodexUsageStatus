import Darwin
import Foundation

public enum SecureUnixRequestResponseTransportFailure: Sendable {
    case frameTooLarge
    case handlerUnavailable
}

public enum SecureUnixRequestResponseTransportError: Error {
    case invalidPath
    case insecureParent
    case existingPathNotOwned
    case existingPathNotSocket
    case alreadyRunning
    case staleSocketUncertain
    case peerUserMismatch
    case requestTooLarge
    case responseTooLarge
    case invalidFrame
    case timedOut
    case system(Int32)
}

/// Protocol-neutral newline-framed request/response transport over a protected
/// Unix domain socket.
///
/// Local threat model V1: socket and parent permissions restrict access across
/// macOS users. They do not authenticate a process against another process
/// running as the same UID. Request binding fields are protocol authority checks,
/// not operating-system process identity proof.
public final class SecureUnixRequestResponseTransport: @unchecked Sendable {
    public static let defaultMaximumFrameSize = 64 * 1024

    public let path: URL
    private let maximumFrameSize: Int
    private let lock = NSLock()
    private let queue: DispatchQueue
    private var descriptor: Int32 = -1
    private var running = false
    private var handler: (@Sendable (Data) async -> Data)?
    private var failureResponse: (@Sendable (SecureUnixRequestResponseTransportFailure) -> Data)?

    public init(path: URL, maximumFrameSize: Int = SecureUnixRequestResponseTransport.defaultMaximumFrameSize) {
        precondition(maximumFrameSize > 0)
        self.path = path
        self.maximumFrameSize = maximumFrameSize
        self.queue = DispatchQueue(label: "com.planloop.desktop.secure-unix-request-response", qos: .userInitiated)
    }

    public func start(
        handler: @escaping @Sendable (Data) async -> Data,
        failureResponse: @escaping @Sendable (SecureUnixRequestResponseTransportFailure) -> Data,
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { throw SecureUnixRequestResponseTransportError.alreadyRunning }
        try prepareParent()
        try prepareExistingSocket()

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw SecureUnixRequestResponseTransportError.invalidPath
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: pathBytes)
        }

        let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw SecureUnixRequestResponseTransportError.system(errno) }
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            close(socketDescriptor)
            throw SecureUnixRequestResponseTransportError.system(code)
        }
        guard listen(socketDescriptor, 8) == 0 else {
            let code = errno
            close(socketDescriptor)
            unlink(path.path)
            throw SecureUnixRequestResponseTransportError.system(code)
        }
        guard chmod(path.path, mode_t(0o600)) == 0 else {
            let code = errno
            close(socketDescriptor)
            unlink(path.path)
            throw SecureUnixRequestResponseTransportError.system(code)
        }
        self.descriptor = socketDescriptor
        self.handler = handler
        self.failureResponse = failureResponse
        self.running = true
        queue.async { [weak self] in self?.acceptLoop() }
    }

    public func stop() {
        lock.lock()
        let socketDescriptor = descriptor
        descriptor = -1
        running = false
        handler = nil
        lock.unlock()

        if socketDescriptor >= 0 {
            shutdown(socketDescriptor, SHUT_RDWR)
            close(socketDescriptor)
        }
        removeSocketIfOwned()
    }

    public func fileMode() throws -> UInt16 {
        var info = stat()
        guard lstat(path.path, &info) == 0 else {
            throw SecureUnixRequestResponseTransportError.system(errno)
        }
        return UInt16(info.st_mode & 0o777)
    }

    public func isOwnedByCurrentUser() throws -> Bool {
        var info = stat()
        guard lstat(path.path, &info) == 0 else {
            throw SecureUnixRequestResponseTransportError.system(errno)
        }
        return info.st_uid == getuid()
    }

    private func prepareParent() throws {
        let parentPath = (path.path as NSString).deletingLastPathComponent
        let parent = URL(fileURLWithPath: parentPath, isDirectory: true)
        try rejectSymlinkComponents(in: parent)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)],
        )
        try rejectSymlinkComponents(in: parent)
        var info = stat()
        guard lstat(parent.path, &info) == 0 else {
            throw SecureUnixRequestResponseTransportError.system(errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
            throw SecureUnixRequestResponseTransportError.insecureParent
        }
        guard chmod(parent.path, mode_t(0o700)) == 0 else {
            throw SecureUnixRequestResponseTransportError.system(errno)
        }
        var securedInfo = stat()
        guard lstat(parent.path, &securedInfo) == 0,
              (securedInfo.st_mode & S_IFMT) == S_IFDIR,
              securedInfo.st_uid == getuid(),
              (securedInfo.st_mode & 0o077) == 0 else {
            throw SecureUnixRequestResponseTransportError.insecureParent
        }
    }

    private func rejectSymlinkComponents(in directory: URL) throws {
        guard let standardizedPath = Self.lexicallyStandardizedAbsolutePath(directory.path) else {
            throw SecureUnixRequestResponseTransportError.insecureParent
        }
        var currentPath = ""
        for component in standardizedPath.split(separator: "/", omittingEmptySubsequences: true) {
            currentPath += "/" + component
            var info = stat()
            guard lstat(currentPath, &info) == 0 else {
                guard errno == ENOENT else {
                    throw SecureUnixRequestResponseTransportError.system(errno)
                }
                return
            }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                throw SecureUnixRequestResponseTransportError.insecureParent
            }
        }
    }

    private static func lexicallyStandardizedAbsolutePath(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(String(component))
            }
        }
        return "/" + components.joined(separator: "/")
    }

    private func prepareExistingSocket() throws {
        var info = stat()
        guard lstat(path.path, &info) == 0 else {
            guard errno == ENOENT else {
                throw SecureUnixRequestResponseTransportError.system(errno)
            }
            return
        }
        guard info.st_uid == getuid() else {
            throw SecureUnixRequestResponseTransportError.existingPathNotOwned
        }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else {
            throw SecureUnixRequestResponseTransportError.existingPathNotSocket
        }
        switch probeExistingSocket() {
        case .active:
            throw SecureUnixRequestResponseTransportError.alreadyRunning
        case .stale:
            guard unlink(path.path) == 0 else {
                throw SecureUnixRequestResponseTransportError.system(errno)
            }
        case .uncertain:
            throw SecureUnixRequestResponseTransportError.staleSocketUncertain
        }
    }

    private enum ExistingSocketProbe {
        case active
        case stale
        case uncertain
    }

    private func probeExistingSocket() -> ExistingSocketProbe {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return .uncertain }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: pathBytes)
        }
        let probeDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probeDescriptor >= 0 else { return .uncertain }
        defer { close(probeDescriptor) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(probeDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return .active }
        if errno == ECONNREFUSED || errno == ENOENT { return .stale }
        return .uncertain
    }

    private func acceptLoop() {
        while isRunning() {
            let client = accept(currentDescriptor(), nil, nil)
            guard client >= 0 else {
                if isRunning() { continue }
                return
            }
            handle(client)
        }
    }

    private func handle(_ client: Int32) {
        var peerUser: uid_t = 0
        var peerGroup: gid_t = 0
        guard getpeereid(client, &peerUser, &peerGroup) == 0, peerUser == getuid() else {
            shutdown(client, SHUT_RDWR)
            close(client)
            return
        }

        var noSigPipe: Int32 = 1
        let socketOptionResult = withUnsafePointer(to: &noSigPipe) {
            setsockopt(
                client,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                $0,
                socklen_t(MemoryLayout<Int32>.size),
            )
        }
        guard socketOptionResult == 0 else {
            shutdown(client, SHUT_RDWR)
            close(client)
            return
        }
        defer { shutdown(client, SHUT_RDWR); close(client) }

        var data = Data()
        var byte: UInt8 = 0
        while data.count < maximumFrameSize {
            let count = read(client, &byte, 1)
            if count <= 0 { break }
            if byte == 0x0A { break }
            data.append(byte)
        }
        guard data.count < maximumFrameSize else {
            writeResponse(failureResponse(for: .frameTooLarge), to: client)
            return
        }

        let responseBox = SocketResponseBox()
        let signal = DispatchSemaphore(value: 0)
        let handler = currentHandler()
        let failureResponse = currentFailureResponse()
        Task {
            if let handler {
                responseBox.set(await handler(data))
            } else if let failureResponse {
                responseBox.set(failureResponse(.handlerUnavailable))
            }
            signal.signal()
        }
        signal.wait()
        writeResponse(responseBox.get(), to: client)
    }

    private func failureResponse(for failure: SecureUnixRequestResponseTransportFailure) -> Data {
        currentFailureResponse()?(failure) ?? Data()
    }

    private func writeResponse(_ payload: Data, to descriptor: Int32) {
        var data = payload
        if data.last != 0x0A { data.append(0x0A) }
        writeAll(data, to: descriptor)
    }

    private func writeAll(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, baseAddress.advanced(by: offset), buffer.count - offset)
                if count <= 0 {
                    if errno == EPIPE { return }
                    return
                }
                offset += count
            }
        }
    }

    private func currentDescriptor() -> Int32 {
        lock.lock(); defer { lock.unlock() }
        return descriptor
    }

    private func currentHandler() -> (@Sendable (Data) async -> Data)? {
        lock.lock(); defer { lock.unlock() }
        return handler
    }

    private func currentFailureResponse() -> (@Sendable (SecureUnixRequestResponseTransportFailure) -> Data)? {
        lock.lock(); defer { lock.unlock() }
        return failureResponse
    }

    private func isRunning() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    private func removeSocketIfOwned() {
        var info = stat()
        guard lstat(path.path, &info) == 0,
              info.st_uid == getuid(),
              (info.st_mode & S_IFMT) == S_IFSOCK else { return }
        _ = unlink(path.path)
    }

    /// Performs one bounded newline-framed request against an existing secure
    /// socket. The parent chain, socket owner/mode, and peer uid are checked
    /// before a response is accepted.
    public static func roundTrip(
        request: Data,
        to path: URL,
        maximumFrameSize: Int = defaultMaximumFrameSize,
        timeout: TimeInterval = 2
    ) throws -> Data {
        guard maximumFrameSize > 0, timeout > 0 else {
            throw SecureUnixRequestResponseTransportError.invalidFrame
        }
        guard request.count < maximumFrameSize, !request.contains(0x0A) else {
            throw SecureUnixRequestResponseTransportError.requestTooLarge
        }

        guard let normalizedSocketPath = lexicallyStandardizedAbsolutePath(path.path) else {
            throw SecureUnixRequestResponseTransportError.invalidPath
        }
        try validateClientSocketPath(normalizedSocketPath)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(normalizedSocketPath.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw SecureUnixRequestResponseTransportError.invalidPath
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: pathBytes)
        }

        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        guard client >= 0 else { throw SecureUnixRequestResponseTransportError.system(errno) }
        defer { shutdown(client, SHUT_RDWR); close(client) }

        var noSigPipe: Int32 = 1
        guard setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw SecureUnixRequestResponseTransportError.system(errno)
        }
        var socketTimeout = timeval(
            tv_sec: Int(timeout),
            tv_usec: suseconds_t((timeout - floor(timeout)) * 1_000_000)
        )
        guard setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &socketTimeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &socketTimeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw SecureUnixRequestResponseTransportError.system(errno)
        }

        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT {
                throw SecureUnixRequestResponseTransportError.timedOut
            }
            throw SecureUnixRequestResponseTransportError.system(errno)
        }

        var peerUser: uid_t = 0
        var peerGroup: gid_t = 0
        guard getpeereid(client, &peerUser, &peerGroup) == 0, peerUser == getuid() else {
            throw SecureUnixRequestResponseTransportError.peerUserMismatch
        }

        var framedRequest = request
        framedRequest.append(0x0A)
        try Self.writeAll(framedRequest, to: client)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while response.count < maximumFrameSize {
            let count = recv(client, &buffer, buffer.count, 0)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT {
                    throw SecureUnixRequestResponseTransportError.timedOut
                }
                throw SecureUnixRequestResponseTransportError.system(errno)
            }
            if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                response.append(contentsOf: buffer[..<newline])
                guard response.count < maximumFrameSize else {
                    throw SecureUnixRequestResponseTransportError.responseTooLarge
                }
                return response
            }
            response.append(contentsOf: buffer[..<count])
        }
        guard response.count < maximumFrameSize else {
            throw SecureUnixRequestResponseTransportError.responseTooLarge
        }
        guard !response.isEmpty else {
            throw SecureUnixRequestResponseTransportError.invalidFrame
        }
        return response
    }

    private static func validateClientSocketPath(_ path: String) throws {
        let parentPath = (path as NSString).deletingLastPathComponent
        try rejectSymlinkComponents(in: parentPath)

        var parentInfo = stat()
        guard lstat(parentPath, &parentInfo) == 0 else {
            throw SecureUnixRequestResponseTransportError.system(errno)
        }
        guard (parentInfo.st_mode & S_IFMT) == S_IFDIR,
              parentInfo.st_uid == getuid(),
              (parentInfo.st_mode & 0o077) == 0 else {
            throw SecureUnixRequestResponseTransportError.insecureParent
        }

        var socketInfo = stat()
        guard lstat(path, &socketInfo) == 0 else {
            throw SecureUnixRequestResponseTransportError.system(errno)
        }
        guard (socketInfo.st_mode & S_IFMT) == S_IFSOCK else {
            throw SecureUnixRequestResponseTransportError.existingPathNotSocket
        }
        guard socketInfo.st_uid == getuid() else {
            throw SecureUnixRequestResponseTransportError.existingPathNotOwned
        }
        guard (socketInfo.st_mode & 0o777) == 0o600 else {
            throw SecureUnixRequestResponseTransportError.insecureParent
        }
    }

    private static func rejectSymlinkComponents(in directoryPath: String) throws {
        guard let standardizedPath = lexicallyStandardizedAbsolutePath(directoryPath) else {
            throw SecureUnixRequestResponseTransportError.insecureParent
        }
        var currentPath = ""
        for component in standardizedPath.split(separator: "/", omittingEmptySubsequences: true) {
            currentPath += "/" + component
            var info = stat()
            guard lstat(currentPath, &info) == 0 else {
                throw SecureUnixRequestResponseTransportError.system(errno)
            }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                throw SecureUnixRequestResponseTransportError.insecureParent
            }
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = send(descriptor, baseAddress.advanced(by: offset), buffer.count - offset, 0)
                guard count > 0 else {
                    if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT {
                        throw SecureUnixRequestResponseTransportError.timedOut
                    }
                    throw SecureUnixRequestResponseTransportError.system(errno)
                }
                offset += count
            }
        }
    }
}

private final class SocketResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()

    func set(_ data: Data) { lock.lock(); value = data; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return value }
}

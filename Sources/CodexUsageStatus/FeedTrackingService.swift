import Foundation
import Darwin

struct FeedHTTPResponse {
    let data: Data
    let statusCode: Int
    let headers: [AnyHashable: Any]
}

enum FeedTransportError: Error, Equatable, CustomStringConvertible {
    case invalidURL(String)
    case redirectRejected
    case httpStatus(Int)
    case bodyTooLarge
    case timeout
    case cancelled
    case dnsPreflightFailed
    case underlying(String)
    var description: String {
        switch self { case .invalidURL(let s): return s; case .redirectRejected: return "Feed redirect 已拒絕"; case .httpStatus(let code): return "Feed HTTP \(code)"; case .bodyTooLarge: return "Feed 回應超過 2 MiB"; case .timeout: return "Feed 連線逾時"; case .cancelled: return "Feed 請求已取消"; case .dnsPreflightFailed: return "Feed 主機 DNS 驗證失敗"; case .underlying(let s): return s }
    }
}

protocol FeedTransportTask { func cancel() }
protocol FeedHTTPTransporting {
    @discardableResult func fetch(request: URLRequest, completion: @escaping (Result<FeedHTTPResponse, Error>) -> Void) -> FeedTransportTask
}
protocol FeedNotificationSubmitting: AnyObject {
    func send(post: FeedPost, prediction: ResetPrediction?, postCount: Int, completion: @escaping (Result<Void, Error>) -> Void)
}

final class FeedHTTPTransport: NSObject, FeedHTTPTransporting, URLSessionDataDelegate, URLSessionTaskDelegate {
    private final class RunningTask: NSObject {
        let completion: (Result<FeedHTTPResponse, Error>) -> Void
        var data = Data(); var response: HTTPURLResponse?; var finished = false
        init(completion: @escaping (Result<FeedHTTPResponse, Error>) -> Void) { self.completion = completion }
    }
    private final class Handle: FeedTransportTask { weak var task: URLSessionDataTask?; func cancel() { task?.cancel() } }
    private var session: URLSession!
    private let preflightValidator: (URL) -> Bool
    private var running: [Int: RunningTask] = [:]
    private let queue = DispatchQueue(label: "CodexUsageStatus.FeedHTTPTransport")
    static let maxBodyBytes = 2 * 1024 * 1024
    static let timeout: TimeInterval = 20

    override convenience init() {
        self.init(configuration: .ephemeral, preflight: FeedHTTPTransport.preflight)
    }

    init(configuration: URLSessionConfiguration, preflight: @escaping (URL) -> Bool = FeedHTTPTransport.preflight) {
        self.preflightValidator = preflight
        let configuration = configuration
        configuration.timeoutIntervalForRequest = Self.timeout; configuration.timeoutIntervalForResource = Self.timeout
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func fetch(request: URLRequest, completion: @escaping (Result<FeedHTTPResponse, Error>) -> Void) -> FeedTransportTask {
        guard let url = request.url, FeedURLPolicy.validate(url).isSuccess else { completion(.failure(FeedTransportError.invalidURL("Feed URL 不符合安全政策"))); return Handle() }
        guard preflightValidator(url) else { completion(.failure(FeedTransportError.dnsPreflightFailed)); return Handle() }
        let task = session.dataTask(with: request); let state = RunningTask(completion: completion); let handle = Handle(); handle.task = task
        queue.sync { running[task.taskIdentifier] = state }; task.resume(); return handle
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, FeedURLPolicy.validate(url).isSuccess, preflightValidator(url) else { completionHandler(nil); finish(task, result: .failure(FeedTransportError.redirectRejected)); return }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, let state = queue.sync(execute: { running[dataTask.taskIdentifier] }) else { completionHandler(.cancel); return }
        state.response = http
        if let length = http.value(forHTTPHeaderField: "Content-Length"), let count = Int(length), count > Self.maxBodyBytes { completionHandler(.cancel); finish(dataTask, result: .failure(FeedTransportError.bodyTooLarge)); return }
        completionHandler(http.statusCode >= 200 && http.statusCode < 300 ? .allow : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let state = queue.sync(execute: { running[dataTask.taskIdentifier] }), !state.finished else { return }
        state.data.append(data)
        if state.data.count > Self.maxBodyBytes { dataTask.cancel(); finish(dataTask, result: .failure(FeedTransportError.bodyTooLarge)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let state = queue.sync(execute: { running[task.taskIdentifier] }), !state.finished else { return }
        if let nsError = error as NSError?, nsError.code == NSURLErrorCancelled { finish(task, result: .failure(FeedTransportError.cancelled)); return }
        if let nsError = error as NSError?, nsError.code == NSURLErrorTimedOut { finish(task, result: .failure(FeedTransportError.timeout)); return }
        if let error { finish(task, result: .failure(error)); return }
        guard let response = state.response else { finish(task, result: .failure(FeedTransportError.underlying("Feed 沒有回應"))); return }
        guard (200..<300).contains(response.statusCode) || response.statusCode == 304 else { finish(task, result: .failure(FeedTransportError.httpStatus(response.statusCode))); return }
        finish(task, result: .success(FeedHTTPResponse(data: state.data, statusCode: response.statusCode, headers: response.allHeaderFields)))
    }

    private func finish(_ task: URLSessionTask, result: Result<FeedHTTPResponse, Error>) {
        var completion: ((Result<FeedHTTPResponse, Error>) -> Void)?
        queue.sync { if let state = running.removeValue(forKey: task.taskIdentifier), !state.finished { state.finished = true; completion = state.completion } }
        completion?(result)
    }

    static func preflight(_ url: URL) -> Bool {
        guard FeedURLPolicy.validate(url).isSuccess, let host = url.host else { return false }
        if IPv4Literal(host)?.isBlocked == true || IPv6Literal(host)?.isBlocked == true { return false }
        guard let addresses = resolve(host: host), !addresses.isEmpty else { return false }
        return addresses.allSatisfy { !isBlocked(address: $0) }
    }

    private static func resolve(host: String) -> [String]? {
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }
        var output: [String] = []; var pointer: UnsafeMutablePointer<addrinfo>? = first
        while let info = pointer { if info.pointee.ai_family == AF_INET || info.pointee.ai_family == AF_INET6 { var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST)); getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST); output.append(String(cString: hostBuffer)) }; pointer = info.pointee.ai_next }
        return output
    }
    private static func isBlocked(address: String) -> Bool { IPv4Literal(address)?.isBlocked == true || IPv6Literal(address)?.isBlocked == true }
}

private struct IPv4Literal { let octets: [Int]; init?(_ s: String) { let p = s.split(separator: "."); let n = p.compactMap { Int($0) }; guard p.count == 4, n.count == 4 else { return nil }; octets = n }; var isBlocked: Bool { let a = octets[0], b = octets[1]; return a == 127 || a == 10 || a == 0 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 169 && b == 254) } }
private struct IPv6Literal { let text: String; init?(_ s: String) { guard s.contains(":"), s.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else { return nil }; text = s.lowercased() }; var isBlocked: Bool { text.hasPrefix("::ffff:") || text == "::1" || text == "::" || text.hasPrefix("fe8") || text.hasPrefix("fe9") || text.hasPrefix("fea") || text.hasPrefix("feb") || text.hasPrefix("fc") || text.hasPrefix("fd") } }

extension Result where Failure == FeedURLPolicyError {
    fileprivate var isSuccess: Bool { if case .success = self { return true }; return false }
}

final class FeedTrackingService {
    private let store: FeedTrackingStore
    private let transport: FeedHTTPTransporting
    private let now: () -> Date
    private let systemTimeZone: TimeZone
    private var timer: DispatchSourceTimer?
    private var request: FeedTransportTask?
    private var generation = UUID()
    private var inFlightNotificationIDs = Set<String>()
    private(set) var state: FeedTrackingState = .idle
    private(set) var errorMessage: String?
    var onStateChange: ((FeedTrackingState, String?) -> Void)?
    var onEventsChange: (([AnnouncementEvent]) -> Void)?
    var notificationService: (any FeedNotificationSubmitting)?
    var notificationsAllowed: () -> Bool = { true }
    var enabled = false
    var cadence: FeedPollingCadence = .hour

    init(store: FeedTrackingStore = FeedTrackingStore(), transport: FeedHTTPTransporting = FeedHTTPTransport(), now: @escaping () -> Date = Date.init, systemTimeZone: TimeZone = .current) { self.store = store; self.transport = transport; self.now = now; self.systemTimeZone = systemTimeZone; if let message = store.errorMessage { self.state = .error(message); self.errorMessage = message } }
    var envelope: FeedTrackingEnvelope { store.envelope }
    var events: [AnnouncementEvent] { FeedAnnouncementPolicy.events(posts: store.envelope.posts, predictions: store.envelope.predictionsByPostID) }

    func start(enabled: Bool, cadence: FeedPollingCadence, feedURL: URL?) {
        stop(); self.enabled = enabled; self.cadence = cadence
        let configuredURL = feedURL.flatMap { FeedURLPolicy.validate($0).isSuccess ? $0 : nil }
        store.configure(feedURL: configuredURL)
        guard enabled else { onEventsChange?([]); publish(.disabled, nil); return }
        guard configuredURL != nil else { onEventsChange?([]); publish(.notConfigured, "請先設定有效的 HTTPS Feed URL"); return }
        onEventsChange?(events); fetch()
        if cadence != .manual { let source = DispatchSource.makeTimerSource(); source.schedule(deadline: .now() + .seconds(cadence.rawValue), repeating: .seconds(cadence.rawValue)); source.setEventHandler { [weak self] in self?.fetch() }; source.resume(); timer = source }
    }
    func stop() { generation = UUID(); request?.cancel(); request = nil; timer?.cancel(); timer = nil; if enabled { publish(.idle, nil) } }
    func fetch() {
        guard enabled, let url = store.envelope.configuredFeedURL else { return }
        request?.cancel()
        generation = UUID()
        var request = URLRequest(url: url); request.timeoutInterval = FeedHTTPTransport.timeout; request.setValue("application/rss+xml, application/atom+xml, application/xml", forHTTPHeaderField: "Accept")
        if let etag = store.envelope.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let modified = store.envelope.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        let token = generation; publish(.fetching, nil)
        self.request = transport.fetch(request: request) { [weak self] result in
            guard let self, self.generation == token else { return }
            switch result { case .failure(let error): let message = self.safeMessage(error, url: url); self.publish(.error(message), message); case .success(let response): self.handle(response, url: url) }
        }
    }
    func corroborate(officialResetDates: [Date]) {
        guard enabled else { return }
        for post in store.envelope.posts {
            guard let prediction = store.envelope.predictionsByPostID[post.id] else { continue }
            store.updatePrediction(postID: post.id, prediction: ResetPredictionPolicy.corroborated(prediction, officialResetDates: officialResetDates))
        }
        try? store.save(); onEventsChange?(events)
    }
    private func handle(_ response: FeedHTTPResponse, url: URL) {
        if response.statusCode == 304 {
            let etag = response.headers.first(where: { String(describing: $0.key).lowercased() == "etag" })?.value as? String ?? store.envelope.etag
            let modified = response.headers.first(where: { String(describing: $0.key).lowercased() == "last-modified" })?.value as? String ?? store.envelope.lastModified
            store.replaceMetadata(title: store.envelope.feedTitle, link: store.envelope.feedLink, etag: etag, lastModified: modified, successfulAt: now())
            try? store.save(); publish(.notModified, nil); onEventsChange?(events); return
        }
        do {
            let ingestionDate = now()
            let parsed = try FeedParser.parse(data: response.data, feedURL: url, firstSeenAt: ingestionDate)
            let calendar = Calendar(identifier: .gregorian)
            let wasEmpty = store.envelope.posts.isEmpty
            var changedIDs = Set<String>()
            for post in parsed.posts {
                if let old = store.post(id: post.id), old.normalizedEffectiveContent == post.normalizedEffectiveContent { continue }
                if store.upsert(post: post, prediction: ResetPredictionPolicy.predict(post: post, now: ingestionDate, systemTimeZone: systemTimeZone, calendar: calendar)) { changedIDs.insert(post.id) }
            }
            let headers = response.headers
            let etag = headers.first(where: { String(describing: $0.key).lowercased() == "etag" })?.value as? String
            let modified = headers.first(where: { String(describing: $0.key).lowercased() == "last-modified" })?.value as? String
            store.replaceMetadata(title: parsed.title, link: parsed.link, etag: etag ?? store.envelope.etag, lastModified: modified ?? store.envelope.lastModified, successfulAt: ingestionDate); store.prune(now: ingestionDate); try store.save(); publish(.loaded, nil); onEventsChange?(events)
            if !wasEmpty, let notificationService, notificationsAllowed() {
                for post in parsed.posts where changedIDs.contains(post.id) && !store.hasNotified(postID: post.id) && !inFlightNotificationIDs.contains(post.id) {
                    inFlightNotificationIDs.insert(post.id)
                    notificationService.send(post: post, prediction: store.envelope.predictionsByPostID[post.id], postCount: 1) { [weak self] (result: Result<Void, Error>) in
                        guard let self else { return }
                        self.inFlightNotificationIDs.remove(post.id)
                        guard case .success = result, self.enabled, self.store.envelope.configuredFeedURL == url else { return }
                        self.store.markNotified(postID: post.id); try? self.store.save()
                    }
                }
            }
        } catch { let message = safeMessage(error, url: url); publish(.error(message), message) }
    }
    private func safeMessage(_ error: Error, url: URL) -> String {
        let host = url.host ?? "unknown host"
        if let feedError = error as? FeedTransportError { return "\(feedError.description)（\(url.scheme ?? "https")://\(host)）" }
        return "Feed 更新失敗（\(url.scheme ?? "https")://\(host)）"
    }
    private func publish(_ newState: FeedTrackingState, _ message: String?) { state = newState; errorMessage = message; onStateChange?(newState, message) }
}

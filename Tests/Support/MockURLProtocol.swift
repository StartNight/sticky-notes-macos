import Foundation

/// Intercepts every request made through URLSession.shared (registered globally in setUp),
/// so SyncEngine's Microsoft Graph calls are served locally. No real network traffic.
final class MockURLProtocol: URLProtocol {
    struct Recorded {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data?
    }

    enum Reply {
        case http(status: Int, json: Any?)
        case failure(URLError.Code)
    }

    private var stopped = false
    static let lock = NSLock()

    nonisolated(unsafe) private static var _responseDelay: TimeInterval = 0
    nonisolated(unsafe) private static var _holdMethods: Set<String> = []
    nonisolated(unsafe) private static var _holdPredicate: ((URLRequest) -> Bool)?
    nonisolated(unsafe) private static var _cancellationCount = 0
    nonisolated(unsafe) private static var _handler: ((URLRequest) -> Reply)?
    nonisolated(unsafe) private static var _held: [(MockURLProtocol, Reply)] = []
    nonisolated(unsafe) private static var _requests: [Recorded] = []

    static var responseDelay: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _responseDelay }
        set { lock.lock(); _responseDelay = newValue; lock.unlock() }
    }
    static var holdMethods: Set<String> {
        get { lock.lock(); defer { lock.unlock() }; return _holdMethods }
        set { lock.lock(); _holdMethods = newValue; lock.unlock() }
    }
    static var holdPredicate: ((URLRequest) -> Bool)? {
        get { lock.lock(); defer { lock.unlock() }; return _holdPredicate }
        set { lock.lock(); _holdPredicate = newValue; lock.unlock() }
    }
    static var cancellationCount: Int {
        get { lock.lock(); defer { lock.unlock() }; return _cancellationCount }
        set { lock.lock(); _cancellationCount = newValue; lock.unlock() }
    }
    static var handler: ((URLRequest) -> Reply)? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; lock.unlock() }
    }
    static var heldCount: Int { lock.lock(); defer { lock.unlock() }; return _held.count }
    static func releaseNext() {
        lock.lock()
        let next = _held.isEmpty ? nil : _held.removeFirst()
        lock.unlock()
        if let (instance, reply) = next {
            DispatchQueue.main.async { if !instance.stopped { instance.deliver(reply) } }
        }
    }

    static var requests: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    static func reset() {
        lock.lock()
        let dangling = _held
        _held = []
        _requests = []
        _handler = nil
        _responseDelay = 0
        _holdMethods = []
        _holdPredicate = nil
        _cancellationCount = 0
        lock.unlock()
        // Fail any held requests left behind by a failed/early-return test so URLSession tasks never hang.
        for (instance, _) in dangling where !instance.stopped {
            instance.deliver(.failure(.cancelled))
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? Self.readStream(request.httpBodyStream)
        Self.lock.lock()
        Self._requests.append(Recorded(method: request.httpMethod ?? "GET",
                                       url: request.url!,
                                       headers: request.allHTTPHeaderFields ?? [:],
                                       body: body))
        let currentHandler = Self._handler
        let delay = Self._responseDelay
        Self.lock.unlock()

        let reply = currentHandler?(request) ?? .failure(.notConnectedToInternet)
        Self.lock.lock()
        let shouldHold = Self._holdMethods.contains(request.httpMethod ?? "GET") || (Self._holdPredicate?(request) ?? false)
        if shouldHold { Self._held.append((self, reply)) }
        Self.lock.unlock()
        if shouldHold { return }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
                if !stopped { deliver(reply) }
            }
        } else { deliver(reply) }
    }

    private func deliver(_ reply: Reply) {
        switch reply {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .http(let status, let json):
            let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            if let json {
                let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stopped = true
        Self.lock.lock(); Self._cancellationCount += 1; Self.lock.unlock()
    }

    private static func readStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}

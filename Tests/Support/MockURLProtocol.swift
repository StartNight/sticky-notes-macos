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

    nonisolated(unsafe) static var responseDelay: TimeInterval = 0
    private var stopped = false
    nonisolated(unsafe) static var holdMethods: Set<String> = []
    nonisolated(unsafe) private static var held: [(MockURLProtocol, Reply)] = []
    static var heldCount: Int { lock.lock(); defer { lock.unlock() }; return held.count }
    static func releaseNext() {
        lock.lock()
        let next = held.isEmpty ? nil : held.removeFirst()
        lock.unlock()
        if let (instance, reply) = next {
            DispatchQueue.main.async { if !instance.stopped { instance.deliver(reply) } }
        }
    }
    static let lock = NSLock()
    nonisolated(unsafe) static var handler: ((URLRequest) -> Reply)?
    nonisolated(unsafe) private static var _requests: [Recorded] = []

    static var requests: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    static func reset() {
        lock.lock(); _requests = []; lock.unlock()
        handler = nil
        responseDelay = 0
        holdMethods = []
        lock.lock(); held = []; lock.unlock()
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
        Self.lock.unlock()

        let reply = Self.handler?(request) ?? .failure(.notConnectedToInternet)
        Self.lock.lock()
        let shouldHold = Self.holdMethods.contains(request.httpMethod ?? "GET")
        if shouldHold { Self.held.append((self, reply)) }
        Self.lock.unlock()
        if shouldHold { return }
        if Self.responseDelay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.responseDelay) { [self] in
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

    override func stopLoading() { stopped = true }

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

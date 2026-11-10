import Foundation
@testable import FengluPlayer

/// A canned reply for one request of a lyrics test.
struct LyricsStubResponse: Sendable {
    var status = 200
    var body = Data()
    var headers: [String: String] = [:]
    var delay: TimeInterval = 0

    static func json(_ object: Any, delay: TimeInterval = 0) -> LyricsStubResponse {
        LyricsStubResponse(body: try! JSONSerialization.data(withJSONObject: object), delay: delay)
    }

    static func html(_ html: String) -> LyricsStubResponse {
        LyricsStubResponse(body: Data(html.utf8))
    }
}

/// Routes every request of a session to a per-test handler and records the
/// URLs that were asked for. Requests without a handler result fail.
final class LyricsStubProtocol: URLProtocol {
    typealias Handler = @Sendable (URL) -> LyricsStubResponse?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var requests: [String: [URL]] = [:]
    private var pendingWork: DispatchWorkItem?

    /// Returns a session whose requests go to `handler`, and the key for `requestedURLs`.
    static func session(_ handler: @escaping Handler) -> (session: URLSession, key: String) {
        let key = UUID().uuidString
        lock.withLock { handlers[key] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LyricsStubProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Lyrics-Stub": key]
        return (URLSession(configuration: configuration), key)
    }

    static func requestedURLs(_ key: String) -> [URL] {
        lock.withLock { requests[key] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let key = request.value(forHTTPHeaderField: "X-Lyrics-Stub"),
              let handler = Self.lock.withLock({ () -> Handler? in
                  Self.requests[key, default: []].append(url)
                  return Self.handlers[key]
              }),
              let stub = handler(url)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(
                url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers
            )!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: stub.body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        pendingWork = work
        if stub.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay, execute: work)
        } else {
            work.perform()
        }
    }

    override func stopLoading() {
        pendingWork?.cancel()
    }
}

enum LyricsTestText {
    static let verses = [
        "Walking down the river road at dawn",
        "Counting every lantern on the bridge",
        "Paper boats are drifting out of sight",
        "Somebody is singing on the ridge",
        "Windows open slowly to the rain",
        "Coffee growing colder in the cup",
        "Letters that I never meant to send",
        "Morning finds me still not giving up"
    ]

    /// Synchronized lyrics whose last line lands at `lastTime` seconds.
    static func synchronized(lastTime: TimeInterval = 170, lines: [String] = verses) -> String {
        lines.enumerated().map { index, line in
            let time = lastTime * Double(index) / Double(max(lines.count - 1, 1))
            return String(format: "[%02d:%05.2f]%@", Int(time) / 60, time - Double(Int(time) / 60 * 60), line)
        }.joined(separator: "\n")
    }

    static var plain: String { verses.joined(separator: "\n") }

    static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

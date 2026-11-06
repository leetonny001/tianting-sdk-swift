import Foundation

public enum HttpMethod: String, Sendable {
    case get = "GET", post = "POST", patch = "PATCH", delete = "DELETE"
}

/// One HTTP request. Bearer tokens only travel in `headers`, never in the URL (PRD-chat 4.2).
public struct HttpRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var method: HttpMethod
    public var url: String
    public var headers: [String: String]
    public var body: Data?

    public init(method: HttpMethod, url: String, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    // Headers and body hold credentials, and a URL can hold a query string: printing a request shows neither.
    public var description: String { "HttpRequest(\(method.rawValue))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["method": method.rawValue]) }
}

public struct HttpResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// The HTTP seam (PRD-chat 4.5): production uses `URLSessionHttpTransport`, tests use `FakeHttp`. Timeouts stay with
/// the caller and the injected `IMClock`.
@MainActor
public protocol HttpTransport: AnyObject {
    /// Returns for any status code. Throws when no response arrived, including on task cancellation.
    func request(_ request: HttpRequest) async throws -> HttpResponse
}

/// The production transport.
///
/// Implicit retries (PRD-chat 21 item 16): URLSession re-sends idempotent methods by itself when a reused connection
/// dies. POST is not idempotent, and every token-changing request is a POST: `URLSessionRetryTests` runs this class
/// against a real socket that closes without answering and counts one POST arriving. Bearer tokens must not reach
/// another host, so redirects are not followed: the 3xx comes back and, having no error code, counts as a network error.
/// HTTP authentication challenges cancel the request, or a 401 with `WWW-Authenticate` would be sent again. No cookies, no cache, no credential store. This class logs nothing, so no URL query can reach a log.
@MainActor
public final class URLSessionHttpTransport: HttpTransport {
    private let session: URLSession

    /// `configuration` is for tests and special hosts; the default is `defaultConfiguration()`.
    public init(configuration: URLSessionConfiguration? = nil) {
        session = URLSession(
            configuration: configuration ?? URLSessionHttpTransport.defaultConfiguration(), delegate: NoRedirects(),
            delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public nonisolated static func defaultConfiguration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.waitsForConnectivity = false  // Fails right away offline: logout goes on locally (AC-ACC-04-6).
        c.httpShouldUsePipelining = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCredentialStorage = nil
        // The SDK's own 30-second timer decides; these only stop a task nobody cancelled from living forever.
        c.timeoutIntervalForRequest = 45
        c.timeoutIntervalForResource = 60
        return c
    }

    public func request(_ request: HttpRequest) async throws -> HttpResponse {
        guard let url = URL(string: request.url) else { throw URLError(.badURL) }
        var r = URLRequest(url: url)
        r.httpMethod = request.method.rawValue
        r.httpBody = request.body
        r.httpShouldHandleCookies = false
        r.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return HttpResponse(status: http.statusCode, body: data)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    /// Measured: a 401 with `WWW-Authenticate` makes URLSession send the POST a second time, with the default handling, a
    /// rejected protection space and an empty credential alike. So an HTTP authentication challenge cancels the request:
    /// it fails as a network error, sent once. im-server sends no such header on /v1; a gateway must not add one, or a
    /// refresh's 4019 reads as a network error and the client keeps backing off.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust, NSURLAuthenticationMethodClientCertificate:
            completionHandler(.performDefaultHandling, nil)
        default:
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

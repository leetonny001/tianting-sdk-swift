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

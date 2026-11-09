import Foundation

// Images and files (PRD-chat section 6: F-FILE-01, 03, 04, 07; section 13.1): the /v1/files/* endpoints, the object
// store's PUT and GET. Image processing (compression, thumbnail, EXIF removal) stays in the app (R-CF-24): the SDK takes
// the processed files. Presigned URLs and file names are never logged, persisted, or put in an error (F-FILE-04 rule 5).

public enum FileVariant: String, Sendable, Codable, Hashable {
    case original, thumb
}

public struct FileUrlItem: Sendable, Hashable {
    public var fileId: String
    public var variant: FileVariant

    public init(fileId: String, variant: FileVariant) {
        self.fileId = fileId
        self.variant = variant
    }
}

/// One item's result: a URL, or `code` (4048: not accessible, the same as a fileId that does not exist). Keep the URL in
/// memory only; printing the value never shows it.
public struct FileUrlResult: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var fileId: String
    public var variant: FileVariant
    public var url: String?
    public var expiresAt: Int64?
    public var code: Int?

    public init(fileId: String, variant: FileVariant, url: String? = nil, expiresAt: Int64? = nil, code: Int? = nil) {
        self.fileId = fileId
        self.variant = variant
        self.url = url
        self.expiresAt = expiresAt
        self.code = code
    }

    public var description: String { "FileUrlResult(\(variant.rawValue), code: \(code.map(String.init) ?? "-"))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["variant": variant.rawValue, "code": code as Any]) }
}

/// A local file to upload, with its declared type (signed into the PUT, RC2-08).
public struct LocalUpload: Sendable, Hashable {
    public var file: URL
    public var mime: String

    public init(file: URL, mime: String) {
        self.file = file
        self.mime = mime
    }
}

/// An image the app processed (F-FILE-02 rules 2-4): both variants re-encoded without EXIF; GIFs not re-encoded. The
/// SDK copies the files into its sandbox before uploading (F-FILE-07 rule 2), the app's files stay untouched.
public struct ProcessedImage: Sendable, Hashable {
    public var original: LocalUpload
    /// Long side <= 480, <= 512 KiB (F-FILE-02 rule 3).
    public var thumb: LocalUpload
    public var width: Int
    public var height: Int
    /// Kept in the server's database only, never shown to the peer; "image" by default.
    public var name: String?

    public init(original: LocalUpload, thumb: LocalUpload, width: Int, height: Int, name: String? = nil) {
        self.original = original
        self.thumb = thumb
        self.width = width
        self.height = height
        self.name = name
    }
}

/// A file to send (F-FILE-03): the content is not re-encoded.
public struct FileInput: Sendable, Hashable {
    public var file: URL
    public var name: String
    /// application/octet-stream when unknown.
    public var mime: String?

    public init(file: URL, name: String, mime: String? = nil) {
        self.file = file
        self.name = name
        self.mime = mime
    }
}

public struct PresignedPut: Sendable, Decodable, CustomStringConvertible {
    public var url: String
    public var headers: [String: String]
    public var expiresAt: Int64

    public var description: String { "PresignedPut" }
}

public struct UploadRequest: Sendable, Hashable {
    public var kind: String
    public var name: String
    public var size: Int64
    public var mime: String
    public var thumb: (size: Int64, mime: String)?

    public init(kind: String, name: String, size: Int64, mime: String, thumbSize: Int64? = nil, thumbMime: String? = nil) {
        self.kind = kind
        self.name = name
        self.size = size
        self.mime = mime
        if let thumbSize, let thumbMime { thumb = (thumbSize, thumbMime) }
    }

    public static func == (a: UploadRequest, b: UploadRequest) -> Bool {
        a.kind == b.kind && a.name == b.name && a.size == b.size && a.mime == b.mime && a.thumb?.size == b.thumb?.size
            && a.thumb?.mime == b.thumb?.mime
    }

    public func hash(into h: inout Hasher) {
        h.combine(kind)
        h.combine(name)
        h.combine(size)
    }

    var json: JSONValue {
        var o: [String: JSONValue] = [
            "kind": .string(kind), "name": .string(name), "size": .int(size), "mime": .string(mime),
        ]
        if let thumb { o["thumb"] = ["size": .int(thumb.size), "mime": .string(thumb.mime)] }
        return .object(o)
    }
}

public struct UploadResponse: Sendable, Decodable {
    public var fileId: String
    public var put: PresignedPut
    public var thumbPut: PresignedPut?
}

public struct CompleteResponse: Sendable, Decodable, Equatable {
    public var fileId: String
    public var size: Int64
    public var mime: String
    public var width: Int?
    public var height: Int?
}

/// Errors of the object store steps. Never carries a URL.
public enum FileTransferError: Error, Sendable, Equatable {
    /// The PUT or GET got this status (403: the presigned URL expired), or 0 when no response arrived.
    case status(Int)
    /// The item has no URL: 4048 (not accessible, expired, unknown) or another code.
    case unavailable(code: Int)
    /// Writing the local file failed.
    case storage
    case cancelled
}

/// Bearer requests to /v1/* for the file endpoints. `AccountClient` implements it (4011 handled as F-ACC-03 rule 7);
/// demo mode uses `StaticTokenAuth`. Throws `AccountError` with a code, or `AccountNetworkError` without one.
@MainActor
public protocol FileAuth: AnyObject {
    func authorized(_ method: HttpMethod, _ path: String, body: JSONValue?) async throws -> JSONValue
}

extension AccountClient: FileAuth {}

/// `FileAuth` for demo mode (`connect(token:)`): a fixed token, no refresh. The server's file endpoints need no `sid`.
@MainActor
public final class StaticTokenAuth: FileAuth {
    private let baseUrl: String
    private let token: String
    private let http: HttpTransport

    public init(baseUrl: String, token: String, http: HttpTransport? = nil) {
        var b = baseUrl
        while b.hasSuffix("/") { b.removeLast() }
        self.baseUrl = b
        self.token = token
        self.http = http ?? URLSessionHttpTransport()
    }

    public func authorized(_ method: HttpMethod, _ path: String, body: JSONValue?) async throws -> JSONValue {
        var headers = ["Accept": "application/json", "Authorization": "Bearer \(token)"]
        if body != nil { headers["Content-Type"] = "application/json" }
        let resp: HttpResponse
        do {
            resp = try await http.request(
                HttpRequest(method: method, url: baseUrl + path, headers: headers, body: body.map { Data($0.jsonString().utf8) }))
        } catch {
            throw AccountNetworkError.network
        }
        if (200..<300).contains(resp.status) {
            return (try? JSONDecoder().decode(JSONValue.self, from: resp.body.isEmpty ? Data("{}".utf8) : resp.body)) ?? [:]
        }
        guard let e = try? JSONDecoder().decode(JSONValue.self, from: resp.body), let code = e["code"]?.intValue else {
            throw AccountNetworkError.status(resp.status)
        }
        var details: [String: JSONValue]?
        if case .object(let d)? = e["details"] { details = d }
        throw AccountError(
            status: resp.status, code: Int(code), message: e["msg"]?.stringValue ?? "", reason: e["reason"]?.stringValue,
            details: details)
    }
}

/// Direct PUT and GET against the object store (F-FILE-01 rule 2, F-FILE-03 rule 3). Production uses
/// `URLSessionObjectStoreTransport`; tests use `FakeObjectStore`.
@MainActor
public protocol ObjectStoreTransport: AnyObject {
    /// PUTs a file; returns the status. Throws when no response arrived, including on task cancellation.
    /// `progress` gets the bytes sent so far.
    func put(url: String, headers: [String: String], file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> Int
    /// GETs into `destination` (written only for a 2xx); returns the status. `progress` gets (received, expected).
    func get(url: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> Int
}

/// The production object store transport.
///
/// Implicit retries (PRD-chat 21 item 16, problem S2): URLSession re-sends idempotent methods (PUT, GET) by itself when a
/// reused keep-alive connection dies. So every request here gets its own session, never a reused connection: a broken
/// upload fails and the SDK decides (a new upload from the start, F-FILE-01 rule 2). `ObjectStoreRetryTests` counts the
/// requests on a real socket. Redirects are not followed, challenges are cancelled, no cookies, no cache, no credential
/// store, and nothing is logged (the URLs carry signatures).
@MainActor
public final class URLSessionObjectStoreTransport: ObjectStoreTransport {
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration? = nil) {
        self.configuration = configuration ?? URLSessionObjectStoreTransport.defaultConfiguration()
    }

    public nonisolated static func defaultConfiguration() -> URLSessionConfiguration {
        let c = URLSessionHttpTransport.defaultConfiguration()
        // Big files: the request timeout is between bytes, the resource timeout is the whole transfer.
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 3600
        return c
    }

    /// Headers the system sets itself: the signed Content-Length is the file's size.
    private static let reserved: Set<String> = ["content-length", "host", "connection"]

    public func put(url: String, headers: [String: String], file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> Int
    {
        guard let u = URL(string: url) else { throw FileTransferError.status(0) }
        var r = URLRequest(url: u)
        r.httpMethod = "PUT"
        r.httpShouldHandleCookies = false
        r.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (k, v) in headers where !Self.reserved.contains(k.lowercased()) { r.setValue(v, forHTTPHeaderField: k) }
        let delegate = ObjectStoreDelegate(sent: progress, received: nil)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.upload(for: r, fromFile: file)
        guard let http = response as? HTTPURLResponse else { throw FileTransferError.status(0) }
        return http.statusCode
    }

    public func get(url: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> Int {
        guard let u = URL(string: url) else { throw FileTransferError.status(0) }
        var r = URLRequest(url: u)
        r.httpMethod = "GET"
        r.httpShouldHandleCookies = false
        r.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let delegate = ObjectStoreDelegate(sent: nil, received: progress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (tmp, response) = try await session.download(for: r)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let http = response as? HTTPURLResponse else { throw FileTransferError.status(0) }
        guard (200..<300).contains(http.statusCode) else { return http.statusCode }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tmp, to: destination)
        } catch {
            throw FileTransferError.storage
        }
        return http.statusCode
    }
}

private final class ObjectStoreDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, Sendable {
    let sent: (@Sendable (Int64) -> Void)?
    let received: (@Sendable (Int64, Int64?) -> Void)?

    init(sent: (@Sendable (Int64) -> Void)?, received: (@Sendable (Int64, Int64?) -> Void)?) {
        self.sent = sent
        self.received = received
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        sent?(totalBytesSent)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        received?(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

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

/// At most 50 items per request (F-FILE-04 rule 1; more is 4131).
public let fileUrlsBatch = 50
/// `complete` answering 5032 is retried 3 times with backoff, then the message fails (F-FILE-07).
public let completeRetries = 3
private let completeBackoffMs: Int64 = 1_000
private let completeJitter = 0.2
/// A cached URL with less than this left is asked for again (a download takes time).
private let urlReuseMarginMs: Int64 = 15_000

/// One pending URL lookup: resolved by a batch.
@MainActor
private final class UrlPromise {
    let item: FileUrlItem
    private var result: Result<FileUrlResult, Error>?
    private var waiters: [CheckedContinuation<FileUrlResult, Error>] = []

    init(_ item: FileUrlItem) { self.item = item }

    func resolve(_ r: Result<FileUrlResult, Error>) {
        guard result == nil else { return }
        result = r
        for w in waiters { w.resume(with: r) }
        waiters = []
    }

    func value() async throws -> FileUrlResult {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }
}

/// The /v1/files/* endpoints (PRD-chat 13.1). `getFileUrls` calls in the same main-actor turn merge into one request
/// (at most 50 per batch, F-FILE-04 rule 6); URLs are cached in memory until shortly before they expire, so the same
/// fileId + variant is not asked again (AC-FILE-04-10). Never persisted, never logged.
@MainActor
public final class FileClient {
    public let auth: FileAuth
    public let objectStore: ObjectStoreTransport
    private let clock: IMClock
    private let log: IMLogger
    private let random: () -> Double
    private var urls: [FileUrlItem: (url: String, expiresAt: Int64)] = [:]
    private var queued: [UrlPromise] = []
    private var inflight: [FileUrlItem: UrlPromise] = [:]
    private var flushScheduled = false

    public init(
        auth: FileAuth, objectStore: ObjectStoreTransport? = nil, clock: IMClock? = nil, logger: IMLogger = SilentLogger(),
        random: (() -> Double)? = nil
    ) {
        self.auth = auth
        self.objectStore = objectStore ?? URLSessionObjectStoreTransport()
        self.clock = clock ?? SystemClock()
        self.log = logger
        self.random = random ?? { Double.random(in: 0..<1) }
    }

    /// POST /v1/files/uploads. 4292 and 4290 (uploadPendingLimit) are not retried (F-FILE-01 rules 6, 6a).
    public func createUpload(_ req: UploadRequest) async throws -> UploadResponse {
        try decode(UploadResponse.self, try await auth.authorized(.post, "/v1/files/uploads", body: req.json))
    }

    /// PUTs one variant with the signed headers as given (RC2-08). A non-2xx throws `FileTransferError.status`.
    public func put(_ target: PresignedPut, file: URL, progress: @escaping @Sendable (Int64) -> Void = { _ in }) async throws {
        let status: Int
        do {
            status = try await objectStore.put(url: target.url, headers: target.headers, file: file, progress: progress)
        } catch {
            if Task.isCancelled { throw FileTransferError.cancelled }
            throw FileTransferError.status(0)
        }
        guard (200..<300).contains(status) else {
            log.warn("files: put status \(status)")
            throw FileTransferError.status(status)
        }
    }

    /// POST /v1/files/{id}/complete. 5032 backs off 1, 2, 4 seconds (+-20%) for 3 retries, then throws.
    public func complete(_ fileId: String) async throws -> CompleteResponse {
        var i = 0
        while true {
            do {
                return try decode(CompleteResponse.self, try await auth.authorized(.post, "/v1/files/\(escape(fileId))/complete", body: nil))
            } catch let e as AccountError where e.code == ErrorCode.objectStoreUnavailable && i < completeRetries {
                if Task.isCancelled { throw e }
                log.debug("files: complete 5032, retry \(i + 1)")
                let base = Double(completeBackoffMs << Int64(i))
                await sleep(Int64((base * (1 + (random() * 2 - 1) * completeJitter)).rounded()))
                if Task.isCancelled { throw FileTransferError.cancelled }
                i += 1
            }
        }
    }

    /// DELETE /v1/files/uploads/{id} (cancelUpload): idempotent; a failure is only logged (best effort, the slot also
    /// frees itself when the PUT URL expires).
    public func cancelUpload(_ fileId: String) async {
        do {
            _ = try await auth.authorized(.delete, "/v1/files/uploads/\(escape(fileId))", body: nil)
        } catch {
            log.warn("files: cancel upload failed: \((error as? AccountError).map { String($0.code) } ?? "network")")
        }
    }

    /// Download URLs (F-FILE-04): calls in the same main-actor turn merge into one batch (<= 50), unexpired URLs come
    /// from the cache. Inaccessible items have code 4048 without affecting the rest. A failed batch throws for its callers.
    public func getFileUrls(_ items: [FileUrlItem]) async throws -> [FileUrlResult] {
        let promises = items.map { lookup($0) }
        var out: [FileUrlResult] = []
        for p in promises { out.append(try await p.value()) }
        return out
    }

    /// Forgets a file's URLs (expiry, deletion, a failed download: F-FILE-06 rule 3, AC-FILE-03-5).
    public func forget(_ fileId: String) {
        for v in [FileVariant.original, .thumb] {
            urls[FileUrlItem(fileId: fileId, variant: v)] = nil
            inflight[FileUrlItem(fileId: fileId, variant: v)] = nil
        }
    }

    func forget(_ item: FileUrlItem) {
        urls[item] = nil
        inflight[item] = nil
    }

    /// Logout: the URLs only live in memory.
    public func clear() {
        urls = [:]
        inflight = [:]
    }

    private func lookup(_ item: FileUrlItem) -> UrlPromise {
        if let hit = urls[item], hit.expiresAt - clock.now() > urlReuseMarginMs {
            let p = UrlPromise(item)
            p.resolve(.success(FileUrlResult(fileId: item.fileId, variant: item.variant, url: hit.url, expiresAt: hit.expiresAt)))
            return p
        }
        if let same = inflight[item] { return same }
        let p = UrlPromise(item)
        inflight[item] = p
        queued.append(p)
        if !flushScheduled {
            flushScheduled = true
            Task { @MainActor [weak self] in
                await Task.yield()  // Lets other lookups of this turn join the batch.
                self?.flush()
            }
        }
        return p
    }

    private func flush() {
        flushScheduled = false
        let all = queued
        queued = []
        var i = 0
        while i < all.count {
            let group = Array(all[i..<min(i + fileUrlsBatch, all.count)])
            Task { @MainActor [weak self] in await self?.batch(group) }
            i += fileUrlsBatch
        }
    }

    private func batch(_ group: [UrlPromise]) async {
        let body: JSONValue = [
            "items": .array(group.map { ["fileId": .string($0.item.fileId), "variant": .string($0.item.variant.rawValue)] })
        ]
        let resp: JSONValue
        do {
            resp = try await auth.authorized(.post, "/v1/files/urls", body: body)
        } catch {
            log.warn("files: urls failed: \((error as? AccountError).map { String($0.code) } ?? "network")")
            for p in group {
                if inflight[p.item] === p { inflight[p.item] = nil }
                p.resolve(.failure(error))
            }
            return
        }
        let items = resp["items"]?.arrayValue ?? []
        for (i, p) in group.enumerated() {
            let match: (JSONValue) -> Bool = {
                $0["fileId"]?.stringValue == p.item.fileId && $0["variant"]?.stringValue == p.item.variant.rawValue
            }
            let r = i < items.count && match(items[i]) ? items[i] : items.first(where: match)
            if inflight[p.item] === p { inflight[p.item] = nil }
            if let url = r?["url"]?.stringValue, let exp = r?["expiresAt"]?.intValue {
                urls[p.item] = (url, exp)
                p.resolve(.success(FileUrlResult(fileId: p.item.fileId, variant: p.item.variant, url: url, expiresAt: exp)))
            } else {
                let code = r?["code"]?.intValue.map(Int.init) ?? ErrorCode.fileNotFound
                p.resolve(.success(FileUrlResult(fileId: p.item.fileId, variant: p.item.variant, code: code)))
            }
        }
    }

    private func sleep(_ ms: Int64) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            _ = clock.setTimeout(ms) { c.resume() }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ v: JSONValue) throws -> T {
        guard let data = try? JSONCoding.encoder.encode(v), let t = try? JSONDecoder().decode(T.self, from: data) else {
            throw AccountNetworkError.invalidResponse
        }
        return t
    }

    private func escape(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? id
    }
}

/// Where an unsent attachment's bytes live: file names in the SDK's per-user sandbox (relative, since an iOS app's
/// container path can change between launches). Stored in the outbox; never a URL.
struct AttachmentSource: Sendable, Hashable, Codable {
    var kind: String  // image | file
    var original: String?
    var originalMime: String?
    var thumb: String?
    var thumbMime: String?
    var width: Int?
    var height: Int?
    /// The upload's name (image: "image" by default; file: the file name). Stored only in the local outbox.
    var name: String?
    /// true while the app's processing has not produced files yet (memory only, never stored as such).
    var pending: Bool = false
}

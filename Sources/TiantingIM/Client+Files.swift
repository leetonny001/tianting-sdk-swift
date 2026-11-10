import Foundation

/// One upload in progress (F-FILE-07 rule 6: one at a time).
@MainActor
final class UploadJob {
    let convId: String
    let clientMsgId: String
    var task: Task<Void, Never>?
    /// Set once the upload was granted: a cancel then sends DELETE.
    var fileId: String?
    var completed = false
    var cancelled = false

    init(convId: String, clientMsgId: String) {
        self.convId = convId
        self.clientMsgId = clientMsgId
    }
}

/// An outbox row as written: the message and its stored source.
struct OutboxRow: Equatable {
    var message: Message
    var source: AttachmentSource?
}

private func hexName(_ s: String) -> String {
    s.utf8.map { String(format: "%02x", $0) }.joined()
}

extension IMClient {
    // MARK: Public: images and files (PRD-chat 13.1, F-FILE-02, 03, 07)

    /// Sends a processed image. The SDK first copies both files into its sandbox (F-FILE-07 rule 2; the app's files are
    /// not touched), inserts an "uploading" message and returns it; uploads run one at a time in pick order (rules 5, 6):
    /// ask -> PUT original and thumbnail -> complete, then `send` like text. Text can pass an uploading image. Uploading
    /// time does not count toward the 10-second send timeout (rule 8). 4292 and 4290 (uploadPendingLimit) are not
    /// retried. `onProgress` gets (sent, total) bytes over both variants.
    @discardableResult
    public func sendImage(
        _ convId: String, _ image: ProcessedImage, onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) throws -> Message {
        let m = try addAttachment(
            convId, type: .image,
            body: MsgBody(
                image: ImageBody(
                    fileId: "", width: image.width, height: image.height, size: fileSize(image.original.file),
                    mime: image.original.mime)),
            status: .uploading, onProgress: onProgress)
        adoptImage(m.clientMsgId, image)
        if store.list(convId).local(m.clientMsgId)?.status == .uploading { enqueueUpload(convId, m.clientMsgId) }
        return store.list(convId).local(m.clientMsgId) ?? m
    }

    /// Sends an image the app still has to process: the message shows "processing" at once, and `process` runs when this
    /// message's turn comes (one at a time, so several big decodes never run together). A throw fails the message with
    /// `.process` ("无法处理这张图片，请用文件方式发送").
    @discardableResult
    public func sendImage(
        _ convId: String, process: @escaping @MainActor () async throws -> ProcessedImage,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) throws -> Message {
        let m = try addAttachment(
            convId, type: .image, body: MsgBody(image: ImageBody(fileId: "")), status: .processing, onProgress: onProgress)
        sources[m.clientMsgId] = AttachmentSource(kind: "image", pending: true)
        producers[m.clientMsgId] = process
        enqueueUpload(convId, m.clientMsgId)
        return m
    }

    /// Sends a file (F-FILE-03): copied into the sandbox, not re-encoded. Otherwise as `sendImage`.
    @discardableResult
    public func sendFile(
        _ convId: String, _ file: FileInput, onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) throws -> Message {
        let mime = file.mime ?? "application/octet-stream"
        let m = try addAttachment(
            convId, type: .file,
            body: MsgBody(file: FileBody(fileId: "", name: file.name, size: fileSize(file.file), mime: mime)),
            status: .uploading, onProgress: onProgress)
        do {
            let name = "\(m.clientMsgId)-file"
            try copyIn(file.file, as: name)
            sources[m.clientMsgId] = AttachmentSource(kind: "file", original: name, originalMime: mime, name: file.name)
            enqueueUpload(convId, m.clientMsgId)
        } catch {
            failAttachment(convId, m.clientMsgId, .storage)
        }
        return store.list(convId).local(m.clientMsgId) ?? m
    }

    /// Cancels an image or file not sent yet (AC-FILE-02-5, AC-FILE-01-17): stops the upload, sends
    /// DELETE /v1/files/uploads/{id} for a granted one, removes the message and its sandbox copy; no `send`. One already
    /// in `send` cannot be cancelled (false). Also deletes a failed attachment.
    @discardableResult
    public func cancelUpload(_ convId: String, _ clientMsgId: String) -> Bool {
        let list = store.list(convId)
        guard let m = list.local(clientMsgId), m.isAttachment,
            list.removeUnsent(clientMsgId, [.processing, .uploading, .queued, .failed])
        else { return false }
        if let job, job.clientMsgId == clientMsgId {
            stopJob(job)
        } else if let id = m.body.fileId {
            cancelOnServer(id)
        }
        uploadQueue.removeAll { $0.clientMsgId == clientMsgId }
        releaseSource(clientMsgId)
        emitMessages(convId)
        pumpUploads()
        return true
    }

    /// Download URLs (F-FILE-04): calls in the same main-actor turn merge into one batch (<= 50), unexpired URLs come
    /// from memory (AC-FILE-04-10). Files known to be expired are answered locally with 4048, no request (AC-FILE-06-6).
    /// Never persist or log the URLs (rule 5).
    public func getFileUrls(_ items: [FileUrlItem]) async throws -> [FileUrlResult] {
        let files = try requireFiles()
        let ask = items.filter { !store.fileExpired($0.fileId) }
        let got = ask.isEmpty ? [] : try await files.getFileUrls(ask)
        var k = 0
        return items.map { i in
            if store.fileExpired(i.fileId), !ask.contains(i) {
                return FileUrlResult(fileId: i.fileId, variant: i.variant, code: ErrorCode.fileNotFound)
            }
            defer { k += 1 }
            return got[k]
        }
    }

    /// The cached download of a file variant, if any (F-FILE-04 rule 5: keyed by fileId + variant, not by URL).
    public func cachedFile(fileId: String, variant: FileVariant) -> URL? {
        guard let f = cacheFile(fileId, variant), FileManager.default.fileExists(atPath: f.path) else { return nil }
        return f
    }

    /// Downloads a file variant into the SDK's private cache with progress (F-FILE-03 rule 3); cancel by cancelling the
    /// calling task. A cached copy is returned without any request. A failure leaves no partial file, and the next call
    /// starts from byte 0 with a new URL (AC-FILE-03-5). A refused GET (403: the URL expired) asks for a new URL once.
    /// Throws `FileTransferError`: `.unavailable(code:)` for 4048 (expired, revoked, no access), `.status`, `.cancelled`.
    /// When the file's message is recalled, deleted or its file expires midway, the transfer stops, the partial file is
    /// deleted, `.downloadAborted(fileId:recalled:)` is emitted and `DownloadAbortedError` thrown (AC-RCL-03-12).
    public func download(
        fileId: String, variant: FileVariant, progress: (@Sendable (Int64, Int64?) -> Void)? = nil
    ) async throws -> URL {
        let files = try requireFiles()
        if store.fileExpired(fileId) { throw FileTransferError.unavailable(code: ErrorCode.fileNotFound) }
        guard let dest = cacheFile(fileId, variant) else { throw FileTransferError.storage }
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        let item = FileUrlItem(fileId: fileId, variant: variant)
        var attempt = 0
        while true {
            let r = try await files.getFileUrls([item])[0]
            guard let url = r.url else { throw FileTransferError.unavailable(code: r.code ?? ErrorCode.fileNotFound) }
            do {
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            } catch {
                throw FileTransferError.storage
            }
            let part = dest.deletingLastPathComponent().appendingPathComponent(
                "\(dest.lastPathComponent).part-\(UUID().uuidString)")
            let status: Int
            // The transfer runs in its own task: a recall or deletion stops only it (`forgetFile`), not the caller.
            let handle = DownloadHandle()
            let objectStore = files.objectStore
            let report = progress ?? { _, _ in }
            let transfer = Task { @MainActor in try await objectStore.get(url: url, to: part, progress: report) }
            handle.task = transfer
            downloads[fileId, default: [:]][ObjectIdentifier(handle)] = handle
            defer {
                downloads[fileId]?[ObjectIdentifier(handle)] = nil
                if downloads[fileId]?.isEmpty == true { downloads[fileId] = nil }
            }
            do {
                status = try await withTaskCancellationHandler {
                    try await transfer.value
                } onCancel: {
                    transfer.cancel()
                }
            } catch {
                try? FileManager.default.removeItem(at: part)
                files.forget(item)
                if let r = handle.abortedRecalled { throw DownloadAbortedError(fileId: fileId, recalled: r) }
                if Task.isCancelled { throw FileTransferError.cancelled }
                if let e = error as? FileTransferError { throw e }
                throw FileTransferError.status(0)
            }
            if let r = handle.abortedRecalled {
                try? FileManager.default.removeItem(at: part)
                throw DownloadAbortedError(fileId: fileId, recalled: r)
            }
            if (200..<300).contains(status) {
                do {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: part, to: dest)
                } catch {
                    try? FileManager.default.removeItem(at: part)
                    throw FileTransferError.storage
                }
                // Expired or deleted meanwhile: do not keep it.
                if store.fileExpired(fileId) {
                    try? FileManager.default.removeItem(at: dest)
                    throw FileTransferError.unavailable(code: ErrorCode.fileNotFound)
                }
                return dest
            }
            try? FileManager.default.removeItem(at: part)
            files.forget(item)
            log.warn("files: download status \(status)")
            if status == 403, attempt == 0 {
                attempt += 1
                continue
            }
            throw FileTransferError.status(status)
        }
    }

    // MARK: The pipeline

    func requireFiles() throws -> FileClient {
        guard let files else { throw FileTransferError.unavailable(code: 0) }
        return files
    }

    private func addAttachment(
        _ convId: String, type: MessageType, body: MsgBody, status: MessageStatus,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) throws -> Message {
        _ = try requireFiles()
        guard !me.isEmpty else { throw IMConnectionError.notConnected }
        _ = try parseConvId(convId, me: me)
        let msg = Message(
            clientMsgId: newId(), msgId: nil, seq: nil, convId: convId, from: me, type: type, body: body, ts: clock.now(),
            status: status, error: nil, deleted: nil, deletedAt: nil)
        store.list(convId).addLocal(msg)
        if let onProgress { progressHandlers[msg.clientMsgId] = onProgress }
        emitMessages(convId)
        return msg
    }

    /// Copies a processed image into the sandbox; a failure fails the message with `.storage` ("存储空间不足").
    private func adoptImage(_ clientMsgId: String, _ image: ProcessedImage) {
        guard let convId = convOf(clientMsgId) else { return }
        do {
            let o = "\(clientMsgId)-original"
            let t = "\(clientMsgId)-thumb"
            try copyIn(image.original.file, as: o)
            try copyIn(image.thumb.file, as: t)
            sources[clientMsgId] = AttachmentSource(
                kind: "image", original: o, originalMime: image.original.mime, thumb: t, thumbMime: image.thumb.mime,
                width: image.width, height: image.height, name: image.name ?? "image")
            store.list(convId).update(clientMsgId) {
                $0.body.image = ImageBody(
                    fileId: "", width: image.width, height: image.height, size: self.fileSize(image.original.file),
                    mime: image.original.mime)
            }
        } catch {
            releaseSource(clientMsgId)
            failAttachment(convId, clientMsgId, .storage)
        }
    }

    private func convOf(_ clientMsgId: String) -> String? {
        for id in store.allListIds() where store.list(id).local(clientMsgId) != nil { return id }
        return nil
    }

    private func enqueueUpload(_ convId: String, _ clientMsgId: String) {
        uploadQueue.append((convId, clientMsgId))
        pumpUploads()
    }

    /// One upload at a time across conversations (F-FILE-07 rule 6), in the order picked (rule 5).
    func pumpUploads() {
        guard job == nil, !uploadQueue.isEmpty else { return }
        let next = uploadQueue.removeFirst()
        let j = UploadJob(convId: next.convId, clientMsgId: next.clientMsgId)
        job = j
        j.task = Task { @MainActor [weak self] in
            await self?.runUpload(j)
            guard let self else { return }
            if self.job === j { self.job = nil }
            self.pumpUploads()
        }
    }

    private func alive(_ j: UploadJob) -> Bool {
        job === j && !j.cancelled && store.list(j.convId).local(j.clientMsgId) != nil
    }

    private func runUpload(_ j: UploadJob) async {
        let convId = j.convId
        let id = j.clientMsgId
        guard let files, alive(j) else { return }
        let list = store.list(convId)
        if sources[id]?.pending == true, let produce = producers[id] {
            let image: ProcessedImage
            do {
                image = try await produce()
            } catch {
                if alive(j) { failAttachment(convId, id, .process) }
                return
            }
            guard alive(j) else { return }
            producers[id] = nil
            adoptImage(id, image)
            guard list.local(id)?.status != .failed else { return }
        }
        guard let src = sources[id], !src.pending, let main = src.original,
            FileManager.default.fileExists(atPath: sandboxFile(main).path),
            src.thumb.map({ FileManager.default.fileExists(atPath: sandboxFile($0).path) }) ?? true
        else {
            failAttachment(convId, id, .sourceMissing)
            return
        }
        list.update(id) { $0.status = .uploading }
        emitMessages(convId)
        let mainSize = fileSize(sandboxFile(main)) ?? 0
        let thumbSize = src.thumb.flatMap { fileSize(sandboxFile($0)) } ?? 0
        let total = mainSize + thumbSize
        let progress = progressHandlers[id]
        do {
            let req = UploadRequest(
                kind: src.kind, name: src.name ?? src.kind, size: mainSize, mime: src.originalMime ?? "application/octet-stream",
                thumbSize: src.thumb == nil ? nil : thumbSize, thumbMime: src.thumbMime)
            let up = try await files.createUpload(req)
            j.fileId = up.fileId
            guard alive(j) else { return }
            try await files.put(up.put, file: sandboxFile(main)) { n in progress?(n, total) }
            if let thumb = src.thumb {
                guard let tp = up.thumbPut else { throw FileTransferError.status(0) }
                guard alive(j) else { return }
                try await files.put(tp, file: sandboxFile(thumb)) { n in progress?(mainSize + n, total) }
            }
            guard alive(j) else { return }
            let done = try await files.complete(up.fileId)
            j.completed = true
            ownFileIds.insert(done.fileId)
            guard alive(j) else { return }
            list.update(id) {
                if $0.type == .image {
                    $0.body.image?.fileId = done.fileId
                    $0.body.image?.size = done.size
                    $0.body.image?.mime = done.mime
                    if let w = done.width, let h = done.height {
                        $0.body.image?.width = w
                        $0.body.image?.height = h
                    }
                } else {
                    $0.body.file?.fileId = done.fileId
                    $0.body.file?.size = done.size
                    $0.body.file?.mime = done.mime
                }
            }
            // Ready to send (rule 1): send when online, else queue; a reconnect sends it once (rule 3).
            if conn.state == .connected {
                dispatch(convId, id)
            } else {
                list.update(id) { $0.status = .queued }
                emitMessages(convId)
            }
        } catch {
            guard alive(j) else { return }
            // An upload that did not complete is cancelled best effort, freeing the pending slot at once (rule 6a).
            if let f = j.fileId, !j.completed { cancelOnServer(f) }
            if let e = error as? AccountError {
                failAttachment(convId, id, .code(e.code), reason: e.reason)
            } else if let e = error as? IMError {
                failAttachment(convId, id, .code(e.code))
            } else {
                failAttachment(convId, id, .network)
            }
        }
    }

    func failAttachment(_ convId: String, _ clientMsgId: String, _ error: SendFailure, reason: String? = nil) {
        let list = store.list(convId)
        guard let m = list.local(clientMsgId), m.seq == nil, m.status != .failed else { return }
        list.update(clientMsgId) {
            $0.status = .failed
            $0.error = error
            $0.errorReason = reason
        }
        emitMessages(convId)
        emit(.sendFailed(convId: convId, clientMsgId: clientMsgId, error: error))
    }

    func retryUpload(_ convId: String, _ clientMsgId: String) {
        let list = store.list(convId)
        let src = sources[clientMsgId]
        let files = [src?.original, src?.thumb].compactMap { $0 }
        let present =
            src != nil
            && (src!.pending ? producers[clientMsgId] != nil
                : !files.isEmpty && files.allSatisfy { FileManager.default.fileExists(atPath: sandboxFile($0).path) })
        guard present else {
            list.update(clientMsgId) {
                $0.error = .sourceMissing
                $0.errorReason = nil
            }
            emitMessages(convId)
            return
        }
        list.update(clientMsgId) {
            $0.status = src!.pending ? .processing : .uploading
            $0.error = nil
            $0.errorReason = nil
        }
        emitMessages(convId)
        enqueueUpload(convId, clientMsgId)
    }

    /// `send` answered 4096 (the file was purged after 24 hours, or bound elsewhere), or 4048 for a fileId this device
    /// completed itself (the purge deleted the row; v1.4, P-37 ①): with a sandbox copy the message goes
    /// back to uploading and uploads again, not counted as an automatic resend (RC2-23); without it, it fails with
    /// `sourceMissing` (F-FILE-07 rule 4, AC-FILE-07-10).
    func reupload(_ convId: String, _ clientMsgId: String) {
        let list = store.list(convId)
        list.update(clientMsgId) {
            $0.body.image?.fileId = ""
            $0.body.file?.fileId = ""
        }
        let src = sources[clientMsgId]
        let files = [src?.original, src?.thumb].compactMap { $0 }
        if src == nil || files.isEmpty || !files.allSatisfy({ FileManager.default.fileExists(atPath: sandboxFile($0).path) }) {
            fail(convId, clientMsgId, .sourceMissing)
            return
        }
        list.update(clientMsgId) {
            $0.status = .uploading
            $0.error = nil
            $0.errorReason = nil
        }
        emitMessages(convId)
        enqueueUpload(convId, clientMsgId)
    }

    /// Stops the upload of this message (a queued one is dropped too). A granted, unfinished one gets DELETE.
    func dropUploadJob(_ clientMsgId: String) {
        uploadQueue.removeAll { $0.clientMsgId == clientMsgId }
        if let job, job.clientMsgId == clientMsgId { stopJob(job) }
    }

    private func stopJob(_ j: UploadJob) {
        j.cancelled = true
        j.task?.cancel()
        if job === j { job = nil }
        if let f = j.fileId, !j.completed { cancelOnServer(f) }
        pumpUploads()
    }

    private func cancelOnServer(_ fileId: String) {
        guard let files else { return }
        Task { @MainActor in await files.cancelUpload(fileId) }
    }

    // MARK: Sandbox and cache

    private var userAttachmentDir: URL { attachmentRoot.appendingPathComponent(hexName(me)) }

    func sandboxFile(_ name: String) -> URL {
        userAttachmentDir.appendingPathComponent(name)
    }

    private func copyIn(_ file: URL, as name: String) throws {
        try FileManager.default.createDirectory(at: userAttachmentDir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = userAttachmentDir
        try? dir.setResourceValues(values)
        let dest = sandboxFile(name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: file, to: dest)
    }

    /// Drops a message's source: the sandbox copies, the producer, the progress handler.
    func releaseSource(_ clientMsgId: String) {
        if let src = sources.removeValue(forKey: clientMsgId) {
            for name in [src.original, src.thumb].compactMap({ $0 }) { try? FileManager.default.removeItem(at: sandboxFile(name)) }
        }
        producers[clientMsgId] = nil
        progressHandlers[clientMsgId] = nil
    }

    func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    private func cacheFile(_ fileId: String, _ variant: FileVariant) -> URL? {
        guard !me.isEmpty else { return nil }
        return fileCacheRoot.appendingPathComponent(hexName(me)).appendingPathComponent("\(hexName(fileId))-\(variant.rawValue)")
    }

    /// An expired, deleted or recalled file: running downloads stop (AC-RCL-03-12), its URLs and cached downloads go
    /// (F-FILE-06 rule 3, F-RCL-03 rule 3).
    func forgetFile(_ fileId: String, recalled: Bool = false) {
        if let running = downloads.removeValue(forKey: fileId) {
            for d in running.values {
                d.abortedRecalled = recalled
                d.task?.cancel()
            }
            emit(.downloadAborted(fileId: fileId, recalled: recalled))
        }
        files?.forget(fileId)
        for v in [FileVariant.original, .thumb] {
            if let f = cacheFile(fileId, v) { try? FileManager.default.removeItem(at: f) }
        }
    }

    /// Logout or kick: uploads stop, sandbox copies and cached downloads are deleted, URLs dropped (F-FILE-07 rule 2,
    /// AC-FILE-07-9).
    func clearFileData() {
        uploadQueue = []
        if let j = job { stopJob(j) }
        job = nil
        sources = [:]
        producers = [:]
        progressHandlers = [:]
        outboxWritten = [:]
        ownFileIds = []
        files?.clear()
        guard !me.isEmpty else { return }
        try? FileManager.default.removeItem(at: userAttachmentDir)
        try? FileManager.default.removeItem(at: fileCacheRoot.appendingPathComponent(hexName(me)))
    }

    // MARK: Outbox (F-FILE-07 rule 3)

    /// A cold start: processing and uploading turn failed (`.interrupted`), never resumed; a completed one (with a fileId)
    /// that was queued or sending is queued again, so the connection sends it once. Sandbox files nobody refers to are
    /// deleted.
    func restoreOutbox(_ rows: [(Message, AttachmentSource?)]) {
        outboxWritten = [:]
        var keep: Set<String> = []
        for (stored, src) in rows {
            var m = stored
            outboxWritten[m.clientMsgId] = OutboxRow(message: stored, source: src)
            // Only this device's own uploads are in the outbox, written after their complete.
            if let id = m.body.fileId { ownFileIds.insert(id) }
            switch m.status {
            case .processing, .uploading:
                m.status = .failed
                m.error = .interrupted
            case .queued, .sending:
                if m.body.fileId == nil {
                    m.status = .failed
                    m.error = .interrupted
                } else {
                    m.status = .queued
                }
            default: break
            }
            store.restoreUnsent(m)
            if let src {
                sources[m.clientMsgId] = src
                keep.formUnion([src.original, src.thumb].compactMap { $0 })
            }
        }
        if let names = try? FileManager.default.contentsOfDirectory(atPath: userAttachmentDir.path) {
            for n in names where !keep.contains(n) { try? FileManager.default.removeItem(at: sandboxFile(n)) }
        }
    }

    func writeOutbox(_ db: LocalDatabase) throws {
        var current: [String: OutboxRow] = [:]
        for m in store.unsentAttachments() {
            let src = sources[m.clientMsgId].flatMap { $0.pending ? nil : $0 }
            current[m.clientMsgId] = OutboxRow(message: m, source: src)
        }
        let upserts = current.values.filter { outboxWritten[$0.message.clientMsgId] != $0 }
        let deletes = outboxWritten.keys.filter { current[$0] == nil }
        try db.saveOutbox(upsert: upserts.map { ($0.message, $0.source) }, delete: Array(deletes))
        outboxWritten = current
    }
}

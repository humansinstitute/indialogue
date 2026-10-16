import Foundation

struct NStackDestination: Codable, Equatable {
    var origin: String
    var signer: String
    var workspace: String
    var workspaceLabel: String
    var appNpub: String
    var channel: String
    var channelLabel: String
    var recipient: String?
    var recipientLabel: String?
    var prompt: String
    var automatic: Bool
    func validate() throws {
        _ = try NStackAPI.origin(origin)
        guard UUID(uuidString: workspace) != nil, UUID(uuidString: channel) != nil,
              NostrCodec.validNpub(signer), NostrCodec.validNpub(appNpub),
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NStackError.invalidSetup }
        if let recipient { guard NostrCodec.validNpub(recipient), let label = recipientLabel, !label.isEmpty,
            !label.contains(where: { "[]()\n\r".contains($0) }) else { throw NStackError.invalidSetup } }
    }
}

enum DialogueMode: String, Codable, CaseIterable, Identifiable {
    case normal = "Normal"
    case channel = "Channel"
    case agent = "Agent"
    var id: String { rawValue }
}

/// Persistent capture choice. Channel and agent destinations are complete values so changing
/// the ordinary NStack setup cannot partially retarget one of these modes.
struct DialogueRouting: Codable, Equatable {
    var mode: DialogueMode = .normal
    var channel: NStackDestination?
    var agent: NStackDestination?

    func destination(normal: NStackDestination?) -> NStackDestination? {
        switch mode {
        case .normal: normal
        case .channel: channel
        case .agent: agent
        }
    }
}

/// Immutable route captured when recording begins. Follow-ups copy this value and add the
/// already-created thread rather than consulting mutable settings.
struct DialogueRouteSnapshot: Codable, Equatable {
    var conversationID = UUID()
    var mode: DialogueMode
    var destination: NStackDestination
    var threadID: String?
    /// The reply this capture answers. It is local lifecycle metadata and is not sent to Tower.
    var respondingToReplyID: String?
}

struct DialogueReply: Identifiable, Equatable {
    let id: String
    let body: String
    let sender: String
    let createdAt: Date?
    let audioObjectID: String?
}
enum NStackError: LocalizedError {
    case discoveryLimit
    case invalidSetup, unsafeURL, response(Int), malformed, incomplete, fallbackLimit, prepareUncertain
    case snapshotMismatch, storageMetadata, storageMismatch, storageIncomplete
    var errorDescription: String? {
        switch self {
        case .discoveryLimit: "NStack discovery reached a server list limit without a continuation cursor. Ask the administrator to provide paginated discovery; the list cannot be confirmed complete."
        case .invalidSetup: "Choose an HTTPS NStack, workspace, channel, unlocked identity and meaningful prompt. Check the recipient npub and label."
        case .unsafeURL: "NStack refused an unsafe URL or redirect. Use your selected HTTPS origin."
        case .response(let code): "NStack returned HTTP \(code). Check access and connection; local files retained."
        case .malformed: "NStack returned an unexpected response. Local files retained."
        case .incomplete: "Recording or export is incomplete. Review recording history; upload refused and audio retained."
        case .snapshotMismatch: "Local upload snapshot no longer matches its saved size or checksum. Upload refused; original audio retained."
        case .storageMetadata: "NStack storage returned invalid size or checksum metadata. Retry the same snapshot after the server response is corrected; local files retained."
        case .storageMismatch: "Stored upload size or checksum does not match the snapshot. Delivery refused; retry keeps the original objects and local files."
        case .storageIncomplete: "NStack has not confirmed storage completion. Retry the same snapshot; local files retained."
        case .fallbackLimit: "This backend uses JSON audio upload, limited to 8 MiB. Configure presigned storage for longer audio. Files retained."
        case .prepareUncertain: "Storage prepare response was uncertain. Retry cannot safely allocate another object. Cancel this snapshot and review remote storage before creating a new upload."
        }
    }
}
final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
@MainActor
final class NStackAPI {
    typealias Sign = (Int, [[String]], String) throws -> NostrEvent
    let sign: Sign
    let session: URLSession
    let backgroundUploads: BackgroundUploadClient
    init(session: URLSession? = nil, backgroundUploads: BackgroundUploadClient? = nil, sign: @escaping Sign) {
        self.sign = sign
        self.backgroundUploads = backgroundUploads ?? BackgroundUploadCoordinator.shared
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 45
        self.session = session ?? URLSession(configuration: config, delegate: RefuseRedirects(), delegateQueue: nil)
    }
    nonisolated static func origin(_ value: String) throws -> URL {
        guard let u = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)), u.scheme == "https", u.host != nil,
              u.user == nil, u.password == nil, u.query == nil, u.fragment == nil, u.path.isEmpty || u.path == "/" else { throw NStackError.unsafeURL }
        return u
    }
    nonisolated static func url(_ origin: String, _ path: String) throws -> URL {
        guard path.hasPrefix("/api/v4/"), let u = URL(string: path, relativeTo: try self.origin(origin))?.absoluteURL else { throw NStackError.unsafeURL }; return u
    }
    nonisolated static func authTags(url: URL, method: String, bytes: Data?) -> [[String]] {
        var tags = [["u", url.absoluteString], ["method", method]]
        if let bytes { tags.append(["payload", NostrCodec.hash(bytes)]) }; return tags
    }
    func request(origin: String, path: String, app: String? = nil, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        try Task.checkCancellation()
        let url = try Self.url(origin, path)
        let bytes = try body.map { try NostrCodec.json($0) }
        let event = try sign(27235, Self.authTags(url: url, method: method, bytes: bytes), "")
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = bytes
        request.setValue("Nostr " + (try JSONEncoder().encode(event)).base64EncodedString(), forHTTPHeaderField: "Authorization")
        if let app { request.setValue(app, forHTTPHeaderField: "x-flightdeck-pg-app-npub") }
        if bytes != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw NStackError.malformed }
        guard (200..<300).contains(http.statusCode) else { throw NStackError.response(http.statusCode) }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NStackError.malformed }
        return result
    }
    func download(origin: String, path: String, app: String? = nil) async throws -> Data {
        try Task.checkCancellation()
        let url = try Self.url(origin, path)
        let event = try sign(27235, Self.authTags(url:url,method:"GET",bytes:nil), "")
        var request = URLRequest(url:url)
        request.setValue("Nostr " + (try JSONEncoder().encode(event)).base64EncodedString(), forHTTPHeaderField:"Authorization")
        if let app { request.setValue(app,forHTTPHeaderField:"x-flightdeck-pg-app-npub") }
        let (data,response) = try await session.data(for:request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw NStackError.malformed }
        guard (200..<300).contains(http.statusCode) else { throw NStackError.response(http.statusCode) }
        return data
    }
    func putFile(_ file: URL, upload: String, origin: String, object: String, mime: String, size: Int) async throws {
        guard let url = URL(string: upload), url.user == nil, url.password == nil, url.fragment == nil else { throw NStackError.unsafeURL }
        let local = try Self.url(origin, "/api/v4/storage/\(object)")
        // API fallback can advertise HTTP behind a proxy: use only the pinned origin and exact object path.
        if url.path == local.path && url.host == local.host && url.query == nil && ["https","http"].contains(url.scheme ?? "") {
            guard size <= 8 * 1024 * 1024 else { throw NStackError.fallbackLimit }
            _ = try await request(origin: origin, path: local.path, method: "PUT", body: ["base64_data": try Data(contentsOf: file).base64EncodedString()]); return
        }
        guard url.scheme == "https", !url.path.hasPrefix("/api/v4/") else { throw NStackError.unsafeURL }
        var request = URLRequest(url: url); request.httpMethod = "PUT"; request.setValue(mime, forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: request, fromFile: file)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw NStackError.response((response as? HTTPURLResponse)?.statusCode ?? 0) }
    }
    /// The signed API fallback remains a bounded in-process operation. A presigned HTTPS PUT
    /// becomes a suspended background task so its ledger mapping can be persisted first.
    func makeBackgroundPut(_ file: URL, upload: String, origin: String, object: String,
                           mime: String, size: Int, description: String) async throws -> BackgroundUploadTask? {
        guard let url = URL(string:upload), url.user == nil, url.password == nil, url.fragment == nil else { throw NStackError.unsafeURL }
        let local = try Self.url(origin,"/api/v4/storage/\(object)")
        if url.path == local.path && url.host == local.host && url.query == nil && ["https","http"].contains(url.scheme ?? "") {
            guard size <= 8 * 1024 * 1024 else { throw NStackError.fallbackLimit }
            _ = try await request(origin:origin,path:local.path,method:"PUT",body:["base64_data":try Data(contentsOf:file).base64EncodedString()])
            return nil
        }
        guard url.scheme == "https", !url.path.hasPrefix("/api/v4/") else { throw NStackError.unsafeURL }
        var request = URLRequest(url:url); request.httpMethod = "PUT"; request.setValue(mime,forHTTPHeaderField:"Content-Type")
        return try backgroundUploads.makeUpload(request:request,file:file,description:description)
    }
    func message(_ job: TransferJob) throws -> [String: Any] {
        let d = job.destination; let hash = NostrCodec.hash(Data(job.body.utf8))
        var tags = [["protocol","flightdeck_pg_message_instruction"],["body_sha256",hash],["workspace_id",d.workspace],["channel_id",d.channel]]
        if let thread = job.threadID { tags.append(["thread_id",thread]) }
        let event = try sign(33358, tags, job.body)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event))
        var body: [String: Any] = ["body":job.body,"client_request_id":job.id.uuidString,
            "message_signature":["version":1,"protocol":"flightdeck_pg_message_instruction","kind":33358,"signer_npub":d.signer,"body_sha256":hash,"nostr_event":encoded],
            "metadata":["attachments":job.files.map { ["kind":"file","storage_object_id":$0.objectID ?? "","filename":$0.name,"mime_type":$0.mime,"size_bytes":$0.size] as [String:Any] },"recorder":["recording_id":job.recordingID.uuidString,"snapshot_id":job.id.uuidString,"version":1]]]
        if let thread = job.threadID { body["thread_id"] = thread }
        else { body["create_thread"] = true; body["thread_title"] = String(job.title.prefix(120)) }
        if let recipient = d.recipient { body["mentions"] = [["type":"agent","npub":recipient,"label":d.recipientLabel!]] }
        return body
    }
}

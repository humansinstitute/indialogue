import Foundation
import CryptoKit
import SwiftUI
import CoreFoundation
import AVFoundation
import UIKit

/// Storage APIs serialize bigint byte counts as either JSON integers or decimal strings.
enum StorageMetadata {
    static func byteCount(_ value: Any?) throws -> Int {
        let digits: String
        if let string = value as? String { digits = string }
        else if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(),
                  !["f", "d"].contains(String(cString: number.objCType)) else { throw NStackError.storageMetadata }
            digits = number.stringValue
        } else { throw NStackError.storageMetadata }
        guard !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let count = Int(digits) else { throw NStackError.storageMetadata }
        return count
    }
    static func isCompleted(_ metadata: [String:Any]) throws -> Bool {
        guard let value = metadata["completed_at"], !(value is NSNull) else { return false }
        guard let completed = value as? String, !completed.isEmpty else { throw NStackError.storageMetadata }
        return true
    }
    static func validateCompleted(_ metadata: [String:Any], file: TransferFile) throws {
        guard try isCompleted(metadata) else { throw NStackError.storageIncomplete }
        let size = try byteCount(metadata["size_bytes"])
        guard let checksum = metadata["sha256_hex"] as? String, checksum.utf8.count == 64,
              checksum.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }) else { throw NStackError.storageMetadata }
        guard size == file.size, checksum.lowercased() == file.checksum.lowercased() else { throw NStackError.storageMismatch }
    }
}

struct TransferFile: Codable, Equatable {
    var name: String
    var mime: String
    var size: Int
    var checksum: String
    var objectID: String?
    var uploadURL: String?
    var preparing = false
    var complete = false
    /// A successful PUT delegate callback is durable separately from storage completion/readback.
    /// Optional preserves decoding of build 11 ledgers.
    var putCompleted: Bool?
    var backgroundTaskID: Int?
    var backgroundTaskDescription: String?
}
struct TransferJob: Codable, Identifiable, Equatable {
    var id = UUID()
    let recordingID: UUID
    let destination: NStackDestination
    let title: String
    let body: String
    var createdAt = Date()
    var files: [TransferFile]
    var state = "queued"
    var notice: String?
    var attempts = 0
    var lastAttempt: Date?
    var messageID: String?
    var threadID: String?
    var conversationID: UUID?
    var dialogueMode: DialogueMode?
    var respondingToReplyID: String?
    var diagnostics: Bool?
}
struct AutomaticUploadIntent: Codable {
    let recordingID: UUID
    let destination: NStackDestination
    var route: DialogueRouteSnapshot?
    var notice: String?
}
struct DialogueReplyState: Codable, Equatable {
    var lastPlayedID: String?
    var lastRespondedID: String?
}
enum DialogueResponseStatus: Equatable {
    case pending
    case sending
    case failed(String?)
    case sent
}
enum ConversationDeliveryStatus: Equatable {
    case local
    case waiting
    case replied
    case failed
}
/// Independent of views. Atomic ledger contains no secret or Authorization headers.
@MainActor
final class NStackTransfers: ObservableObject {
    @Published private(set) var jobs: [TransferJob] = []
    @Published private(set) var destination: NStackDestination?
    @Published private(set) var routing = DialogueRouting()
    @Published private(set) var replies: [UUID:DialogueReply] = [:]
    @Published private(set) var replyStates: [UUID:DialogueReplyState] = [:]
    @Published var replyNotice: String?
    @Published private(set) var playingReplyID: String?
    @Published private(set) var recentConversationLimit: Int
    @Published var notice: String?
    private(set) var intents: [AutomaticUploadIntent] = []
    let root: URL
    let diagnosticsLog: DiagnosticsLog
    private var readable = true
    private var worker: Task<Void, Never>?
    private var allowed = false
    private var currentSigner: String?
    private var api: NStackAPI?
    private var reconcilingBackgroundTasks = false
    private var missingBackgroundTasks = Set<String>()
    private var backgrounded = false
    private var backgroundExecution: UIBackgroundTaskIdentifier = .invalid
    private(set) var replyRefreshJobID: UUID?
    private var replyPlayer: AVAudioPlayer?
    private let speech = AVSpeechSynthesizer()
    let replyVoice: ReplyVoice
    private let speakReply: ((AVSpeechUtterance) -> Void)?
    private let defaults: UserDefaults
    static let defaultRecentConversationLimit = 5
    static let recentConversationLimitRange = 1...50
    static let recentConversationLimitKey = "recentConversationLimit"
    private lazy var playbackDelegate = ReplyPlaybackDelegate { [weak self] in
        Task { @MainActor in
            self?.diagnosticsLog.record(.playbackFinished)
            self?.replyPlayer = nil
            self?.playingReplyID = nil
        }
    }
    struct Ledger: Codable {
        var jobs: [TransferJob]
        var intents: [AutomaticUploadIntent]
        var destination: NStackDestination?
        var routing: DialogueRouting
        var replyStates: [UUID:DialogueReplyState]
        enum CodingKeys: String, CodingKey { case jobs, intents, destination, routing, replyStates }
        init(jobs:[TransferJob],intents:[AutomaticUploadIntent],destination:NStackDestination?,routing:DialogueRouting = DialogueRouting(),replyStates:[UUID:DialogueReplyState] = [:]) {
            self.jobs = jobs; self.intents = intents; self.destination = destination; self.routing = routing; self.replyStates = replyStates
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy:CodingKeys.self)
            jobs = try c.decodeIfPresent([TransferJob].self,forKey:.jobs) ?? []
            intents = try c.decodeIfPresent([AutomaticUploadIntent].self,forKey:.intents) ?? []
            destination = try c.decodeIfPresent(NStackDestination.self,forKey:.destination)
            routing = try c.decodeIfPresent(DialogueRouting.self,forKey:.routing) ?? DialogueRouting()
            replyStates = try c.decodeIfPresent([UUID:DialogueReplyState].self,forKey:.replyStates) ?? [:]
        }
    }
    init(root: URL, defaults providedDefaults: UserDefaults? = nil, speakReply: ((AVSpeechUtterance) -> Void)? = nil) {
        self.root = root
        diagnosticsLog = DiagnosticsLog(root:root.appendingPathComponent("Diagnostics"))
        self.speakReply = speakReply
        defaults = providedDefaults ?? .standard
        replyVoice = ReplyVoice(defaults: providedDefaults ?? .standard)
        recentConversationLimit = Self.validatedRecentConversationLimit(
            defaults.object(forKey: Self.recentConversationLimitKey)
        )
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var dir = root; var values = URLResourceValues(); values.isExcludedFromBackup = true; try dir.setResourceValues(values)
            let path = root.appendingPathComponent("ledger.json")
            if FileManager.default.fileExists(atPath: path.path) {
                let ledger = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: path))
                jobs = ledger.jobs; intents = ledger.intents; destination = ledger.destination; routing = ledger.routing; replyStates = ledger.replyStates
                for i in jobs.indices where ["uploading","posting"].contains(jobs[i].state) { jobs[i].state = "queued" }
            }
        } catch { readable = false; notice = "Transfer ledger unreadable; retained and cannot be overwritten. \(error.localizedDescription)" }
    }
    static func validatedRecentConversationLimit(_ value: Any?) -> Int {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return defaultRecentConversationLimit }
        return recentConversationLimitRange.contains(number.intValue) ? number.intValue : defaultRecentConversationLimit
    }
    @discardableResult func saveRecentConversationLimit(_ text: String) -> Bool {
        guard let value = Int(text), Self.recentConversationLimitRange.contains(value) else { return false }
        recentConversationLimit = value
        defaults.set(value, forKey: Self.recentConversationLimitKey)
        return true
    }
    var onIdle: (() -> Void)?
    var retentionReady: Bool { readable && worker == nil }
    func retentionProtects(_ id: UUID) -> Bool {
        intents.contains { $0.recordingID == id } || jobs.contains {
            $0.recordingID == id && !["sent", "cancelled"].contains($0.state)
        }
    }
    /// Remove finished local snapshots and their transcript-bearing ledger entries; never remote objects.
    func deleteFinishedLocalArtifacts(_ id: UUID) throws {
        guard retentionReady, !retentionProtects(id) else { throw NStackError.incomplete }
        let removedConversations = Set(jobs.filter { $0.recordingID == id }.compactMap(\.conversationID))
        for job in jobs where job.recordingID == id {
            let directory = root.appendingPathComponent(job.id.uuidString)
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        }
        let previous = jobs, previousReplyStates = replyStates
        jobs.removeAll { $0.recordingID == id }
        for conversation in removedConversations where !jobs.contains(where: { $0.conversationID == conversation }) {
            replyStates.removeValue(forKey:conversation)
        }
        do { try persist() }
        catch { jobs = previous; replyStates = previousReplyStates; throw error }
    }
    func persist() throws {
        guard readable else { throw NStackError.malformed }
        try JSONEncoder().encode(Ledger(jobs:jobs,intents:intents,destination:destination,routing:routing,replyStates:replyStates)).write(to: root.appendingPathComponent("ledger.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func save(_ d: NStackDestination) throws { try d.validate(); destination = d; try persist() }
    func setMode(_ mode: DialogueMode) throws { routing.mode = mode; try persist() }
    func saveRoute(_ destination: NStackDestination, mode: DialogueMode) throws {
        try destination.validate()
        switch mode {
        case .normal: self.destination = destination
        case .channel:
            guard destination.recipient == nil else { throw NStackError.invalidSetup }
            routing.channel = destination
        case .agent:
            guard destination.recipient != nil else { throw NStackError.invalidSetup }
            routing.agent = destination
        }
        routing.mode = mode
        try persist()
    }
    func savedRoute(for mode: DialogueMode) -> NStackDestination? {
        switch mode {
        case .normal: destination
        case .channel: routing.channel
        case .agent: routing.agent
        }
    }
    /// A new mode reuses a valid installation-level connection without mutating any saved route.
    func setupSeed(for mode: DialogueMode, signer: String?) -> (destination: NStackDestination, saved: Bool)? {
        if let saved = savedRoute(for:mode), saved.signer == signer, (try? saved.validate()) != nil {
            return (saved, true)
        }
        for candidate in [destination, routing.channel, routing.agent].compactMap({ $0 })
        where candidate.signer == signer && (try? candidate.validate()) != nil {
            return (candidate, false)
        }
        return nil
    }
    func captureRoute() -> DialogueRouteSnapshot? {
        guard let selected = routing.destination(normal:destination) else { return nil }
        return DialogueRouteSnapshot(mode:routing.mode,destination:selected,threadID:nil)
    }
    func followupRoute(for job: TransferJob) -> DialogueRouteSnapshot? {
        guard let thread = job.threadID, let conversation = job.conversationID else { return nil }
        return DialogueRouteSnapshot(conversationID:conversation,mode:job.dialogueMode ?? job.routeMode,destination:job.destination,threadID:thread)
    }
    var latestConversationJob: TransferJob? {
        jobs.reversed().first { $0.state == "sent" && $0.threadID != nil && $0.conversationID != nil }
    }
    var recentConversationJobs: [TransferJob] {
        var seen = Set<UUID>()
        return jobs.sorted { $0.createdAt > $1.createdAt }.filter { job in
            guard job.state != "cancelled", let conversation = job.conversationID,
                  seen.insert(conversation).inserted else { return false }
            return true
        }.prefix(recentConversationLimit).map { $0 }
    }
    func conversationStatus(for job: TransferJob) -> ConversationDeliveryStatus {
        if let conversation = job.conversationID, let reply = replies[conversation] {
            switch responseStatus(to:reply,for:job.id) {
            case .pending?, .sending?, .sent?: return .waiting
            case .failed?, nil: return .replied
            }
        }
        if job.state == "sent" { return .waiting }
        if job.state == "failed" { return .failed }
        return .local
    }
    @discardableResult func rememberNew(_ r: Recording, force: Bool = false) -> Bool {
        let route = r.dialogueRoute
        guard let d = route?.destination ?? destination, force || d.automatic else { return false }
        guard !intents.contains(where: { $0.recordingID == r.id }) else { return true }
        intents.append(AutomaticUploadIntent(recordingID:r.id,destination:d,route:route))
        do { try persist(); return true }
        catch {
            intents.removeAll { $0.recordingID == r.id }
            notice = error.localizedDescription
            return false
        }
    }
    func snapshotFailed(_ id: UUID, error: Error) {
        if let i = intents.firstIndex(where: { $0.recordingID == id }) { intents[i].notice = error.localizedDescription }
        notice = error.localizedDescription
        do { try persist() } catch { notice = error.localizedDescription }
    }
    func status(_ id: UUID) -> String? {
        if let j = jobs.last(where: { $0.recordingID == id }) { return j.state.replacingOccurrences(of: "_", with: " ") + (j.notice.map { " · " + $0 } ?? "") }
        if let intent = intents.first(where: { $0.recordingID == id }) { return intent.notice ?? "Waiting for transcription or upload preparation" }; return nil
    }
    static func checksum(_ url: URL) throws -> (Int,String) {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256(); var count = 0
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes); count += bytes.count }
        return (count,Data(hash.finalize()).hex)
    }
    func enqueue(_ r: Recording, destination d: NStackDestination, audio: URL, corrected: String) throws {
        try enqueue(r,route:r.dialogueRoute ?? DialogueRouteSnapshot(mode:.normal,destination:d,threadID:nil),audio:audio,corrected:corrected)
    }
    func enqueue(_ r: Recording, route: DialogueRouteSnapshot, audio: URL, corrected: String) throws {
        let d = route.destination
        try d.validate()
        guard r.state == .saved, r.deliveryReady, !r.segments.isEmpty else { throw NStackError.incomplete }
        guard !jobs.contains(where: { $0.recordingID == r.id && $0.state != "cancelled" }) else { return }
        let id = UUID(); let directory = root.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioTarget = directory.appendingPathComponent("recording.m4a")
        try FileManager.default.copyItem(at: audio, to: audioTarget)
        let (size, hash) = try Self.checksum(audioTarget)
        var artifact: [String:Any] = ["version":1,"recording_id":r.id.uuidString,"snapshot_id":id.uuidString,"title":r.title,"created_at":ISO8601DateFormatter().string(from:r.createdAt),"duration_seconds":r.duration,"events":r.events,"transcription_status":r.deliveryContent == .audioOnly ? "not_requested" : "complete","transcript_attached":r.deliveryContent == .transcriptAndAudio,"prompt":d.prompt,"audio_sha256":hash,"audio_size_bytes":size,"destination_workspace":d.workspace,"destination_channel":d.channel,"signer_npub":d.signer]
        if r.deliveryContent == .transcriptAndAudio {
            artifact["raw_transcript"] = r.transcript ?? ""
            artifact["corrected_transcript"] = corrected
        } else {
            artifact["transcription_requested"] = "agent_or_server"
        }
        let transcript = try NostrCodec.json(artifact); try transcript.write(to: directory.appendingPathComponent("transcript.json"), options: .atomic)
        let mention = d.recipient.map { "@[\(d.recipientLabel!)](mention:agent:\($0))\n\n" } ?? ""
        let content = r.deliveryContent == .audioOnly
            ? "The attached audio is the source recording. Please transcribe and process it on the agent/server. No transcript is attached."
            : String(corrected.prefix(4000)) + "\n\nFull corrected transcript and audio attached."
        let body = (mention + d.prompt + "\n\n" + r.title + "\n\n" + content).trimmingCharacters(in: .whitespacesAndNewlines)
        jobs.append(TransferJob(id:id,recordingID:r.id,destination:d,title:r.title.isEmpty ? "Recording" : r.title,body:body,files:[TransferFile(name:"recording.m4a",mime:"audio/mp4",size:size,checksum:hash),TransferFile(name:"transcript.json",mime:"application/json",size:transcript.count,checksum:NostrCodec.hash(transcript))],threadID:route.threadID,conversationID:route.conversationID,dialogueMode:route.mode,respondingToReplyID:route.respondingToReplyID))
        let last = jobs.count - 1
        if currentSigner == nil { jobs[last].state = "paused_locked"; jobs[last].notice = "Unlock identity while the app is active to send." }
        else if currentSigner != d.signer { jobs[last].state = "paused_identity" }
        else if !allowed { jobs[last].state = "paused_capture_or_background" }
        intents.removeAll { $0.recordingID == r.id }
        try persist(); resume()
    }
    /// A separate report job: no Recording, transcript, prompt, agent mention or conversation.
    func enqueueDiagnostics(snapshot: RecorderDiagnosticSnapshot) throws {
        guard worker == nil, !reconcilingBackgroundTasks else { throw DiagnosticsError.busy }
        guard readable, var d = routing.destination(normal:destination) else { throw NStackError.invalidSetup }
        guard currentSigner == d.signer else { throw NStackError.invalidSetup }
        d.recipient = nil; d.recipientLabel = nil; d.prompt = "Operational diagnostics"; d.automatic = false
        try d.validate()
        // Bound report snapshots as well as the event log. Never discard pending reports.
        let reports = jobs.filter { $0.diagnostics == true }
        guard !reports.contains(where: { !["sent","cancelled"].contains($0.state) }) else { throw DiagnosticsError.pending }
        // Also remove report-only orphans left by termination before ledger commit.
        let pendingIDs = Set(jobs.filter { $0.diagnostics == true && !["sent","cancelled"].contains($0.state) }.map { $0.id.uuidString })
        for directory in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil) {
            guard !pendingIDs.contains(directory.lastPathComponent),
                  FileManager.default.fileExists(atPath:directory.appendingPathComponent("diagnostics.json").path) else { continue }
            try FileManager.default.removeItem(at:directory)
        }
        jobs.removeAll { $0.diagnostics == true }
        let data = try diagnosticsLog.report(snapshot:snapshot)
        let id = UUID()
        // Use the job ID for the immutable snapshot path, as ordinary transfers do.
        let target = root.appendingPathComponent(id.uuidString)
        do {
            try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
            try data.write(to:target.appendingPathComponent("diagnostics.json"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        } catch { try? FileManager.default.removeItem(at:target); throw error }
        let job = TransferJob(id:id,recordingID:id,destination:d,title:"In Dialogue diagnostics",
            body:"In Dialogue operational diagnostics. Private JSON report attached; no audio or message content.",
            files:[TransferFile(name:"diagnostics.json",mime:"application/json",size:data.count,checksum:NostrCodec.hash(data))],diagnostics:true)
        jobs.append(job)
        do { try persist() } catch { jobs.removeLast(); try? FileManager.default.removeItem(at:target); throw error }
        resume()
    }
    var diagnosticsDestinationLabel: String? {
        routing.destination(normal:destination).map { $0.workspaceLabel + " → " + $0.channelLabel }
    }
    var diagnosticsStatus: String? {
        guard let job = jobs.last(where:{$0.diagnostics == true}) else { return nil }
        if job.state == "sent", let object = job.files.first?.objectID {
            return "Diagnostics sent to \(job.destination.channelLabel). Report: storage://\(object)"
        }
        return "Diagnostics: \(job.state). Use NStack uploads to retry or cancel."
    }
    func setAvailability(active: Bool, signer: String?, api: NStackAPI) {
        self.api = api; currentSigner = signer; allowed = active && signer != nil
        api.backgroundUploads.onEvents = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.reconcileBackgroundTransfers() }
        }
        if !allowed { worker?.cancel(); stopReply() }
        for i in jobs.indices where !["sent","cancelled","failed","background_uploading"].contains(jobs[i].state) {
            if !active { jobs[i].state = "paused_capture_or_background" }
            else if signer == nil { jobs[i].state = "paused_locked" }
            else if signer != jobs[i].destination.signer { jobs[i].state = "paused_identity" }
            else { jobs[i].state = "queued" }
        }
        do { try persist() } catch { notice = error.localizedDescription }
        Task { await reconcileBackgroundTransfers() }
        resume()
    }
    func enterBackground() {
        backgrounded = true
        stopReply()
        if worker != nil { beginBackgroundExecution() }
    }
    private func beginBackgroundExecution() {
        guard backgroundExecution == .invalid else { return }
        backgroundExecution = UIApplication.shared.beginBackgroundTask(withName:"Finish recording delivery") { [weak self] in
            Task { @MainActor in self?.backgroundExecutionExpired() }
        }
    }
    func enterForeground() {
        backgrounded = false
        endBackgroundExecution()
        resume()
    }
    func backgroundExecutionExpired() {
        guard backgroundExecution != .invalid || backgrounded else { return }
        worker?.cancel()
        endBackgroundExecution()
    }
    private func endBackgroundExecution() {
        guard backgroundExecution != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundExecution)
        backgroundExecution = .invalid
    }
    func retry(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state != "sent", jobs[i].state != "cancelled" else { return }
        if jobs[i].state == "failed" {
            for file in jobs[i].files.indices where jobs[i].files[file].backgroundTaskID != nil {
                jobs[i].files[file].backgroundTaskID = nil
                jobs[i].files[file].backgroundTaskDescription = nil
            }
        }
        diagnosticsLog.record(.deliveryRetry)
        jobs[i].state = currentSigner == nil ? "paused_locked" : currentSigner != jobs[i].destination.signer ? "paused_identity" : !allowed ? "paused_capture_or_background" : "queued"; jobs[i].notice = nil
        do { try persist() } catch { notice = error.localizedDescription }; resume()
    }
    func sendPendingConversation(_ id: UUID) {
        guard let job = jobs.first(where:{$0.id == id}),
              !["uploading","posting","background_uploading"].contains(job.state) else { return }
        retry(id)
    }
    func cancel(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state != "sent" else { return }
        worker?.cancel()
        if let api { for task in jobs[i].files.compactMap(\.backgroundTaskID) { api.backgroundUploads.cancel(task) } }
        jobs[i].state = "cancelled"; jobs[i].notice = "Local cancellation retains files. It cannot retract an already committed remote message."
        do { try persist() } catch { notice = error.localizedDescription }
    }
    func resume() {
        guard readable, allowed, worker == nil, jobs.contains(where: { $0.state == "queued" && $0.destination.signer == currentSigner }), let api else { return }
        if backgrounded { beginBackgroundExecution() }
        worker = Task {
            defer { worker = nil; onIdle?(); if backgrounded { endBackgroundExecution() }; if allowed { resume() } }
            while let i = jobs.firstIndex(where: { $0.state == "queued" && $0.destination.signer == currentSigner }), allowed, !Task.isCancelled {
                do { try await send(i, api:api) }
                catch {
                    diagnosticsLog.record(.deliveryFailed, interrupted:Task.isCancelled, reason:DiagnosticReason.failure(error))
                    if jobs[i].state != "cancelled" {
                        jobs[i].state = Task.isCancelled ? (currentSigner == nil ? "paused_locked" : allowed ? "queued" : "paused_capture_or_background") : "failed"
                        jobs[i].notice = Task.isCancelled ? "Finalization was interrupted and will resume safely when execution is available." : error.localizedDescription
                    }
                    do { try persist() } catch { notice = error.localizedDescription }
                    if Task.isCancelled { break }
                }
            }
        }
    }
    private func send(_ i: Int, api: NStackAPI) async throws {
        let d = jobs[i].destination
        diagnosticsLog.record(.deliveryAttempt, count:jobs[i].attempts + 1)
        jobs[i].attempts += 1; jobs[i].lastAttempt = Date(); jobs[i].state = "uploading"; try persist()
        for f in jobs[i].files.indices {
            try Task.checkCancellation()
            if jobs[i].files[f].complete { continue }
            let file = jobs[i].files[f]; let path = root.appendingPathComponent(jobs[i].id.uuidString).appendingPathComponent(file.name)
            let actual = try Self.checksum(path)
            guard actual.0 == file.size, actual.1 == file.checksum else { throw NStackError.snapshotMismatch }
            if file.objectID == nil {
                guard !file.preparing else { throw NStackError.prepareUncertain }
                jobs[i].files[f].preparing = true; try persist()
                let prepared = try await api.request(origin:d.origin,path:"/api/v4/flightdeck-pg/workspaces/\(d.workspace)/storage/prepare",app:d.appNpub,method:"POST",body:["file_name":file.name,"content_type":file.mime,"size_bytes":file.size,"sha256_hex":file.checksum,"is_public":false,"metadata":["purpose":"recorder-upload","snapshot_id":jobs[i].id.uuidString]])
                guard let id = prepared["object_id"] as? String, UUID(uuidString:id) != nil, let upload = prepared["upload_url"] as? String else { throw NStackError.malformed }
                jobs[i].files[f].objectID = id; jobs[i].files[f].uploadURL = upload; jobs[i].files[f].preparing = false; try persist()
            }
            let object = jobs[i].files[f].objectID!
            let metadata = try await api.request(origin:d.origin,path:"/api/v4/storage/\(object)")
            if try StorageMetadata.isCompleted(metadata) {
                try StorageMetadata.validateCompleted(metadata, file: file)
            } else {
                if jobs[i].files[f].putCompleted != true {
                    if jobs[i].files[f].backgroundTaskID != nil {
                        jobs[i].state = "background_uploading"; try persist(); return
                    }
                    let description = Self.backgroundDescription(job:jobs[i].id,file:file.name)
                    if let task = try await api.makeBackgroundPut(path,upload:jobs[i].files[f].uploadURL!,origin:d.origin,object:object,mime:file.mime,size:file.size,description:description) {
                        jobs[i].files[f].backgroundTaskID = task.identifier
                        jobs[i].files[f].backgroundTaskDescription = description
                        jobs[i].state = "background_uploading"
                        jobs[i].notice = "File transfer continues using iOS background delivery."
                        try persist()
                        api.backgroundUploads.resume(task.identifier)
                        return
                    }
                    jobs[i].files[f].putCompleted = true
                    try persist()
                }
                _ = try await api.request(origin:d.origin,path:"/api/v4/storage/\(object)/complete",method:"POST",body:["size_bytes":file.size,"sha256_hex":file.checksum])
                let readback = try await api.request(origin:d.origin,path:"/api/v4/storage/\(object)")
                try StorageMetadata.validateCompleted(readback, file: file)
            }
            jobs[i].files[f].complete = true; try persist()
            diagnosticsLog.record(.storageComplete)
        }
        try Task.checkCancellation(); jobs[i].state = "posting"; try persist()
        let response = try await api.request(origin:d.origin,path:"/api/v4/flightdeck-pg/workspaces/\(d.workspace)/channels/\(d.channel)/messages",app:d.appNpub,method:"POST",body:api.message(jobs[i]))
        guard let message = response["message"] as? [String:Any], let id = message["id"] as? String else { throw NStackError.malformed }
        jobs[i].messageID = id; jobs[i].threadID = (response["thread"] as? [String:Any])?["id"] as? String ?? message["thread_id"] as? String
        jobs[i].state = "sent"; jobs[i].notice = nil
        diagnosticsLog.record(.deliverySent)
        if let conversation = jobs[i].conversationID, let replyID = jobs[i].respondingToReplyID {
            var replyState = replyStates[conversation] ?? DialogueReplyState()
            replyState.lastRespondedID = replyID
            replyStates[conversation] = replyState
        }
        try persist()
    }

    static func backgroundDescription(job: UUID, file: String) -> String { "v1|\(job.uuidString)|\(file)" }

    private func fileIndex(for event: BackgroundUploadEvent) -> (Int, Int)? {
        for job in jobs.indices {
            for file in jobs[job].files.indices {
                let candidate = jobs[job].files[file]
                if candidate.backgroundTaskID == event.identifier ||
                    (event.description != nil && candidate.backgroundTaskDescription == event.description) {
                    return (job,file)
                }
            }
        }
        return nil
    }

    func reconcileBackgroundTransfers() async {
        guard !reconcilingBackgroundTasks, let api else { return }
        reconcilingBackgroundTasks = true
        defer { reconcilingBackgroundTasks = false }

        let events = api.backgroundUploads.drainEvents()
        var ledgerChanged = !events.isEmpty
        for event in events {
            guard let (job,file) = fileIndex(for:event), !["sent","cancelled"].contains(jobs[job].state) else { continue }
            if let description = jobs[job].files[file].backgroundTaskDescription { missingBackgroundTasks.remove(description) }
            jobs[job].files[file].backgroundTaskID = nil
            jobs[job].files[file].backgroundTaskDescription = nil
            if event.succeeded {
                jobs[job].files[file].putCompleted = true
                jobs[job].state = resumableState(for:jobs[job])
                jobs[job].notice = jobs[job].state == "queued" ? nil : "File transfer finished; unlock the matching identity to finalize delivery."
            } else {
                diagnosticsLog.record(.deliveryFailed, reason:.offline)
                jobs[job].state = "failed"
                let detail = event.errorDescription ?? event.statusCode.map { "HTTP \($0)" } ?? "unknown response"
                jobs[job].notice = "Background file transfer was interrupted (\(detail)). Retry uses the same saved object and upload URL."
            }
        }

        let live = await api.backgroundUploads.tasks()
        let liveIDs = Set(live.map(\.identifier))
        let liveDescriptions = Set(live.compactMap(\.description))
        for job in jobs.indices where jobs[job].state == "background_uploading" {
            for file in jobs[job].files.indices {
                guard let id = jobs[job].files[file].backgroundTaskID else { continue }
                let description = jobs[job].files[file].backgroundTaskDescription
                if liveIDs.contains(id) || description.map({ liveDescriptions.contains($0) }) == true {
                    if let description { missingBackgroundTasks.remove(description) }
                    continue
                }
                let key = description ?? "task:\(id)"
                guard missingBackgroundTasks.contains(key) else {
                    missingBackgroundTasks.insert(key)
                    Task { @MainActor [weak self] in
                        // Delegate callbacks and getAllTasks are delivered on independent queues.
                        // Give a completed task's callback time to win before declaring it missing.
                        try? await Task.sleep(for:.seconds(5))
                        await self?.reconcileBackgroundTransfers()
                    }
                    continue
                }
                missingBackgroundTasks.remove(key)
                jobs[job].files[file].backgroundTaskID = nil
                jobs[job].files[file].backgroundTaskDescription = nil
                jobs[job].state = "failed"
                jobs[job].notice = "The saved background transfer is no longer registered with iOS. Retry uses the same object and upload URL; no new object was created."
                ledgerChanged = true
            }
        }
        if ledgerChanged {
            do { try persist() }
            catch {
                notice = error.localizedDescription
                api.backgroundUploads.requeueEvents(events)
                return
            }
        }
        api.backgroundUploads.reconciliationDrained()
        resume()
    }

    private func resumableState(for job: TransferJob) -> String {
        if currentSigner == nil { return "paused_locked" }
        if currentSigner != job.destination.signer { return "paused_identity" }
        return allowed ? "queued" : "paused_capture_or_background"
    }

    static let replyPollInterval: Duration = .seconds(20)
    typealias ReplyPollDelay = (Duration) async throws -> Void
    func pollReplies(for jobID: UUID, interval: Duration = replyPollInterval, autoPlay: Bool = true,
                     delay: @escaping ReplyPollDelay = { try await Task<Never, Never>.sleep(for:$0) }) async {
        while allowed, !Task.isCancelled {
            if let reply = await refreshReply(for:jobID), autoPlay { autoPlayReplyIfNeeded(reply,for:jobID) }
            guard allowed, !Task.isCancelled else { return }
            do { try await delay(interval) }
            catch { return }
        }
    }
    func beginReplyRefresh(for jobID: UUID) -> Bool {
        guard replyRefreshJobID == nil else { return false }
        replyRefreshJobID = jobID
        return true
    }
    func finishReplyRefresh(for jobID: UUID) {
        if replyRefreshJobID == jobID { replyRefreshJobID = nil }
    }
    @discardableResult func storeReply(_ reply: DialogueReply, for conversation: UUID) -> Bool {
        guard replies[conversation]?.id != reply.id else { return false }
        replies[conversation] = reply
        return true
    }
    @discardableResult func refreshReply(for jobID: UUID) async -> DialogueReply? {
        guard allowed, let api, let job = jobs.first(where:{$0.id == jobID}), job.state == "sent",
              currentSigner == job.destination.signer, let thread = job.threadID,
              let conversation = job.conversationID else { replyNotice = "Replies refresh only in the foreground with the matching identity unlocked."; return nil }
        guard beginReplyRefresh(for:jobID) else { return nil }
        diagnosticsLog.record(.replyRefresh)
        defer { finishReplyRefresh(for:jobID) }
        do {
            let base = "/api/v4/flightdeck-pg/workspaces/\(job.destination.workspace)/channels/\(job.destination.channel)/messages"
            let own = Set(jobs.filter{$0.conversationID == conversation}.compactMap(\.messageID))
            let allowedQuery = CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"-._~"))
            let encodedThread = thread.addingPercentEncoding(withAllowedCharacters:allowedQuery) ?? thread
            var cursor: String?, seen = Set<String>(), newest: DialogueReply?
            repeat {
                var path = base + "?thread_id=" + encodedThread + "&effective_transcript=true&limit=200"
                if let cursor {
                    guard seen.insert(cursor).inserted else { throw NStackError.malformed }
                    path += "&cursor=" + (cursor.addingPercentEncoding(withAllowedCharacters:allowedQuery) ?? cursor)
                }
                let result = try await api.request(origin:job.destination.origin,path:path,app:job.destination.appNpub)
                guard let messages = result["messages"] as? [[String:Any]] else { throw NStackError.malformed }
                for message in messages {
                    if let id = message["id"] as? String, own.contains(id) { continue }
                    if let reply = try Self.reply(message) {
                        // The typed endpoint guarantees created_at ASC, id ASC across pages.
                        newest = reply
                    }
                }
                cursor = result["next_cursor"] as? String
            } while cursor != nil
            try Task.checkCancellation()
            guard allowed, currentSigner == job.destination.signer else { return nil }
            if let newest {
                diagnosticsLog.record(.replyReceived)
                let inserted = storeReply(newest,for:conversation)
                replyNotice = nil
                return inserted ? newest : nil
            }
            replyNotice = "No new reply yet. Pull to refresh or tap the refresh icon while the app is in the foreground."
        } catch {
            diagnosticsLog.record(.replyFailed, interrupted:Task.isCancelled, reason:DiagnosticReason.failure(error))
            if !Task.isCancelled { replyNotice = error.localizedDescription }
        }
        return nil
    }
    static func reply(_ message: [String:Any]) throws -> DialogueReply? {
        if message["record_state"] as? String == "deleted" { return nil }
        if let deletedAt = message["deleted_at"], !(deletedAt is NSNull) { return nil }
        let metadata = message["metadata"] as? [String:Any]
        if let recorder = metadata?["recorder"], !(recorder is NSNull) { return nil }
        guard let id = message["id"] as? String, !id.isEmpty,
              let body = message["body"] as? String else { throw NStackError.malformed }
        let attachments = message["attachments"] as? [[String:Any]] ?? metadata?["attachments"] as? [[String:Any]] ?? []
        let audio = attachments.first { entry in
            let mime = entry["mime_type"] as? String ?? entry["content_type"] as? String ?? ""
            return mime.lowercased().hasPrefix("audio/")
        }?["storage_object_id"] as? String
        let date = (message["created_at"] as? String).flatMap(Self.replyDate)
        let sender = message["created_by_actor_label"] as? String ?? message["sender_label"] as? String ?? "Reply"
        return DialogueReply(id:id,body:body,sender:sender,createdAt:date,audioObjectID:audio)
    }
    private static func replyDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from:value) ?? ISO8601DateFormatter().date(from:value)
    }
    func refreshAndPlayReply(for jobID: UUID) async {
        if let reply = await refreshReply(for:jobID) { autoPlayReplyIfNeeded(reply,for:jobID) }
    }
    func refreshRecentReplies() async {
        var played = false
        for job in recentConversationJobs where job.state == "sent" && job.threadID != nil {
            if let reply = await refreshReply(for:job.id), !played {
                autoPlayReplyIfNeeded(reply,for:job.id)
                played = true
            }
        }
    }
    func claimReplyPlayback(_ reply: DialogueReply, for jobID: UUID) -> Bool {
        guard let conversation = jobs.first(where:{$0.id == jobID})?.conversationID,
              replyStates[conversation]?.lastPlayedID != reply.id else { return false }
        var state = replyStates[conversation] ?? DialogueReplyState()
        state.lastPlayedID = reply.id; replyStates[conversation] = state
        do { try persist() } catch { notice = error.localizedDescription }
        return true
    }
    func responseStatus(to reply: DialogueReply, for jobID: UUID) -> DialogueResponseStatus? {
        guard let conversation = jobs.first(where:{$0.id == jobID})?.conversationID else { return nil }
        if replyStates[conversation]?.lastRespondedID == reply.id { return .sent }
        if let response = jobs.reversed().first(where: {
            $0.conversationID == conversation && $0.respondingToReplyID == reply.id && $0.state != "cancelled"
        }) {
            switch response.state {
            case "sent": return .sent
            case "uploading", "posting": return .sending
            case "failed": return .failed(response.notice)
            default: return .pending
            }
        }
        if intents.contains(where: {
            $0.route?.conversationID == conversation && $0.route?.respondingToReplyID == reply.id
        }) { return .pending }
        return nil
    }
    func retryResponse(to reply: DialogueReply, for jobID: UUID) {
        guard let conversation = jobs.first(where:{$0.id == jobID})?.conversationID,
              let response = jobs.reversed().first(where: {
                  $0.conversationID == conversation && $0.respondingToReplyID == reply.id && $0.state == "failed"
              }) else { return }
        retry(response.id)
    }
    func autoPlayReplyIfNeeded(_ reply: DialogueReply, for jobID: UUID) {
        guard claimReplyPlayback(reply,for:jobID) else { return }
        startReplyPlayback(reply,for:jobID)
    }
    func toggleReplyPlayback(_ reply: DialogueReply, for jobID: UUID) {
        if playingReplyID == reply.id { stopReply(); return }
        _ = claimReplyPlayback(reply,for:jobID)
        startReplyPlayback(reply,for:jobID)
    }
    private func startReplyPlayback(_ reply: DialogueReply, for jobID: UUID) {
        stopReply(); playingReplyID = reply.id
        diagnosticsLog.record(.playbackStart)
        if let object = reply.audioObjectID, let job = jobs.first(where:{$0.id == jobID}), let api, allowed {
            Task {
                do {
                    let data = try await api.download(origin:job.destination.origin,path:"/api/v4/storage/\(object)/content",app:job.destination.appNpub)
                    guard playingReplyID == reply.id else { return }
                    replyPlayer = try AVAudioPlayer(data:data)
                    replyPlayer?.delegate = playbackDelegate
                    guard replyPlayer?.play() == true else { throw NStackError.malformed }
                } catch { diagnosticsLog.record(.playbackFailed, reason:DiagnosticReason.failure(error)); playingReplyID = nil; replyNotice = error.localizedDescription }
            }
        } else {
            let utterance = replyVoice.utterance(reply.body)
            speech.delegate = playbackDelegate
            if let speakReply { speakReply(utterance) }
            else { speech.speak(utterance) }
        }
    }
    func stopReply() { if playingReplyID != nil { diagnosticsLog.record(.playbackStop) }; replyPlayer?.stop(); replyPlayer = nil; speech.stopSpeaking(at:.immediate); playingReplyID = nil }
}

private final class ReplyPlaybackDelegate: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    let finished: () -> Void
    init(finished:@escaping () -> Void) { self.finished = finished }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { finished() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finished() }
}

private extension TransferJob {
    var routeMode: DialogueMode {
        if destination.recipient != nil { return .agent }
        return .channel
    }
}

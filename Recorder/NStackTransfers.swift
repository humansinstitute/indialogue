import Foundation
import CryptoKit
import SwiftUI

struct TransferFile: Codable, Equatable {
    var name: String
    var mime: String
    var size: Int
    var checksum: String
    var objectID: String?
    var uploadURL: String?
    var preparing = false
    var complete = false
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
}
struct AutomaticUploadIntent: Codable {
    let recordingID: UUID
    let destination: NStackDestination
    var notice: String?
}
/// Independent of views. Atomic ledger contains no secret or Authorization headers.
@MainActor
final class NStackTransfers: ObservableObject {
    @Published private(set) var jobs: [TransferJob] = []
    @Published private(set) var destination: NStackDestination?
    @Published var notice: String?
    private(set) var intents: [AutomaticUploadIntent] = []
    let root: URL
    private var readable = true
    private var worker: Task<Void, Never>?
    private var allowed = false
    private var currentSigner: String?
    private var api: NStackAPI?
    struct Ledger: Codable { var jobs: [TransferJob]; var intents: [AutomaticUploadIntent]; var destination: NStackDestination? }
    init(root: URL) {
        self.root = root
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var dir = root; var values = URLResourceValues(); values.isExcludedFromBackup = true; try dir.setResourceValues(values)
            let path = root.appendingPathComponent("ledger.json")
            if FileManager.default.fileExists(atPath: path.path) {
                let ledger = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: path))
                jobs = ledger.jobs; intents = ledger.intents; destination = ledger.destination
                for i in jobs.indices where ["uploading","posting"].contains(jobs[i].state) { jobs[i].state = "queued" }
            }
        } catch { readable = false; notice = "Transfer ledger unreadable; retained and cannot be overwritten. \(error.localizedDescription)" }
    }
    func persist() throws {
        guard readable else { throw NStackError.malformed }
        try JSONEncoder().encode(Ledger(jobs: jobs, intents: intents, destination: destination)).write(to: root.appendingPathComponent("ledger.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func save(_ d: NStackDestination) throws { try d.validate(); destination = d; try persist() }
    func rememberNew(_ r: Recording) {
        guard let d = destination, d.automatic else { return }
        intents.append(AutomaticUploadIntent(recordingID: r.id, destination: d))
        do { try persist() } catch { notice = error.localizedDescription }
    }
    func snapshotFailed(_ id: UUID, error: Error) {
        if let i = intents.firstIndex(where: { $0.recordingID == id }) { intents[i].notice = error.localizedDescription }
        notice = error.localizedDescription
        do { try persist() } catch { notice = error.localizedDescription }
    }
    func status(_ id: UUID) -> String? {
        if let j = jobs.last(where: { $0.recordingID == id }) { return j.state.replacingOccurrences(of: "_", with: " ") + (j.notice.map { " · " + $0 } ?? "") }
        if let intent = intents.first(where: { $0.recordingID == id }) { return intent.notice ?? "Waiting for transcription" }; return nil
    }
    static func checksum(_ url: URL) throws -> (Int,String) {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256(); var count = 0
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes); count += bytes.count }
        return (count,Data(hash.finalize()).hex)
    }
    func enqueue(_ r: Recording, destination d: NStackDestination, audio: URL, corrected: String) throws {
        try d.validate()
        guard r.state == .saved, r.transcriptionState == .complete, !r.segments.isEmpty else { throw NStackError.incomplete }
        guard !jobs.contains(where: { $0.recordingID == r.id && $0.state != "cancelled" }) else { return }
        let id = UUID(); let directory = root.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioTarget = directory.appendingPathComponent("recording.m4a")
        try FileManager.default.copyItem(at: audio, to: audioTarget)
        let (size, hash) = try Self.checksum(audioTarget)
        let artifact: [String:Any] = ["version":1,"recording_id":r.id.uuidString,"snapshot_id":id.uuidString,"title":r.title,"created_at":ISO8601DateFormatter().string(from:r.createdAt),"duration_seconds":r.duration,"events":r.events,"raw_transcript":r.transcript ?? "","corrected_transcript":corrected,"prompt":d.prompt,"audio_sha256":hash,"audio_size_bytes":size,"destination_workspace":d.workspace,"destination_channel":d.channel,"signer_npub":d.signer]
        let transcript = try NostrCodec.json(artifact); try transcript.write(to: directory.appendingPathComponent("transcript.json"), options: .atomic)
        let mention = d.recipient.map { "@[\(d.recipientLabel!)](mention:agent:\($0))\n\n" } ?? ""
        let body = (mention + d.prompt + "\n\n" + r.title + "\n\n" + String(corrected.prefix(4000)) + "\n\nFull corrected transcript and audio attached.").trimmingCharacters(in: .whitespacesAndNewlines)
        jobs.append(TransferJob(id:id,recordingID:r.id,destination:d,title:r.title.isEmpty ? "Recording" : r.title,body:body,files:[TransferFile(name:"recording.m4a",mime:"audio/mp4",size:size,checksum:hash),TransferFile(name:"transcript.json",mime:"application/json",size:transcript.count,checksum:NostrCodec.hash(transcript))]))
        let last = jobs.count - 1
        if currentSigner == nil { jobs[last].state = "paused_locked"; jobs[last].notice = "Unlock identity while the app is active to send." }
        else if currentSigner != d.signer { jobs[last].state = "paused_identity" }
        else if !allowed { jobs[last].state = "paused_capture_or_background" }
        intents.removeAll { $0.recordingID == r.id }
        try persist(); resume()
    }
    func setAvailability(active: Bool, signer: String?, api: NStackAPI) {
        self.api = api; currentSigner = signer; allowed = active && signer != nil
        if !allowed { worker?.cancel() }
        for i in jobs.indices where !["sent","cancelled","failed"].contains(jobs[i].state) {
            if !active { jobs[i].state = "paused_capture_or_background" }
            else if signer == nil { jobs[i].state = "paused_locked" }
            else if signer != jobs[i].destination.signer { jobs[i].state = "paused_identity" }
            else { jobs[i].state = "queued" }
        }
        do { try persist() } catch { notice = error.localizedDescription }; resume()
    }
    func retry(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state != "sent", jobs[i].state != "cancelled" else { return }
        jobs[i].state = currentSigner == nil ? "paused_locked" : currentSigner != jobs[i].destination.signer ? "paused_identity" : !allowed ? "paused_capture_or_background" : "queued"; jobs[i].notice = nil
        do { try persist() } catch { notice = error.localizedDescription }; resume()
    }
    func cancel(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state != "sent" else { return }
        worker?.cancel(); jobs[i].state = "cancelled"; jobs[i].notice = "Local cancellation retains files. It cannot retract an already committed remote message."
        do { try persist() } catch { notice = error.localizedDescription }
    }
    func resume() {
        guard readable, allowed, worker == nil, jobs.contains(where: { $0.state == "queued" && $0.destination.signer == currentSigner }), let api else { return }
        worker = Task {
            defer { worker = nil; if allowed { resume() } }
            while let i = jobs.firstIndex(where: { $0.state == "queued" && $0.destination.signer == currentSigner }), allowed, !Task.isCancelled {
                do { try await send(i, api:api) }
                catch {
                    if jobs[i].state != "cancelled" {
                        jobs[i].state = Task.isCancelled ? (currentSigner == nil ? "paused_locked" : "queued") : "failed"
                        jobs[i].notice = Task.isCancelled ? "Deferred until foreground, idle capture and identity unlock." : error.localizedDescription
                    }
                    do { try persist() } catch { notice = error.localizedDescription }
                    if Task.isCancelled { break }
                }
            }
        }
    }
    private func send(_ i: Int, api: NStackAPI) async throws {
        let d = jobs[i].destination
        jobs[i].attempts += 1; jobs[i].lastAttempt = Date(); jobs[i].state = "uploading"; try persist()
        for f in jobs[i].files.indices {
            try Task.checkCancellation()
            if jobs[i].files[f].complete { continue }
            let file = jobs[i].files[f]; let path = root.appendingPathComponent(jobs[i].id.uuidString).appendingPathComponent(file.name)
            let actual = try Self.checksum(path)
            guard actual.0 == file.size, actual.1 == file.checksum else { throw NStackError.incomplete }
            if file.objectID == nil {
                guard !file.preparing else { throw NStackError.prepareUncertain }
                jobs[i].files[f].preparing = true; try persist()
                let prepared = try await api.request(origin:d.origin,path:"/api/v4/flightdeck-pg/workspaces/\(d.workspace)/storage/prepare",app:d.appNpub,method:"POST",body:["file_name":file.name,"content_type":file.mime,"size_bytes":file.size,"sha256_hex":file.checksum,"is_public":false,"metadata":["purpose":"recorder-upload","snapshot_id":jobs[i].id.uuidString]])
                guard let id = prepared["object_id"] as? String, UUID(uuidString:id) != nil, let upload = prepared["upload_url"] as? String else { throw NStackError.malformed }
                jobs[i].files[f].objectID = id; jobs[i].files[f].uploadURL = upload; jobs[i].files[f].preparing = false; try persist()
            }
            let object = jobs[i].files[f].objectID!
            let metadata = try await api.request(origin:d.origin,path:"/api/v4/storage/\(object)")
            if metadata["completed_at"] is String {
                guard (metadata["size_bytes"] as? Int) == file.size, metadata["sha256_hex"] as? String == file.checksum else { throw NStackError.incomplete }
            } else {
                try await api.putFile(path,upload:jobs[i].files[f].uploadURL!,origin:d.origin,object:object,mime:file.mime,size:file.size)
                _ = try await api.request(origin:d.origin,path:"/api/v4/storage/\(object)/complete",method:"POST",body:["size_bytes":file.size,"sha256_hex":file.checksum])
                let readback = try await api.request(origin:d.origin,path:"/api/v4/storage/\(object)")
                guard readback["completed_at"] is String, readback["sha256_hex"] as? String == file.checksum, readback["size_bytes"] as? Int == file.size else { throw NStackError.incomplete }
            }
            jobs[i].files[f].complete = true; try persist()
        }
        try Task.checkCancellation(); jobs[i].state = "posting"; try persist()
        let response = try await api.request(origin:d.origin,path:"/api/v4/flightdeck-pg/workspaces/\(d.workspace)/channels/\(d.channel)/messages",app:d.appNpub,method:"POST",body:api.message(jobs[i]))
        guard let message = response["message"] as? [String:Any], let id = message["id"] as? String else { throw NStackError.malformed }
        jobs[i].messageID = id; jobs[i].threadID = (response["thread"] as? [String:Any])?["id"] as? String ?? message["thread_id"] as? String
        jobs[i].state = "sent"; jobs[i].notice = nil; try persist()
    }
}

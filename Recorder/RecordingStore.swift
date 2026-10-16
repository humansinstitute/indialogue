import Foundation
import AVFoundation

struct Recording: Codable, Identifiable, Equatable {
    var schemaVersion = 2
    var id = UUID()
    var title: String
    var createdAt = Date()
    var state = State.recording
    var segments: [String] = []
    var duration: Double = 0
    var events: [String] = []
    var transcript: String?
    var transcriptionLocale: String?
    var correctedTranscript: String?
    var cleanupDraft: String?
    var transcriptionState: TranscriptionState = .none
    var transcriptionNotice: String?
    var dialogueRoute: DialogueRouteSnapshot?
    enum TranscriptionState: String, Codable { case none, queued, running, complete, failed, cancelled }
    var reviewText: String { correctedTranscript ?? transcript ?? "" }
    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, title, createdAt, state, segments, duration, events, transcript, transcriptionLocale
        case correctedTranscript, cleanupDraft, transcriptionState, transcriptionNotice, dialogueRoute
    }
    init(title: String) { self.title = title }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = max(2, try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        state = try c.decodeIfPresent(State.self, forKey: .state) ?? .saved
        segments = try c.decodeIfPresent([String].self, forKey: .segments) ?? []
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        events = try c.decodeIfPresent([String].self, forKey: .events) ?? []
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript)
        transcriptionLocale = try c.decodeIfPresent(String.self, forKey: .transcriptionLocale)
        correctedTranscript = try c.decodeIfPresent(String.self, forKey: .correctedTranscript)
        cleanupDraft = try c.decodeIfPresent(String.self, forKey: .cleanupDraft)
        transcriptionState = try c.decodeIfPresent(TranscriptionState.self, forKey: .transcriptionState) ?? (transcript == nil ? .none : .complete)
        transcriptionNotice = try c.decodeIfPresent(String.self, forKey: .transcriptionNotice)
        dialogueRoute = try c.decodeIfPresent(DialogueRouteSnapshot.self, forKey: .dialogueRoute)
    }
    enum State: String, Codable { case recording, saved, interrupted }
}

/// One atomic manifest per recording; audio is never removed during recovery.
final class RecordingStore {
    let root: URL
    private(set) var warnings: [String] = []
    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var localRoot = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try localRoot.setResourceValues(values)
    }
    func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func audio(_ r: Recording, _ name: String) -> URL { directory(r.id).appendingPathComponent(name) }
    func save(_ r: Recording) throws {
        let dir = directory(r.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let data = try JSONEncoder().encode(r)
        try data.write(to: dir.appendingPathComponent("metadata.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func load() throws -> [Recording] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.hasDirectoryPath }.map {
                try JSONDecoder().decode(Recording.self, from: Data(contentsOf: $0.appendingPathComponent("metadata.json")))
            }.sorted { $0.createdAt > $1.createdAt }
    }
    func recover() throws -> [Recording] {
        warnings = []
        var records: [Recording] = []
        for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where directory.hasDirectoryPath {
            do {
                records.append(try JSONDecoder().decode(Recording.self, from: Data(contentsOf: directory.appendingPathComponent("metadata.json"))))
            } catch {
                warnings.append("Could not read recording folder \(directory.lastPathComponent). Files retained: \(error.localizedDescription)")
            }
        }
        records.sort { $0.createdAt > $1.createdAt }
        for i in records.indices where records[i].state == .recording {
            records[i].duration = 0
            for name in records[i].segments {
                if let audio = try? AVAudioPlayer(contentsOf: audio(records[i], name)) {
                    records[i].duration += audio.duration
                } else {
                    records[i].events.append("Unreadable or missing segment: \(name). File reference retained; no audio deleted.")
                }
            }
            records[i].state = .interrupted
            records[i].events.append("Recovered after app termination. Last segment may be incomplete; earlier segments retained.")
            do { try save(records[i]) }
            catch { warnings.append("Recovered recording \(records[i].id.uuidString), but could not save recovery metadata: \(error.localizedDescription). Original files retained.") }
        }
        for i in records.indices where records[i].transcriptionState == .running {
            records[i].transcriptionState = .queued
            records[i].transcriptionNotice = "Queued after interruption; audio retained."
            do { try save(records[i]) } catch { warnings.append("Could not save transcription recovery: \(error.localizedDescription)") }
        }
        return records
    }
    func delete(_ r: Recording) throws {
        // Combined exports have an exact recording UUID + export UUID filename.
        // Remove these local copies too, including copies left by a previous process.
        let prefix = r.id.uuidString + "-"
        for url in try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil) {
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "m4a", name.hasPrefix(prefix),
                  UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { continue }
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.removeItem(at: directory(r.id))
    }
}

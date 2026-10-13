import Foundation
import AVFoundation

struct Recording: Codable, Identifiable, Equatable {
    var schemaVersion = 1
    var id = UUID()
    var title: String
    var createdAt = Date()
    var state = State.recording
    var segments: [String] = []
    var duration: Double = 0
    var events: [String] = []
    var transcript: String?
    var transcriptionLocale: String?
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
        return records
    }
    func delete(_ r: Recording) throws { try FileManager.default.removeItem(at: directory(r.id)) }
}

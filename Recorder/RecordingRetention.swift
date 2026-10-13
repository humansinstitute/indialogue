import Foundation

/// Elapsed 24-hour days from creation, independent of calendar/time-zone changes.
struct RecordingRetention: Codable, Equatable {
    static let dayRange = 1...3650
    static let validationMessage = "Enter a whole number of days from 1 to 3650."
    var enabled = false
    var days = 30
    static func parseDays(_ text: String) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(text), dayRange.contains(value) else { return nil }
        return value
    }
    func expires(_ recording: Recording, now: Date) -> Bool {
        enabled && Self.dayRange.contains(days) && recording.createdAt <= now.addingTimeInterval(-Double(days) * 86400)
    }
    static let key = "recordingRetention.v1"
    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(Self.self, from: data),
              dayRange.contains(saved.days) else { return Self() }
        return saved
    }
    func save(to defaults: UserDefaults) throws {
        guard Self.dayRange.contains(days) else { throw RetentionError.invalidDays }
        defaults.set(try JSONEncoder().encode(self), forKey: Self.key)
    }
    enum RetentionError: LocalizedError {
        case invalidDays
        var errorDescription: String? { RecordingRetention.validationMessage }
    }
}

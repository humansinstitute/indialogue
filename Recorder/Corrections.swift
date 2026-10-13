import Foundation

struct VocabularyCorrection: Codable, Identifiable, Equatable {
    var id = UUID()
    var heard: String
    var replacement: String
}

enum TranscriptCorrections {
    static func pattern(_ phrase: String) -> String {
        "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: phrase) + "(?![\\p{L}\\p{N}_])"
    }
    static func caseAdjusted(_ replacement: String, for source: String) -> String {
        if source == source.uppercased(), source != source.lowercased() { return replacement.uppercased() }
        if source.first?.isUppercase == true, source.dropFirst() == source.dropFirst().lowercased() {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }
    /// One pass, longest phrase first. Replacements cannot cascade into another rule.
    static func apply(_ text: String, vocabulary: [VocabularyCorrection]) -> String {
        let rules = vocabulary.filter { !$0.heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.heard.count == $1.heard.count ? $0.id.uuidString < $1.id.uuidString : $0.heard.count > $1.heard.count }
        var chosen: [(NSRange, String)] = []
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern(rule.heard), options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard !chosen.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }), let range = Range(match.range, in: text) else { continue }
                chosen.append((match.range, caseAdjusted(rule.replacement, for: String(text[range]))))
            }
        }
        let result = NSMutableString(string: text)
        for (range, replacement) in chosen.sorted(by: { $0.0.location > $1.0.location }) { result.replaceCharacters(in: range, with: replacement) }
        return result as String
    }
    static func words(_ text: String) -> [NSRange] {
        let regex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}_]+(?:['’][\\p{L}\\p{N}_]+)*")
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
    }
    static func replacingWord(in text: String, range: NSRange, with replacement: String) -> String {
        guard let swiftRange = Range(range, in: text) else { return text }
        var result = text
        result.replaceSubrange(swiftRange, with: caseAdjusted(replacement, for: String(text[swiftRange])))
        return result
    }
}

final class VocabularyStore {
    let url: URL
    init(url: URL) { self.url = url }
    func load() throws -> [VocabularyCorrection] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([VocabularyCorrection].self, from: Data(contentsOf: url))
    }
    func save(_ rules: [VocabularyCorrection]) throws {
        try JSONEncoder().encode(rules).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

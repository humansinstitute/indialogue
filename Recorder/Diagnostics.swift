import Foundation

/// Closed vocabulary and numeric/boolean fields only. Never accept arbitrary log text.
enum DiagnosticEventKind: String, Codable {
    case reportRequested, reopen, foreground, background, captureStart, segmentStart, segmentComplete, captureStop
    case interruptionBegan, interruptionEnded, mediaReset, routeChanged
    case deliveryAttempt, deliveryRetry, deliveryFailed, storageComplete, deliverySent
    case replyRefresh, replyReceived, replyFailed, playbackStart, playbackStop, playbackFinished, playbackFailed
}
enum DiagnosticReason: String, Codable {
    case userStop, inputSelection, interruption, mediaReset, lostInput, encode, storage, segmentStart, captureStopped
    case offline, cancelled, authentication, integrity, storageIncomplete, remoteResponse, uncertainPrepare, other
    static func failure(_ error: Error) -> Self {
        if error is CancellationError { return .cancelled }
        if error is URLError { return .offline }
        if let error = error as? NStackError {
            switch error {
            case .storageIncomplete: return .storageIncomplete
            case .storageMetadata, .storageMismatch, .snapshotMismatch: return .integrity
            case .prepareUncertain: return .uncertainPrepare
            case .response: return .remoteResponse
            case .invalidSetup: return .authentication
            default: return .other
            }
        }
        return .other
    }
}
enum DiagnosticRoute: String, Codable {
    case builtIn, bluetooth, wired, usb, other, none
}
struct DiagnosticEvent: Codable {
    let time: Date
    let kind: DiagnosticEventKind
    var seconds: Double?
    var count: Int?
    var interrupted: Bool?
    var route: DiagnosticRoute?
    var reason: DiagnosticReason?
}
struct RecorderDiagnosticSnapshot: Codable {
    let recorderExists: Bool
    let recorderCapturing: Bool
    let displayRecording: Bool
    let displayElapsed: Double
    let recorderElapsed: Double
    let completedSeconds: Double
    let segmentCount: Int
    let foreground: Bool
    let metersRunning: Bool
}
struct DiagnosticReport: Codable {
    let schemaVersion: Int
    let generatedAt: Date
    let requestedSince: Date
    let coverageSince: Date
    let gaps: [Gap]
    let build: String
    let os: String
    let snapshot: RecorderDiagnosticSnapshot
    let events: [DiagnosticEvent]
    enum Gap: String, Codable { case beforeLogStarted, processNotObserved, capacityTrimmed, persistenceUnavailable }
}
@MainActor
final class DiagnosticsLog {
    static let maxEvents = 1000
    static let maxBytes = 256 * 1024
    private struct State: Codable {
        var coverageSince: Date
        var events: [DiagnosticEvent] = []
        var capacityTrimmedAt: Date?
    }
    private let path: URL
    private var state: State
    private var persistenceUnavailable = false
    init(root: URL, now: Date = Date()) {
        path = root.appendingPathComponent("operations.json")
        state = State(coverageSince: now)
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            var directory = root; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            if FileManager.default.fileExists(atPath:path.path) {
                let size = try path.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                guard size <= Self.maxBytes else { throw CocoaError(.fileReadCorruptFile) }
                state = try JSONDecoder().decode(State.self,from:Data(contentsOf:path))
            }
        } catch { persistenceUnavailable = true }
        record(.reopen, now:now)
    }
    func record(_ kind: DiagnosticEventKind, seconds: Double? = nil, count: Int? = nil,
                interrupted: Bool? = nil, route: DiagnosticRoute? = nil, reason: DiagnosticReason? = nil, now: Date = Date()) {
        state.events.append(DiagnosticEvent(time:now,kind:kind,seconds:seconds.flatMap { $0.isFinite ? max(0,min($0,604800)) : nil },count:count.map { max(0,min($0,1000000)) },interrupted:interrupted,route:route,reason:reason))
        trim(now:now)
        do {
            var data = try JSONEncoder().encode(state)
            while data.count > Self.maxBytes, !state.events.isEmpty {
                state.capacityTrimmedAt = now; state.events.removeFirst()
                data = try JSONEncoder().encode(state)
            }
            try data.write(to:path,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        } catch { persistenceUnavailable = true }
    }
    private func trim(now: Date) {
        state.events.removeAll { $0.time < now.addingTimeInterval(-3600) || $0.time > now }
        if state.events.count > Self.maxEvents {
            state.events.removeFirst(state.events.count - Self.maxEvents); state.capacityTrimmedAt = now
        }
    }
    func report(snapshot: RecorderDiagnosticSnapshot, now: Date = Date()) throws -> Data {
        // Also persist retention when exporting after a quiet hour.
        record(.reportRequested,now:now)
        var gaps: [DiagnosticReport.Gap] = [.processNotObserved] // Suspension/termination cannot be observed continuously.
        let since = now.addingTimeInterval(-3600)
        if state.coverageSince > since { gaps.append(.beforeLogStarted) }
        if let trimmed = state.capacityTrimmedAt, trimmed >= since { gaps.append(.capacityTrimmed) }
        if persistenceUnavailable { gaps.append(.persistenceUnavailable) }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let report = DiagnosticReport(schemaVersion:1,generatedAt:now,requestedSince:since,
            coverageSince:max(since,state.coverageSince),gaps:gaps,build:version + " (" + build + ")",
            os:ProcessInfo.processInfo.operatingSystemVersionString,snapshot:snapshot,events:state.events)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(report)
    }
}

enum DiagnosticsError: LocalizedError, Equatable {
    case pending, busy
    var errorDescription: String? {
        switch self {
        case .pending: return "A diagnostics report is already pending. Retry or cancel it in NStack uploads before creating another."
        case .busy: return "A delivery is active. Send diagnostics again when it finishes; capture is unaffected."
        }
    }
}

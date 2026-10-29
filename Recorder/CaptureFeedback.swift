import SwiftUI

struct CaptureInput: Equatable {
    let uid: String
    let source: String?
    let name: String
}

struct CaptureRouteHistory {
    private var previous: [CaptureInput]?
    mutating func start(_ inputs: [CaptureInput]) { previous = inputs }
    mutating func stop() { previous = nil }
    mutating func observe(_ inputs: [CaptureInput], capturing: Bool) -> (changed: Bool, lostInput: Bool) {
        guard let previous else { return (false, false) }
        let changed = previous != inputs
        self.previous = inputs
        // A duplicate notification must still detect a stopped recorder.
        return (changed, inputs.isEmpty || !capturing)
    }
}

struct CaptureLevels {
    static let capacity = 40 // Ten seconds at the existing four updates per second.
    private(set) var samples: [Double] = []
    private(set) var running = false
    private(set) var decibels: Float?
    mutating func start() { samples = []; decibels = nil; running = true }
    mutating func pause() { samples = []; decibels = nil }
    mutating func stop() { pause(); running = false }
    mutating func append(decibels: Float) {
        guard running, decibels.isFinite else { return }
        self.decibels = max(-160, min(0, decibels))
        // Display dBFS on a bounded scale so quiet background noise remains visible.
        samples.append(Double(max(0, min(1, (decibels + 60) / 60))))
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }
    var accessibilityValue: String {
        guard let decibels else { return "Waiting for audio level" }
        if decibels < -60 { return "Very quiet" }
        if decibels < -30 { return "Quiet audio" }
        if decibels < -6 { return "Audio detected" }
        return "Loud audio"
    }
}

struct CaptureLevelView: View {
    let levels: CaptureLevels
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 8) {
            Canvas { context, size in
                let values = reduceMotion ? [levels.samples.last ?? 0] : levels.samples
                let slots = reduceMotion ? 1 : CaptureLevels.capacity
                let width = size.width / Double(slots)
                for (index, value) in values.enumerated() {
                    let height = max(2, value * size.height)
                    let x = Double(slots - values.count + index) * width
                    let rect = CGRect(x: x + 1, y: (size.height - height) / 2, width: max(1, width - 2), height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(.primary))
                }
            }.frame(height: 64)
            Text("Live recording level").font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live recording level")
        .accessibilityValue(levels.accessibilityValue)
        .accessibilityIdentifier("captureLevelHistory")
    }
}

// Injectable waits let regressions exercise delayed selection without audio hardware.
@MainActor
func waitForPreferredCaptureInput(uid: String?, current: () -> [CaptureInput], interrupted: () -> Bool,
                                  ready: () -> Bool = { true },
                                  wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(50)) }) async throws {
    for _ in 0..<20 {
        if (CaptureInputPolicy.matches(uid: uid, inputs: current()) && ready()) || interrupted() { return }
        try await wait()
    }
}

// UID is the OS port identity, never the display name or the requested preference.
enum CaptureInputPolicy {
    static func matches(uid: String?, inputs: [CaptureInput]) -> Bool {
        guard let uid else { return true } // Explicit system routing accepts substitutions.
        return !inputs.isEmpty && inputs.allSatisfy { $0.uid == uid }
    }
}

enum MicrophoneSelectionError: LocalizedError {
    case unavailable(String)
    case unhonoured(String, String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let name): return "Chosen microphone \(name) is unavailable. Recording requires this microphone."
        case .unhonoured(let name, let actual): return "iOS could not select \(name). Actual input: \(actual). Recording requires the chosen microphone."
        }
    }
}

// One request, one bounded verification; no automatic retry loop against iOS routing.
@MainActor
func requestVerifiedCaptureInput(uid: String?, name: String, request: () throws -> Void,
                                 current: () -> [CaptureInput], interrupted: () -> Bool, ready: () -> Bool = { true },
                                 wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(50)) }) async throws {
    try request()
    try await waitForPreferredCaptureInput(uid: uid, current: current, interrupted: interrupted, ready: ready, wait: wait)
    guard !interrupted(), ready(), CaptureInputPolicy.matches(uid: uid, inputs: current()) else {
        let actual = current().map(\.name).joined(separator: ", ")
        throw MicrophoneSelectionError.unhonoured(name, actual.isEmpty ? "No active input" : actual)
    }
}

struct CaptureRouting {
    let current: () -> [CaptureInput]
    let available: () -> [CaptureInput]?
    let request: (String?) throws -> Void
    var isCapturing: (() -> Bool)? = nil
}

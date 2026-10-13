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
                                  wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(50)) }) async throws {
    guard let uid else { return }
    for _ in 0..<20 {
        if current().contains(where: { $0.uid == uid }) || interrupted() { return }
        try await wait()
    }
}

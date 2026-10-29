import XCTest
@testable import PeteRecorder

final class CaptureFeedbackTests: XCTestCase {
    let phone = CaptureInput(uid: "phone", source: "front", name: "Phone")
    let bluetooth = CaptureInput(uid: "bt", source: nil, name: "AirPods")
    func testAsynchronousRouteChangesAreDistinctAndLossAlwaysDetected() {
        var history = CaptureRouteHistory()
        history.start([phone])
        XCTAssertFalse(history.observe([phone], capturing: true).changed)
        XCTAssertTrue(history.observe([bluetooth], capturing: true).changed)
        XCTAssertFalse(history.observe([bluetooth], capturing: true).changed)
        XCTAssertTrue(history.observe([bluetooth], capturing: false).lostInput)
        XCTAssertTrue(history.observe([], capturing: true).lostInput)
        XCTAssertTrue(history.observe([phone], capturing: true).changed)
        XCTAssertTrue(history.observe([CaptureInput(uid: "phone", source: "back", name: "Phone")], capturing: true).changed)
        history.stop()
        XCTAssertFalse(history.observe([], capturing: false).lostInput)
    }
    func testMeterBoundsSegmentContinuityPauseStopAndRestart() {
        var levels = CaptureLevels()
        levels.append(decibels: -12)
        XCTAssertTrue(levels.samples.isEmpty)
        levels.start()
        for _ in 0..<100 { levels.append(decibels: -30) }
        XCTAssertEqual(levels.samples.count, 40)
        XCTAssertEqual(levels.samples.last, 0.5)
        // The next segment feeds the same history; no reset at a boundary.
        levels.append(decibels: -6)
        XCTAssertEqual(levels.samples.first, 0.5)
        XCTAssertEqual(levels.samples.last!, 0.9, accuracy: 0.0001)
        levels.append(decibels: .nan)
        XCTAssertEqual(levels.samples.count, 40)
        levels.pause(); XCTAssertTrue(levels.samples.isEmpty); XCTAssertTrue(levels.running)
        levels.append(decibels: -160); XCTAssertEqual(levels.samples.last, 0)
        levels.append(decibels: 20); XCTAssertEqual(levels.samples.last, 1)
        levels.stop(); levels.append(decibels: -10)
        XCTAssertTrue(levels.samples.isEmpty); XCTAssertNil(levels.decibels)
        levels.start(); XCTAssertTrue(levels.samples.isEmpty)
    }
}

extension CaptureFeedbackTests {
    @MainActor func testStartupWaitsForActualPreferredInputAndBoundsFallback() async throws {
        var route = [phone]
        var waits = 0
        try await waitForPreferredCaptureInput(uid: bluetooth.uid, current: { route }, interrupted: { false }, wait: {
            waits += 1
            if waits == 3 { route = [self.bluetooth] }
        })
        XCTAssertEqual(waits, 3)
        XCTAssertEqual(route, [bluetooth])
        waits = 0; route = [phone]
        try await waitForPreferredCaptureInput(uid: bluetooth.uid, current: { route }, interrupted: { false }, wait: { waits += 1 })
        XCTAssertEqual(waits, 20)
        XCTAssertEqual(route, [phone]) // Never relabel preference as actual.
        waits = 0
        try await waitForPreferredCaptureInput(uid: nil, current: { route }, interrupted: { false }, wait: { waits += 1 })
        XCTAssertEqual(waits, 0)
        try await waitForPreferredCaptureInput(uid: bluetooth.uid, current: { route }, interrupted: { true }, wait: { waits += 1 })
        XCTAssertEqual(waits, 0)
    }
}

extension CaptureFeedbackTests {
    func testStrictPreferenceRejectsVanAndEmptyInputButSystemRemainsExplicit() {
        let van = CaptureInput(uid: "van", source: nil, name: "Van")
        XCTAssertFalse(CaptureInputPolicy.matches(uid: bluetooth.uid, inputs: [van]))
        XCTAssertFalse(CaptureInputPolicy.matches(uid: bluetooth.uid, inputs: []))
        XCTAssertFalse(CaptureInputPolicy.matches(uid: bluetooth.uid, inputs: [bluetooth, van]))
        XCTAssertTrue(CaptureInputPolicy.matches(uid: bluetooth.uid, inputs: [bluetooth]))
        XCTAssertTrue(CaptureInputPolicy.matches(uid: nil, inputs: [van]))
        // Display names cannot establish device identity.
        XCTAssertFalse(CaptureInputPolicy.matches(uid: bluetooth.uid, inputs: [CaptureInput(uid: "other", source: nil, name: "AirPods")]))
    }
    @MainActor func testPickerVerifiesDelayedSwitchOnceAndRejectsUnhonouredRequest() async throws {
        var route = [phone], requests = 0, waits = 0
        try await requestVerifiedCaptureInput(uid: bluetooth.uid, name: "AirPods", request: { requests += 1 },
            current: { route }, interrupted: { false }, wait: {
                waits += 1
                if waits == 3 { route = [self.bluetooth] }
            })
        XCTAssertEqual(requests, 1); XCTAssertEqual(waits, 3)
        route = [phone]; waits = 0
        do {
            try await requestVerifiedCaptureInput(uid: bluetooth.uid, name: "AirPods", request: { requests += 1 },
                current: { route }, interrupted: { false }, wait: { waits += 1 })
            XCTFail("An accepted API request must not mean a verified selection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("AirPods"))
            XCTAssertTrue(error.localizedDescription.contains("Phone"))
        }
        XCTAssertEqual(requests, 2); XCTAssertEqual(waits, 20); XCTAssertEqual(route, [phone])
        do {
            try await requestVerifiedCaptureInput(uid: bluetooth.uid, name: "AirPods", request: {},
                current: { [self.bluetooth] }, interrupted: { true }, wait: { XCTFail("Interrupted selection must not wait") })
            XCTFail("Interruption must not commit a selection")
        } catch {}
        try await requestVerifiedCaptureInput(uid: nil, name: "System default", request: { requests += 1 },
            current: { route }, interrupted: { false }, wait: { XCTFail("System selection must not wait for a specific device") })
        XCTAssertEqual(requests, 3)
    }
}

extension CaptureFeedbackTests {
    @MainActor func testModelRejectsPickerWithoutPersistingAndStopsOnReplacementWithAudioRetained() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: "Microphone." + root.lastPathComponent)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: "Microphone." + root.lastPathComponent) }
        defaults.set("bt", forKey: "preferredInputUID")
        defaults.set("AirPods", forKey: "preferredInputName")
        var route = [bluetooth], requests = 0
        let van = CaptureInput(uid: "van", source: nil, name: "Van")
        let routing = CaptureRouting(current: { route }, available: { [self.bluetooth, van] }, request: { _ in requests += 1 })
        let model = RecorderModel(root: root, captureRouting: routing, retentionDefaults: defaults)
        await model.chooseInput(uid: "van", name: "Van") // Request accepted, actual input never follows.
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(defaults.string(forKey: "preferredInputUID"), "bt")
        XCTAssertEqual(model.selectedInputName, "AirPods")
        XCTAssertEqual(model.actualInput, "AirPods")
        XCTAssertTrue(model.inputSelectionNotice?.contains("could not select Van") == true)
        var recording = Recording(title: "Synthetic strict route")
        recording.segments = ["segment-00000.m4a"]
        try model.store!.save(recording)
        let bytes = Data([1, 2, 3, 4]) // Retention check only; no claim of playable hardware audio.
        let audio = model.store!.audio(recording, recording.segments[0])
        try bytes.write(to: audio)
        model.active = recording
        route = [van]
        XCTAssertFalse(model.enforceCaptureInput())
        XCTAssertNil(model.active)
        XCTAssertEqual(model.recordings.first?.state, .interrupted)
        XCTAssertEqual(try model.store!.recover().first?.state, .interrupted)
        XCTAssertEqual(try Data(contentsOf: audio), bytes)
        XCTAssertTrue(model.message?.contains("Recording stopped") == true)
        XCTAssertEqual(requests, 1) // No retry loop from policy enforcement.
    }
    @MainActor func testActualRouteOutranksStaleDiscoveryAndPendingSwitchDoesNotStop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: "Microphone." + root.lastPathComponent)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: "Microphone." + root.lastPathComponent) }
        defaults.set("bt", forKey: "preferredInputUID"); defaults.set("AirPods", forKey: "preferredInputName")
        var route = [bluetooth], requests = 0
        var available: [CaptureInput] = []
        let model = RecorderModel(root: root, captureRouting: CaptureRouting(current: { route }, available: { available }, request: { _ in requests += 1 }, isCapturing: { true }), retentionDefaults: defaults)
        model.refreshRoute()
        XCTAssertEqual(model.preferredInputAvailable, true)
        await model.chooseInput(uid: "bt", name: "AirPods")
        XCTAssertEqual(requests, 0) // Already actual: never send a port absent from availableInputs.
        XCTAssertEqual(model.actualInput, "AirPods")
        XCTAssertFalse(model.microphonePreferenceLabel.contains("unavailable"))
        available = [phone, bluetooth]
        model.active = Recording(title: "Synthetic transition")
        let selection = Task { await model.chooseInput(uid: "phone", name: "Phone") }
        while !model.selectingInput { await Task.yield() }
        XCTAssertTrue(model.enforceCaptureInput())
        XCTAssertNotNil(model.active) // Old actual input during an explicit switch is permitted briefly.
        route = [phone]
        await selection.value
        XCTAssertEqual(defaults.string(forKey: "preferredInputUID"), "phone")
        XCTAssertEqual(model.selectedInputName, "Phone")
        XCTAssertEqual(requests, 1)
        await model.chooseInput(uid: nil, name: "System default")
        XCTAssertNil(defaults.string(forKey: "preferredInputUID"))
        model.active = Recording(title: "System route")
        route = [bluetooth]
        XCTAssertTrue(model.enforceCaptureInput())
        XCTAssertNotNil(model.active)
        model.stop()
    }
}

extension CaptureFeedbackTests {
    @MainActor func testSelectionWaitsForCaptureToSurviveRouteTransition() async throws {
        var running = false, waits = 0
        try await requestVerifiedCaptureInput(uid: bluetooth.uid, name: "AirPods", request: {},
            current: { [self.bluetooth] }, interrupted: { false }, ready: { running }, wait: {
                waits += 1
                if waits == 4 { running = true }
            })
        XCTAssertEqual(waits, 4)
        running = false; waits = 0
        do {
            try await requestVerifiedCaptureInput(uid: nil, name: "System default", request: {},
                current: { [self.phone] }, interrupted: { false }, ready: { running }, wait: { waits += 1 })
            XCTFail("Stopped capture cannot be reported as a successful switch")
        } catch {}
        XCTAssertEqual(waits, 20)
    }
}

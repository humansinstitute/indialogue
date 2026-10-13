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

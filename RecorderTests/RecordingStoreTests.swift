import XCTest
@testable import PeteRecorder
final class RecordingStoreTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func testIntentRecoveryPreservesIdentityAudioAndEvents() throws {
        let store = try RecordingStore(root: root)
        var r = Recording(title: "Test")
        r.segments = ["segment-00000.m4a"]
        try store.save(r)
        let audio = store.audio(r, r.segments[0])
        try Data([1,2,3]).write(to: audio)
        let recovered = try store.recover()
        XCTAssertEqual(recovered.first?.id, r.id)
        XCTAssertEqual(recovered.first?.state, .interrupted)
        XCTAssertEqual(try Data(contentsOf: audio), Data([1,2,3]))
        XCTAssertEqual(try store.recover().first?.events.count, 2, "Recovery is idempotent")
    }
    func testSavedRenameTranscriptRoundTripAndDelete() throws {
        let store = try RecordingStore(root: root)
        var r = Recording(title: "Before")
        r.state = .saved; r.duration = 31; r.transcript = "Local words"; r.segments = ["a.m4a", "b.m4a"]
        try store.save(r)
        r.title = "After"; try store.save(r)
        XCTAssertEqual(try store.recover(), [r])
        try store.delete(r)
        XCTAssertTrue(try store.load().isEmpty)
    }
    func testCorruptManifestIsIsolatedWithoutDeletingAudio() throws {
        let store = try RecordingStore(root: root)
        let r = Recording(title: "Corrupt")
        try store.save(r)
        let file = store.directory(r.id).appendingPathComponent("metadata.json")
        try Data("invalid".utf8).write(to: file)
        XCTAssertTrue(try store.recover().isEmpty)
        XCTAssertEqual(store.warnings.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}

import AVFoundation
extension RecordingStoreTests {
    @MainActor
    func testAACSegmentsExportAsPlayableM4A() async throws {
        let model = RecorderModel(root: root)
        let store = try XCTUnwrap(model.store)
        var r = Recording(title: "Synthetic test audio")
        r.state = .saved
        r.segments = ["segment-00000.m4a", "segment-00001.m4a"]
        try store.save(r)
        defer { try? store.delete(r) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        for name in r.segments {
            let file = try AVAudioFile(forWriting: store.audio(r, name), settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96000])
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100))
            buffer.frameLength = 44100
            memset(buffer.floatChannelData![0], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
            try file.write(from: buffer)
        }
        let exported = try await model.export(r)
        defer { try? FileManager.default.removeItem(at: exported) }
        let playback = try AVAudioPlayer(contentsOf: exported)
        XCTAssertEqual(playback.duration, 2, accuracy: 0.15)
        XCTAssertEqual(exported.pathExtension, "m4a")
        XCTAssertEqual(try store.load().first(where: { $0.id == r.id })?.id, r.id)
        r.state = .recording; r.duration = 999
        r.segments.append("incomplete-final.m4a")
        try store.save(r)
        let recovered = try XCTUnwrap(store.recover().first)
        XCTAssertEqual(recovered.state, .interrupted)
        XCTAssertEqual(recovered.duration, 2, accuracy: 0.15)
        let salvaged = try await model.export(recovered)
        XCTAssertEqual(try AVAudioPlayer(contentsOf: salvaged).duration, 2, accuracy: 0.15)
        XCTAssertTrue(model.message?.contains("Unreadable segments omitted") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audio(r, r.segments[0]).path))
    }
}

extension RecordingStoreTests {
    @MainActor
    func testStopPersistsFinalStateAndClearsCaptureIntent() throws {
        let model = RecorderModel(root: root)
        let store = try XCTUnwrap(model.store)
        let r = Recording(title: "Pending capture")
        try store.save(r)
        model.active = r
        model.stop()
        XCTAssertNil(model.active)
        XCTAssertEqual(model.recordings.first?.state, .saved)
        XCTAssertEqual(try store.load().first?.state, .saved)
        XCTAssertEqual(try store.recover().first?.state, .saved)
    }
    @MainActor
    func testInterruptionFinalizesIntentAndRetainsSegmentReference() async throws {
        let model = RecorderModel(root: root)
        let store = try XCTUnwrap(model.store)
        var r = Recording(title: "Interrupted capture")
        r.segments = ["segment-00000.m4a"]
        try store.save(r)
        model.active = r
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(model.active)
        XCTAssertTrue(model.message?.contains("interrupted") == true)
        let saved = try XCTUnwrap(store.load().first)
        XCTAssertEqual(saved.id, r.id)
        XCTAssertEqual(saved.state, .interrupted)
        XCTAssertEqual(saved.segments, r.segments)
        XCTAssertFalse(saved.events.isEmpty)
    }
}

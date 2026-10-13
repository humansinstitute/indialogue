import XCTest
@testable import PeteRecorder

@MainActor
final class RecordingRetentionTests: XCTestCase {
    var root: URL!
    var defaults: UserDefaults!
    var suite: String!
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "RetentionTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-transfers"))
        defaults.removePersistentDomain(forName: suite)
    }
    func model(available: @escaping () -> Bool = { true }) -> RecorderModel {
        RecorderModel(root: root, retentionDefaults: defaults, protectedDataAvailable: available)
    }
    func record(_ model: RecorderModel, age: Double = 31 * 86400) throws -> Recording {
        var r = Recording(title: "Synthetic retention")
        r.state = .saved; r.createdAt = now.addingTimeInterval(-age)
        r.transcript = "original"; r.correctedTranscript = "edited"; r.cleanupDraft = "draft"
        r.segments = ["segment.m4a"]
        try model.store!.save(r)
        try Data([1,2,3]).write(to: model.store!.audio(r, "segment.m4a"))
        model.recordings.append(r)
        return r
    }
    func enable(_ m: RecorderModel) throws {
        // Persist without triggering real-clock cleanup; all fixtures are dated in the future.
        XCTAssertTrue(m.saveRetention(enabled: true, days: "30"))
    }
    func testDisabledDefaultPersistenceAndValidation() throws {
        let m = model(); let r = try record(m)
        XCTAssertFalse(m.retention.enabled); m.runRetention(now: now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: m.store!.directory(r.id).path))
        for text in ["", "0", "-1", "1.5", "3651", "999999999999999999999", " 30", "abc"] {
            XCTAssertFalse(m.saveRetention(enabled: true, days: text)); XCTAssertFalse(m.retention.enabled)
            XCTAssertEqual(m.retentionNotice, RecordingRetention.validationMessage)
        }
        XCTAssertTrue(m.saveRetention(enabled: true, days: "3650"))
        let reopened = model(); XCTAssertEqual(reopened.retention, RecordingRetention(enabled: true, days: 3650))
        XCTAssertTrue(reopened.saveRetention(enabled: false, days: "7"))
        XCTAssertEqual(model().retention, RecordingRetention(enabled: false, days: 7))
        defaults.set(Data("corrupt".utf8), forKey: RecordingRetention.key)
        XCTAssertFalse(model().retention.enabled)
    }
    func testExactCutoffCreationAgeAndAllRecordingArtifacts() throws {
        let m = model(); let expired = try record(m, age: 30 * 86400)
        let newer = try record(m, age: 30 * 86400 - 0.001)
        let future = try record(m, age: -86400)
        let export = FileManager.default.temporaryDirectory.appendingPathComponent(expired.id.uuidString + "-" + UUID().uuidString + ".m4a")
        let unrelated = FileManager.default.temporaryDirectory.appendingPathComponent(expired.id.uuidString + "-keep.m4a")
        defer { try? FileManager.default.removeItem(at: export); try? FileManager.default.removeItem(at: unrelated) }
        try Data([4]).write(to: export); try Data([5]).write(to: unrelated)
        try enable(m); m.runRetention(now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertEqual(Set(m.recordings.map(\.id)), Set([newer.id, future.id]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: m.store!.directory(expired.id).path))
        XCTAssertEqual(try m.store!.load().count, 2)
    }
    func testProtectedDataBackgroundCapturePlaybackAndQueuedSpeechDefer() throws {
        var available = false
        let m = model { available }; let r = try record(m); try enable(m)
        m.runRetention(now: now); XCTAssertEqual(m.recordings.count, 1)
        available = true; m.background(); m.runRetention(now: now); XCTAssertEqual(m.recordings.count, 1)
        m.foreground(); m.active = r; m.runRetention(now: now); XCTAssertEqual(m.recordings.count, 1)
        m.active = nil; m.playing = r.id; m.runRetention(now: now); XCTAssertEqual(m.recordings.count, 1)
        m.playing = nil
        for state: Recording.TranscriptionState in [.queued, .running] {
            var changed = r; changed.transcriptionState = state; m.replace(changed)
            m.runRetention(now: now); XCTAssertEqual(m.recordings.count, 1)
        }
        var changed = r; changed.state = .recording; m.replace(changed)
        m.runRetention(now: now); XCTAssertEqual(m.recordings.count, 1)
        m.replace(r); m.runRetention(now: now); XCTAssertTrue(m.recordings.isEmpty)
    }
    func testUnreadableTransferLedgerFailsClosed() throws {
        let m = model(); let r = try record(m); try enable(m)
        try Data("unreadable".utf8).write(to: m.transfers.root.appendingPathComponent("ledger.json"))
        let reopened = model(); reopened.runRetention(now: now)
        XCTAssertEqual(reopened.recordings.first?.id, r.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.store!.directory(r.id).path))
    }
    func testUploadIntentsAndEveryUnfinishedJobStateAreProtected() throws {
        let m = model(); let r = try record(m); try enable(m)
        let d = NStackDestination(origin: "https://example.com", signer: "synthetic", workspace: "workspace", workspaceLabel: "Workspace", appNpub: "synthetic", channel: "channel", channelLabel: "Channel", prompt: "Review", automatic: true)
        // Load realistic durable ledgers so paused/failed states are tested without network or secrets.
        for state in ["queued", "uploading", "posting", "paused_locked", "paused_identity", "paused_capture_or_background", "failed"] {
            let job = TransferJob(recordingID: r.id, destination: d, title: r.title, body: "snapshot", files: [], state: state)
            let ledger = NStackTransfers.Ledger(jobs: [job], intents: [], destination: nil)
            try JSONEncoder().encode(ledger).write(to: m.transfers.root.appendingPathComponent("ledger.json"))
            let reopened = model(); reopened.runRetention(now: now)
            XCTAssertEqual(reopened.recordings.first?.id, r.id, state)
        }
        let ledger = NStackTransfers.Ledger(jobs: [], intents: [AutomaticUploadIntent(recordingID: r.id, destination: d, notice: "snapshot failed")], destination: nil)
        try JSONEncoder().encode(ledger).write(to: m.transfers.root.appendingPathComponent("ledger.json"))
        let reopened = model(); reopened.runRetention(now: now); XCTAssertEqual(reopened.recordings.first?.id, r.id)
    }
    func testFinishedUploadSnapshotsAndTranscriptBearingLedgerEntriesDeleted() throws {
        let m = model(); let r = try record(m); try enable(m)
        let d = NStackDestination(origin: "https://example.com", signer: "synthetic", workspace: "workspace", workspaceLabel: "Workspace", appNpub: "synthetic", channel: "channel", channelLabel: "Channel", prompt: "Review", automatic: false)
        let jobs = ["sent", "cancelled"].map { TransferJob(recordingID: r.id, destination: d, title: r.title, body: "snapshot", files: [], state: $0) }
        for job in jobs {
            let dir = m.transfers.root.appendingPathComponent(job.id.uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data([1]).write(to: dir.appendingPathComponent("recording.m4a"))
            try Data("transcript".utf8).write(to: dir.appendingPathComponent("transcript.json"))
        }
        try JSONEncoder().encode(NStackTransfers.Ledger(jobs: jobs, intents: [], destination: nil)).write(to: m.transfers.root.appendingPathComponent("ledger.json"))
        let reopened = model(); reopened.runRetention(now: now)
        XCTAssertTrue(reopened.recordings.isEmpty)
        XCTAssertTrue(reopened.transfers.jobs.isEmpty)
        XCTAssertTrue(NStackTransfers(root: reopened.transfers.root).jobs.isEmpty)
        for job in jobs { XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.transfers.root.appendingPathComponent(job.id.uuidString).path)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.transfers.root.appendingPathComponent("ledger.json").path))
    }
}

extension RecordingRetentionTests {
    func testRunningSpeechAfterCancellationStillProtectsUntilWorkerReturns() async throws {
        var finish: CheckedContinuation<LocalTranscript, Error>?
        let m = RecorderModel(root: root, speech: { _, _ in
            try await withCheckedThrowingContinuation { finish = $0 }
        }, audioExport: { _ in FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }, retentionDefaults: defaults, protectedDataAvailable: { true })
        let r = try record(m); try enable(m)
        m.startTranscription(r, download: false)
        for _ in 0..<100 where finish == nil { await Task.yield() }
        XCTAssertNotNil(finish)
        m.cancelTranscription(); m.runRetention(now: now)
        XCTAssertEqual(m.recordings.count, 1, "Cancelled status is insufficient until the task releases its files")
        finish?.resume(throwing: CancellationError())
        for _ in 0..<100 where m.transcribing { await Task.yield() }
        m.runRetention(now: now); XCTAssertTrue(m.recordings.isEmpty)
    }
    func testCleanupAndCancellationProtectUntilTaskReturns() async throws {
        var finish: CheckedContinuation<String, Error>?
        let m = RecorderModel(root: root, cleanup: { _, _ in
            try await withCheckedThrowingContinuation { finish = $0 }
        }, retentionDefaults: defaults, protectedDataAvailable: { true })
        let r = try record(m); try enable(m); m.cleanUp(r.id)
        for _ in 0..<100 where finish == nil { await Task.yield() }
        XCTAssertNotNil(finish); m.runRetention(now: now); XCTAssertEqual(m.recordings.count, 1)
        m.cancelCleanup(); m.runRetention(now: now); XCTAssertEqual(m.recordings.count, 1)
        finish?.resume(throwing: CancellationError())
        for _ in 0..<100 where m.cleaning { await Task.yield() }
        m.runRetention(now: now); XCTAssertTrue(m.recordings.isEmpty)
    }
    func testFailureKeepsRecordAndReportsRetry() throws {
        let m = model(); let r = try record(m); try enable(m)
        // Synthetic missing folder deterministically exercises storage deletion failure.
        try m.store!.delete(r)
        m.runRetention(now: now)
        XCTAssertEqual(m.recordings.first?.id, r.id)
        XCTAssertTrue(m.retentionNotice?.contains("will retry") == true)
        try m.store!.save(r); m.runRetention(now: now); XCTAssertTrue(m.recordings.isEmpty)
        XCTAssertNil(m.retentionNotice, "A successful retry clears the deletion error")
    }
    func testSharingDefersRetention() throws {
        let m = model(); let r = try record(m); try enable(m)
        m.sharingID = r.id; m.runRetention(now: now); XCTAssertEqual(m.recordings.count, 1)
        m.sharingID = nil; m.runRetention(now: now); XCTAssertTrue(m.recordings.isEmpty)
    }
}


extension RecordingRetentionTests {
    func testLaunchAndForegroundRunSavedPolicy() throws {
        let m = model()
        var r = try record(m); r.createdAt = Date().addingTimeInterval(-31 * 86400)
        try m.store!.save(r)
        try RecordingRetention(enabled: true, days: 30).save(to: defaults)
        let launched = model()
        XCTAssertTrue(launched.recordings.isEmpty, "Launch applies persisted policy")
        let expired = try record(launched)
        var changed = expired; changed.createdAt = r.createdAt
        try launched.store!.save(changed); launched.replace(changed)
        launched.background(); launched.runRetention(); XCTAssertEqual(launched.recordings.count, 1)
        launched.foreground(); XCTAssertTrue(launched.recordings.isEmpty)
    }
    func testPreparingUploadRemainsProtectedAfterCancellation() async throws {
        var finish: CheckedContinuation<URL, Error>?
        let m = RecorderModel(root: root, audioExport: { _ in
            try await withCheckedThrowingContinuation { finish = $0 }
        }, retentionDefaults: defaults, protectedDataAvailable: { true })
        var r = try record(m); r.transcriptionState = .complete; m.replace(r)
        try enable(m)
        let d = NStackDestination(origin: "https://example.com", signer: "synthetic", workspace: "workspace", workspaceLabel: "Workspace", appNpub: "synthetic", channel: "channel", channelLabel: "Channel", prompt: "Review", automatic: false)
        m.upload(r, destination: d)
        for _ in 0..<100 where finish == nil { await Task.yield() }
        XCTAssertNotNil(finish); m.runRetention(now: now); XCTAssertEqual(m.recordings.count, 1)
        m.prioritizeCapture(); m.runRetention(now: now); XCTAssertEqual(m.recordings.count, 1)
        finish?.resume(throwing: CancellationError())
        for _ in 0..<100 where m.preparingUpload { await Task.yield() }
        m.runRetention(now: now); XCTAssertTrue(m.recordings.isEmpty)
    }
}

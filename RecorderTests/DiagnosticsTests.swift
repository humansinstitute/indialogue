import XCTest
@testable import PeteRecorder

@MainActor
final class DiagnosticsTests: XCTestCase {
    func temp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    var snapshot: RecorderDiagnosticSnapshot {
        RecorderDiagnosticSnapshot(recorderExists:true,recorderCapturing:true,displayRecording:true,displayElapsed:10,
            recorderElapsed:2,completedSeconds:8,segmentCount:1,foreground:true,metersRunning:true)
    }
    func decode(_ data: Data) throws -> DiagnosticReport {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DiagnosticReport.self,from:data)
    }
    func testHourRetentionRelaunchCapacityAndPrivacySchema() throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        let now = Date(timeIntervalSince1970:1_800_000_000)
        let log = DiagnosticsLog(root:root,now:now.addingTimeInterval(-3700))
        log.record(.captureStart,now:now.addingTimeInterval(-3601))
        log.record(.segmentComplete,seconds:15,count:1,now:now.addingTimeInterval(-3599))
        let report = try decode(log.report(snapshot:snapshot,now:now))
        XCTAssertFalse(report.events.contains{$0.kind == .captureStart})
        XCTAssertTrue(report.events.contains{$0.kind == .segmentComplete})
        let restored = DiagnosticsLog(root:root,now:now)
        XCTAssertTrue(try decode(restored.report(snapshot:snapshot,now:now)).events.contains{$0.kind == .segmentComplete})
        for _ in 0..<1100 { restored.record(.routeChanged,seconds:.infinity,count:Int.max,route:.bluetooth,now:now) }
        let data = try restored.report(snapshot:snapshot,now:now)
        let capped = try decode(data)
        XCTAssertLessThanOrEqual(capped.events.count,DiagnosticsLog.maxEvents)
        XCTAssertTrue(capped.gaps.contains(.capacityTrimmed))
        XCTAssertTrue(capped.gaps.contains(.processNotObserved))
        XCTAssertLessThanOrEqual(try Data(contentsOf:root.appendingPathComponent("operations.json")).count,DiagnosticsLog.maxBytes)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertEqual(Set(object.keys),Set(["schemaVersion","generatedAt","requestedSince","coverageSince","gaps","build","os","snapshot","events"]))
        for event in try XCTUnwrap(object["events"] as? [[String:Any]]) {
            XCTAssertTrue(Set(event.keys).isSubset(of:["time","kind","seconds","count","interrupted","route","reason"]))
            XCTAssertNil(event["seconds"])
        }
        let empty = try decode(restored.report(snapshot:snapshot,now:now.addingTimeInterval(3601)))
        XCTAssertEqual(empty.events.count,1)
    }
    func testMissingOrCorruptHistoryIsExplicit() throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        var log = DiagnosticsLog(root:root)
        XCTAssertTrue(try decode(log.report(snapshot:snapshot)).gaps.contains(.beforeLogStarted))
        try Data("unfiltered secret error".utf8).write(to:root.appendingPathComponent("operations.json"))
        log = DiagnosticsLog(root:root)
        let data = try log.report(snapshot:snapshot)
        XCTAssertTrue(try decode(data).gaps.contains(.persistenceUnavailable))
        XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("secret"))
    }
    func testSeparateReportSnapshotBindingNoInstructionAndBoundedPending() throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        let helper = BackgroundUploadTests(), queue = NStackTransfers(root:root)
        var d = helper.destination(); d.recipient = helper.npub; d.recipientLabel = "Agent"; d.prompt = "PRIVATE MESSAGE"
        try queue.save(d)
        XCTAssertThrowsError(try queue.enqueueDiagnostics(snapshot:snapshot))
        queue.setAvailability(active:false,signer:helper.npub,api:helper.api(FakeBackgroundUploads()))
        try queue.enqueueDiagnostics(snapshot:snapshot)
        let job = try XCTUnwrap(queue.jobs.first)
        XCTAssertTrue(job.diagnostics == true); XCTAssertNil(job.destination.recipient)
        XCTAssertNil(job.conversationID); XCTAssertFalse(job.body.contains("PRIVATE MESSAGE"))
        XCTAssertEqual(job.files.map(\.name),["diagnostics.json"])
        XCTAssertThrowsError(try queue.enqueueDiagnostics(snapshot:snapshot))
        let message = try helper.api(FakeBackgroundUploads()).message(job)
        XCTAssertNil(message["mentions"])
        let metadata = try XCTUnwrap(message["metadata"] as? [String:Any])
        XCTAssertNil(metadata["recorder"]); XCTAssertNotNil(metadata["diagnostics"])
        d.workspace = UUID().uuidString; try queue.save(d)
        let restored = NStackTransfers(root:root)
        XCTAssertEqual(restored.jobs.first?.destination.workspace,job.destination.workspace)
        restored.setAvailability(active:true,signer:nil,api:helper.api(FakeBackgroundUploads()))
        XCTAssertEqual(restored.jobs.first?.state,"paused_locked")
        restored.setAvailability(active:true,signer:NostrCodec.npub(Data(repeating:2,count:32)),api:helper.api(FakeBackgroundUploads()))
        XCTAssertEqual(restored.jobs.first?.state,"paused_identity")
    }
    func testModelLifecycleSnapshotAndContentNeverEnterReport() throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-transfers")); try? FileManager.default.removeItem(at:root) }
        let model = RecorderModel(root:root)
        var recording = Recording(title:"PERSONAL TITLE")
        recording.transcript = "PRIVATE TRANSCRIPT"; recording.events = ["PERSONAL MIC"]
        model.active = recording; model.actualInput = "PERSONAL MIC"; model.message = "TOKEN RAW ERROR"
        model.levels.start(); model.background(); model.foreground()
        XCTAssertTrue(model.levels.running) // pause clears history, never stops the meter.
        var report = try decode(model.transfers.diagnosticsLog.report(snapshot:model.diagnosticSnapshot))
        XCTAssertFalse(report.snapshot.recorderCapturing)
        XCTAssertTrue(report.snapshot.displayRecording) // Preserve evidence of a mismatch, do not invent capture.
        XCTAssertTrue(report.events.contains{$0.kind == .background})
        XCTAssertTrue(report.events.contains{$0.kind == .foreground})
        model.stop(interrupted:true,reason:.encode)
        let data = try model.transfers.diagnosticsLog.report(snapshot:model.diagnosticSnapshot)
        report = try decode(data)
        XCTAssertTrue(report.events.contains{$0.kind == .captureStop && $0.reason == .encode})
        for privateText in ["PERSONAL TITLE","PRIVATE TRANSCRIPT","PERSONAL MIC","TOKEN RAW ERROR"] {
            XCTAssertFalse(String(decoding:data,as:UTF8.self).contains(privateText))
        }
    }
    func testActiveWorkerCannotPruneOrAppendReport() async throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        let helper = BackgroundUploadTests(), background = FakeBackgroundUploads()
        _ = helper.installBackend()
        let queue = try helper.makeQueue(root:root,background:background)
        let ids = queue.jobs.map(\.id)
        var checked = false
        let api = NStackAPI(session:helper.session(),backgroundUploads:background) { kind,tags,content in
            checked = true
            XCTAssertThrowsError(try queue.enqueueDiagnostics(snapshot:self.snapshot)) { error in
                XCTAssertEqual(error as? DiagnosticsError,.busy)
            }
            XCTAssertEqual(queue.jobs.map(\.id),ids)
            return NostrEvent(id:String(repeating:"0",count:64),pubkey:String(repeating:"01",count:32),created_at:1,kind:kind,tags:tags,content:content,sig:String(repeating:"0",count:128))
        }
        queue.setAvailability(active:true,signer:helper.npub,api:api)
        try await helper.wait { queue.jobs[0].state == "background_uploading" }
        XCTAssertTrue(checked)
    }
    func testStorageReadbackMustConfirmCompletionBeforeReportPost() async throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        let helper = BackgroundUploadTests(), background = FakeBackgroundUploads()
        let backend = helper.installBackend()
        let normal = MockNStackProtocol.handler!
        MockNStackProtocol.handler = { request in
            if request.url!.path.hasSuffix("/complete") { return (200,[:]) }
            return try normal(request)
        }
        let queue = NStackTransfers(root:root)
        try queue.save(helper.destination())
        queue.setAvailability(active:false,signer:helper.npub,api:helper.api(background))
        try queue.enqueueDiagnostics(snapshot:snapshot)
        queue.setAvailability(active:true,signer:helper.npub,api:helper.api(background))
        try await helper.wait { queue.jobs[0].state == "background_uploading" }
        background.finish(try XCTUnwrap(queue.jobs[0].files[0].backgroundTaskID))
        await queue.reconcileBackgroundTransfers()
        try await helper.wait { queue.jobs[0].state == "failed" }
        XCTAssertEqual(backend.posts,0)
        XCTAssertFalse(queue.jobs[0].files[0].complete)
        XCTAssertFalse(queue.diagnosticsStatus?.contains("Diagnostics sent") == true)
    }
    func testInterruptedReportRelaunchLockedFinalizationAndStorageCompletion() async throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        let helper = BackgroundUploadTests(), background = FakeBackgroundUploads(), backend = helper.installBackend()
        var queue = NStackTransfers(root:root)
        try queue.save(helper.destination())
        queue.setAvailability(active:false,signer:helper.npub,api:helper.api(background))
        try queue.enqueueDiagnostics(snapshot:snapshot)
        queue.setAvailability(active:true,signer:helper.npub,api:helper.api(background))
        try await helper.wait { queue.jobs[0].state == "background_uploading" }
        let jobID = queue.jobs[0].id, objectID = queue.jobs[0].files[0].objectID
        let task = try XCTUnwrap(queue.jobs[0].files[0].backgroundTaskID)
        background.finish(task,status:503,error:"PRIVATE ERROR https://secret")
        await queue.reconcileBackgroundTransfers()
        XCTAssertEqual(queue.jobs[0].state,"failed"); XCTAssertEqual(backend.posts,0)
        XCTAssertFalse(queue.diagnosticsStatus?.contains("Diagnostics sent") == true)
        queue.retry(jobID)
        try await helper.wait { queue.jobs[0].state == "background_uploading" }
        let retryTask = try XCTUnwrap(queue.jobs[0].files[0].backgroundTaskID)
        queue.setAvailability(active:true,signer:nil,api:helper.api(background))
        background.finish(retryTask)
        await queue.reconcileBackgroundTransfers()
        queue = NStackTransfers(root:root)
        queue.setAvailability(active:true,signer:nil,api:helper.api(background))
        XCTAssertEqual(backend.posts,0); XCTAssertEqual(backend.completes,0)
        XCTAssertEqual(queue.jobs[0].files[0].objectID,objectID)
        queue.setAvailability(active:true,signer:helper.npub,api:helper.api(background))
        try await helper.wait { queue.jobs[0].state == "sent" }
        XCTAssertEqual(backend.prepares,1); XCTAssertEqual(backend.completes,1); XCTAssertEqual(backend.posts,1)
        XCTAssertTrue(queue.diagnosticsStatus?.contains("storage://" + objectID!) == true)
        let report = try Data(contentsOf:root.appendingPathComponent(jobID.uuidString).appendingPathComponent("diagnostics.json"))
        XCTAssertFalse(String(decoding:report,as:UTF8.self).contains("PRIVATE ERROR"))
    }
}

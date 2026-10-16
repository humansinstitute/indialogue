import XCTest
@testable import PeteRecorder

@MainActor
final class FakeBackgroundUploads: BackgroundUploadClient {
    var onEvents: (() -> Void)?
    var live: [BackgroundUploadTask] = []
    var events: [BackgroundUploadEvent] = []
    var requests: [URLRequest] = []
    var resumed: [Int] = []
    var cancelled: [Int] = []
    var drainedCount = 0
    private var nextID = 40

    func makeUpload(request: URLRequest, file: URL, description: String) throws -> BackgroundUploadTask {
        nextID += 1
        let task = BackgroundUploadTask(identifier:nextID,description:description)
        live.append(task); requests.append(request)
        return task
    }
    func resume(_ identifier: Int) { resumed.append(identifier) }
    func cancel(_ identifier: Int) { cancelled.append(identifier); live.removeAll{$0.identifier == identifier} }
    func tasks() async -> [BackgroundUploadTask] { live }
    func drainEvents() -> [BackgroundUploadEvent] { defer { events.removeAll() }; return events }
    func requeueEvents(_ events: [BackgroundUploadEvent]) { self.events.insert(contentsOf:events,at:0) }
    func reconciliationDrained() { drainedCount += 1 }
    func handleEvents(completion: @escaping () -> Void) { completion() }
    func finish(_ identifier: Int, status: Int = 200, error: String? = nil) {
        let task = live.first{$0.identifier == identifier}
        live.removeAll{$0.identifier == identifier}
        events.append(BackgroundUploadEvent(identifier:identifier,description:task?.description,statusCode:status,errorDescription:error))
        onEvents?()
    }
    func inject(_ event: BackgroundUploadEvent) { events.append(event); onEvents?() }
}

final class BackgroundBackend {
    var prepares = 0
    var completes = 0
    var posts = 0
    var objects: [String:(Int,String,Bool)] = [:]
}

@MainActor
final class BackgroundUploadTests: XCTestCase {
    let npub = NostrCodec.npub(Data(repeating:1,count:32))
    func temp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    func destination() -> NStackDestination {
        NStackDestination(origin:"https://nstack.example",signer:npub,workspace:UUID().uuidString,workspaceLabel:"Workspace",appNpub:npub,channel:UUID().uuidString,channelLabel:"Channel",recipient:nil,recipientLabel:nil,prompt:"Review.",automatic:true)
    }
    func record() -> Recording {
        var value = Recording(title:"Background fixture")
        value.state = .saved; value.segments = ["segment.m4a"]; value.transcriptionState = .complete; value.transcript = "hello"
        return value
    }
    func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockNStackProtocol.self]
        return URLSession(configuration:configuration)
    }
    func api(_ background: BackgroundUploadClient) -> NStackAPI {
        NStackAPI(session:session(),backgroundUploads:background) { kind,tags,content in
            NostrEvent(id:String(repeating:"0",count:64),pubkey:String(repeating:"01",count:32),created_at:1,kind:kind,tags:tags,content:content,sig:String(repeating:"0",count:128))
        }
    }
    func installBackend() -> BackgroundBackend {
        let box = BackgroundBackend()
        MockNStackProtocol.handler = { request in
            let path = request.url!.path
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating:0,count:4096)
                while stream.hasBytesAvailable { let count = stream.read(&bytes,maxLength:bytes.count); if count <= 0 { break }; data.append(contentsOf:bytes.prefix(count)) }
            }
            let body = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]
            if path.hasSuffix("/prepare") {
                box.prepares += 1; let id = UUID().uuidString
                box.objects[id] = (body["size_bytes"] as! Int,body["sha256_hex"] as! String,false)
                return (201,["object_id":id,"upload_url":"https://storage.example/private/\(id)?signature=fixed"])
            }
            if path.hasSuffix("/messages") { box.posts += 1; return (201,["message":["id":UUID().uuidString]]) }
            let id = path.split(separator:"/")[3].description
            if path.hasSuffix("/complete") { box.completes += 1; box.objects[id]!.2 = true; return (200,[:]) }
            let object = box.objects[id]!
            var result:[String:Any] = ["size_bytes":object.0,"sha256_hex":object.1]
            if object.2 { result["completed_at"] = "2026-10-16" }
            return (200,result)
        }
        return box
    }
    func wait(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for:.milliseconds(10)) }
        XCTFail("Timed out waiting for transfer state")
    }
    func makeQueue(root: URL, background: FakeBackgroundUploads) throws -> NStackTransfers {
        let queue = NStackTransfers(root:root), source = root.appendingPathComponent("source.m4a")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try Data([1,2,3,4]).write(to:source)
        try queue.enqueue(record(),destination:destination(),audio:source,corrected:"hello")
        return queue
    }

    func testForegroundTransferContinuesWhenAppBackgrounds() async throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        let background = FakeBackgroundUploads(); let backend = installBackend()
        let queue = try makeQueue(root:root,background:background)
        queue.setAvailability(active:true,signer:npub,api:api(background))
        try await wait { queue.jobs[0].state == "background_uploading" }
        let task = try XCTUnwrap(queue.jobs[0].files[0].backgroundTaskID)
        queue.enterBackground()
        queue.backgroundExecutionExpired()
        XCTAssertEqual(queue.jobs[0].state,"background_uploading")
        XCTAssertTrue(background.live.contains{$0.identifier == task})
        XCTAssertFalse(background.cancelled.contains(task))
    }

    func testCallbacksUpdateCorrectFilesAndFinalizeExactlyOnce() async throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        let background = FakeBackgroundUploads(); let backend = installBackend()
        let queue = try makeQueue(root:root,background:background)
        queue.setAvailability(active:true,signer:npub,api:api(background))
        try await wait { background.live.count == 1 }
        background.finish(background.live[0].identifier)
        try await wait { background.live.count == 1 && queue.jobs[0].files[0].complete }
        background.finish(background.live[0].identifier)
        try await wait { queue.jobs[0].state == "sent" }
        XCTAssertEqual(backend.prepares,2); XCTAssertEqual(backend.completes,2); XCTAssertEqual(backend.posts,1)
        XCTAssertEqual(background.requests.count,2)
        background.inject(BackgroundUploadEvent(identifier:999,description:"stale",statusCode:200,errorDescription:nil))
        try await Task.sleep(for:.milliseconds(30))
        XCTAssertEqual(backend.posts,1); XCTAssertEqual(queue.jobs[0].state,"sent")
    }

    func testRelaunchAttachesTaskWithoutRepeatingPrepareOrPut() async throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        let background = FakeBackgroundUploads(); let backend = installBackend()
        let first = try makeQueue(root:root,background:background)
        first.setAvailability(active:true,signer:npub,api:api(background))
        try await wait { background.live.count == 1 }
        let task = background.live[0], prepareCount = backend.prepares, putCount = background.requests.count
        let restored = NStackTransfers(root:root)
        restored.setAvailability(active:true,signer:npub,api:api(background))
        try await Task.sleep(for:.milliseconds(50))
        XCTAssertEqual(restored.jobs[0].state,"background_uploading")
        XCTAssertEqual(restored.jobs[0].files[0].backgroundTaskID,task.identifier)
        XCTAssertEqual(backend.prepares,prepareCount); XCTAssertEqual(background.requests.count,putCount)
    }

    func testInterruptionIsDurableAndRetryableWithoutNewObject() async throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        let background = FakeBackgroundUploads(); let backend = installBackend()
        let queue = try makeQueue(root:root,background:background)
        queue.setAvailability(active:true,signer:npub,api:api(background))
        try await wait { background.live.count == 1 }
        let object = queue.jobs[0].files[0].objectID
        background.finish(background.live[0].identifier,error:"connection lost")
        try await wait { queue.jobs[0].state == "failed" }
        XCTAssertEqual(NStackTransfers(root:root).jobs[0].state,"failed")
        queue.retry(queue.jobs[0].id)
        try await wait { background.live.count == 1 }
        XCTAssertEqual(queue.jobs[0].files[0].objectID,object); XCTAssertEqual(backend.prepares,1)
    }

    func testLockedAndMismatchedIdentityPauseFinalizationThenUnlockResumes() async throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        let background = FakeBackgroundUploads(); let backend = installBackend()
        let queue = try makeQueue(root:root,background:background), unlockedAPI = api(background)
        queue.setAvailability(active:true,signer:npub,api:unlockedAPI)
        try await wait { background.live.count == 1 }
        queue.setAvailability(active:true,signer:nil,api:unlockedAPI)
        background.finish(background.live[0].identifier)
        try await wait { queue.jobs[0].state == "paused_locked" }
        XCTAssertEqual(backend.completes,0)
        queue.setAvailability(active:true,signer:NostrCodec.npub(Data(repeating:2,count:32)),api:unlockedAPI)
        XCTAssertEqual(queue.jobs[0].state,"paused_identity")
        queue.setAvailability(active:true,signer:npub,api:unlockedAPI)
        try await wait { backend.completes == 1 }
    }

    func testBackgroundSessionCompletionWaitsForEventDrain() {
        let coordinator = BackgroundUploadCoordinator.shared
        _ = coordinator.drainEvents()
        var completed = false
        coordinator.handleEvents { completed = true }
        coordinator.accept(BackgroundUploadEvent(identifier:777,description:"unknown",statusCode:200,errorDescription:nil))
        coordinator.finishDelegateEvents()
        XCTAssertFalse(completed)
        _ = coordinator.drainEvents()
        XCTAssertFalse(completed)
        coordinator.reconciliationDrained()
        XCTAssertTrue(completed)

        var unknownCompleted = false
        RecorderAppDelegate().application(UIApplication.shared,handleEventsForBackgroundURLSession:"unknown.session") { unknownCompleted = true }
        XCTAssertTrue(unknownCompleted)
    }
}

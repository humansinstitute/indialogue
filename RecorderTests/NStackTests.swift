import XCTest
import P256K
@testable import PeteRecorder

final class MockNStackProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int,[String:Any]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status,json) = try Self.handler!(request)
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:try NostrCodec.json(json)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() {}
}
@MainActor
final class NStackTests: XCTestCase {
    let npub = NostrCodec.npub(Data(repeating:1,count:32))
    func destination() -> NStackDestination {
        NStackDestination(origin:"https://nstack.example",signer:npub,workspace:UUID().uuidString,workspaceLabel:"Workspace",appNpub:npub,channel:UUID().uuidString,channelLabel:"DMs / Agent",recipient:npub,recipientLabel:"Agent",prompt:"Review this recording.",automatic:true)
    }
    func session() -> URLSession { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [MockNStackProtocol.self]; return URLSession(configuration:c) }
    func api(_ events: @escaping (Int,[[String]],String) -> Void = {_,_,_ in}) -> NStackAPI {
        NStackAPI(session:session()) { kind,tags,content in
            events(kind,tags,content)
            return NostrEvent(id:String(repeating:"0",count:64),pubkey:String(repeating:"01",count:32),created_at:1,kind:kind,tags:tags,content:content,sig:String(repeating:"0",count:128))
        }
    }
    func temp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    func record() -> Recording { var r = Recording(title:"Synthetic review"); r.state = .saved; r.segments = ["a.m4a"]; r.transcriptionState = .complete; r.transcript = "nosta"; r.correctedTranscript = "Edited nosta"; r.cleanupDraft = "Unaccepted draft"; return r }
    func testExactAuthenticationBytesAndOriginSafety() async throws {
        var captured: [[String]] = []
        let api = api { kind,tags,_ in XCTAssertEqual(kind,27235); captured = tags }
        let body:[String:Any] = ["z":"é / 😀","a":1]
        MockNStackProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod,"POST")
            // URLProtocol may expose upload streams rather than httpBody; auth hash is checked against the encoder below.
            return (200,["ok":true])
        }
        _ = try await api.request(origin:"https://nstack.example",path:"/api/v4/test",method:"POST",body:body)
        XCTAssertEqual(captured,[["u","https://nstack.example/api/v4/test"],["method","POST"],["payload",NostrCodec.hash(try NostrCodec.json(body))]])
        for unsafe in ["http://nstack.example","https://user:pass@nstack.example","https://nstack.example/path","https://nstack.example?x=1"] { XCTAssertThrowsError(try NStackAPI.origin(unsafe)) }
        XCTAssertTrue(NostrCodec.validNpub(npub)); XCTAssertFalse(NostrCodec.validNpub(npub.dropLast() + "x"))
    }
    func testSnapshotRetentionMessageSignatureAndNoOldAutomaticUpload() throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        let queue = NStackTransfers(root:root); let d = destination(); try queue.save(d)
        let r = record(); XCTAssertNil(queue.status(r.id))
        queue.rememberNew(r); XCTAssertEqual(queue.status(r.id),"Waiting for transcription")
        let audio = root.appendingPathComponent("source.m4a"); try Data([1,2,3]).write(to:audio)
        try queue.enqueue(r,destination:d,audio:audio,corrected:"Edited nostr")
        var job = try XCTUnwrap(queue.jobs.first)
        XCTAssertTrue(job.body.contains("@[Agent](mention:agent:")); XCTAssertFalse(job.body.contains("Unaccepted draft"))
        XCTAssertTrue(FileManager.default.fileExists(atPath:audio.path))
        let artifact = try String(contentsOf:root.appendingPathComponent(job.id.uuidString).appendingPathComponent("transcript.json"),encoding:.utf8)
        XCTAssertTrue(artifact.contains("Edited nostr")); XCTAssertTrue(artifact.contains("raw_transcript"))
        var changed = d; changed.prompt = "New prompt"; try queue.save(changed)
        XCTAssertEqual(NStackTransfers(root:root).jobs.first?.destination.prompt,d.prompt)
        for i in job.files.indices { job.files[i].objectID = UUID().uuidString }
        let message = try api { kind,tags,content in
            XCTAssertEqual(kind,33358); XCTAssertEqual(content,job.body)
            XCTAssertTrue(tags.contains(["body_sha256",NostrCodec.hash(Data(job.body.utf8))]))
            XCTAssertTrue(tags.contains(["channel_id",d.channel])); XCTAssertFalse(tags.contains(where:{$0[0] == "thread_id"}))
        }.message(job)
        XCTAssertEqual(message["client_request_id"] as? String,job.id.uuidString)
        XCTAssertEqual((message["mentions"] as? [[String:String]])?.first?["npub"],d.recipient)
        XCTAssertEqual(message["create_thread"] as? Bool,true)
        let restored = NStackTransfers(root:root); restored.setAvailability(active:true,signer:nil,api:api())
        XCTAssertEqual(restored.jobs[0].state,"paused_locked")
        restored.setAvailability(active:true,signer:NostrCodec.npub(Data(repeating:2,count:32)),api:api())
        XCTAssertEqual(restored.jobs[0].state,"paused_identity")
        restored.cancel(job.id); XCTAssertEqual(restored.jobs[0].state,"cancelled")
        XCTAssertTrue(FileManager.default.fileExists(atPath:audio.path))
    }
    func testPartialStorageAndAmbiguousMessageRetryUsesSameObjects() async throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        let queue = NStackTransfers(root:root); let d = destination(); let r = record()
        let audio = root.appendingPathComponent("source"); try Data([1,2,3]).write(to:audio)
        try queue.enqueue(r,destination:d,audio:audio,corrected:"Corrected")
        var prepares = 0; var posts = 0; var objects:[String:(Int,String,Bool)] = [:]; var ids:[String] = []
        MockNStackProtocol.handler = { req in
            let path = req.url!.path
            let bytes:Data
            if let body = req.httpBody { bytes = body }
            else if let stream = req.httpBodyStream { stream.open(); defer {stream.close()}; var data = Data(); var buffer = [UInt8](repeating:0,count:4096); while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count); if n <= 0 {break}; data.append(contentsOf:buffer.prefix(n)) }; bytes = data }
            else { bytes = Data() }
            let body = (try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any] ?? [:]
            if path.hasSuffix("/prepare") {
                prepares += 1; XCTAssertEqual(body["is_public"] as? Bool,false)
                let id = UUID().uuidString; objects[id] = (body["size_bytes"] as! Int,body["sha256_hex"] as! String,false)
                return (201,["object_id":id,"upload_url":"https://nstack.example/api/v4/storage/" + id])
            }
            if path.hasSuffix("/messages") { posts += 1; ids.append(body["client_request_id"] as! String); if posts == 1 { throw URLError(.networkConnectionLost) }; return (201,["message":["id":UUID().uuidString,"thread_id":UUID().uuidString]]) }
            let id = path.split(separator:"/")[3].description
            if req.httpMethod == "PUT" { XCTAssertNotNil(body["base64_data"]); return (200,["object_id":id]) }
            if path.hasSuffix("/complete") { objects[id]!.2 = true; return (200,["object_id":id]) }
            let o = objects[id]!; var result:[String:Any] = ["size_bytes":o.0,"sha256_hex":o.1]; if o.2 { result["completed_at"] = "2026-01-01" }; return (200,result)
        }
        queue.setAvailability(active:true,signer:npub,api:api())
        for _ in 0..<200 where queue.jobs[0].state != "failed" { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(queue.jobs[0].state,"failed"); XCTAssertEqual(prepares,2)
        let restored = NStackTransfers(root:root); restored.retry(restored.jobs[0].id); restored.setAvailability(active:true,signer:npub,api:api())
        for _ in 0..<200 where restored.jobs[0].state != "sent" { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(restored.jobs[0].state,"sent"); XCTAssertEqual(prepares,2); XCTAssertEqual(posts,2); XCTAssertEqual(ids.first,ids.last)
        XCTAssertTrue(FileManager.default.fileExists(atPath:audio.path))
    }
}

extension NStackTests {
    func testAutomaticTranscriptionThenCurrentVocabularySnapshotAndOldLibraryExclusion() async throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        let model = RecorderModel(root:root,speech:{ _,_ in LocalTranscript(text:"nosta 42",locale:"en") },audioExport:{ _ in
            let file = root.appendingPathComponent(UUID().uuidString + ".m4a"); try Data([1,2,3]).write(to:file); return file
        })
        try model.transfers.save(destination())
        var old = record(); old.title = "Old library"; try model.store!.save(old); model.recordings = [old]
        XCTAssertNil(model.transfers.status(old.id))
        model.saveVocabulary([VocabularyCorrection(heard:"nosta",replacement:"nostr")])
        var fresh = Recording(title:"New capture"); fresh.segments = ["segment.m4a"]
        try model.store!.save(fresh); model.active = fresh; model.stop()
        for _ in 0..<300 where model.transfers.jobs.isEmpty { try await Task.sleep(for:.milliseconds(10)) }
        let job = try XCTUnwrap(model.transfers.jobs.first)
        XCTAssertEqual(job.recordingID,fresh.id); XCTAssertTrue(job.body.contains("nostr 42"))
        XCTAssertEqual(model.recordings.first(where:{$0.id == fresh.id})?.transcript,"nosta 42")
        XCTAssertEqual(model.transfers.jobs.count,1)
        model.background()
    }
    func testPrepareUncertaintyDoesNotAllocateAgainAndIncompleteRefusal() async throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        let queue = NStackTransfers(root:root); let d = destination(); var r = record()
        let audio = root.appendingPathComponent("audio"); try Data([1]).write(to:audio)
        r.state = .interrupted; XCTAssertThrowsError(try queue.enqueue(r,destination:d,audio:audio,corrected:"text"))
        r.state = .saved; try queue.enqueue(r,destination:d,audio:audio,corrected:"text")
        var prepares = 0
        MockNStackProtocol.handler = { _ in prepares += 1; throw URLError(.timedOut) }
        queue.setAvailability(active:true,signer:npub,api:api())
        for _ in 0..<200 where queue.jobs[0].state != "failed" { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(prepares,1); XCTAssertTrue(queue.jobs[0].files[0].preparing)
        queue.retry(queue.jobs[0].id)
        for _ in 0..<200 where queue.jobs[0].state != "failed" { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(prepares,1); XCTAssertTrue(queue.jobs[0].notice?.contains("uncertain") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath:audio.path))
    }
}

// Bitcoin BIP340 official test vector 0, public synthetic scalar 3.
extension NStackTests {
    func testOfficialBIP340VectorZero() throws {
        let key = try P256K.Schnorr.PrivateKey(dataRepresentation:Data([UInt8](repeating:0,count:31) + [3]))
        var message = [UInt8](repeating:0,count:32); var auxiliary = [UInt8](repeating:0,count:32)
        let signature = try key.signature(message:&message,auxiliaryRand:&auxiliary,strict:true)
        XCTAssertEqual(Data(key.xonly.bytes).hex,"f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9")
        XCTAssertEqual(signature.dataRepresentation.hex,"e907831f80848d1069a5371b402410364bdf1c5f8307b0084c55f1ce2dca821525f66a4a85ea8b71e482a74f382d2ce5ebeee8fdb2172f477df4900d310536c0")
    }
}

extension NStackTests {
    func testRestartAfterTranscriptionResumesPendingSnapshot() async throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root); try? FileManager.default.removeItem(at:root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-transfers")) }
        let store = try RecordingStore(root:root); let r = record(); try store.save(r)
        let transferRoot = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-transfers")
        let queue = NStackTransfers(root:transferRoot); try queue.save(destination()); queue.rememberNew(r)
        let model = RecorderModel(root:root,audioExport:{ _ in let file = root.appendingPathComponent("export.m4a"); try Data([1,2,3]).write(to:file); return file })
        for _ in 0..<200 where model.transfers.jobs.isEmpty { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(model.transfers.jobs.first?.recordingID,r.id)
        XCTAssertTrue(model.transfers.intents.isEmpty)
        model.background()
    }
    func testPartialPutFailurePersistsPreparedObjectAndRetryCompletes() async throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        let queue = NStackTransfers(root:root); let audio = root.appendingPathComponent("audio"); try Data([1,2,3]).write(to:audio)
        try queue.enqueue(record(),destination:destination(),audio:audio,corrected:"text")
        var prepares = 0; var puts = 0
        MockNStackProtocol.handler = { request in
            if request.url!.path.hasSuffix("/prepare") { prepares += 1; let id = UUID().uuidString; return (201,["object_id":id,"upload_url":"https://nstack.example/api/v4/storage/" + id]) }
            if request.httpMethod == "PUT" { puts += 1; throw URLError(.notConnectedToInternet) }
            return (200,[:])
        }
        queue.setAvailability(active:true,signer:npub,api:api())
        for _ in 0..<200 where queue.jobs[0].state != "failed" { try await Task.sleep(for:.milliseconds(10)) }
        let firstID = queue.jobs[0].files[0].objectID
        XCTAssertNotNil(firstID); XCTAssertEqual(prepares,1); XCTAssertEqual(puts,1)
        let restored = NStackTransfers(root:root); restored.retry(restored.jobs[0].id); restored.setAvailability(active:true,signer:npub,api:api())
        for _ in 0..<200 where restored.jobs[0].state != "failed" { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(prepares,1); XCTAssertEqual(puts,2); XCTAssertEqual(restored.jobs[0].files[0].objectID,firstID)
        XCTAssertTrue(FileManager.default.fileExists(atPath:audio.path))
    }
}

extension NStackTests {
    func testAgentDirectoryCanonicalSelectionFixtures() throws {
        let fixtures:[String:Any] = ["workspace_agents":[["agent_npub":npub,"display_name":"Agent","is_visible":true,"metadata":["can_instruct":true]],["agent_npub":npub,"display_name":"Duplicate"],["agent_npub":"invalid","display_name":"Never infer"],["agent_npub":NostrCodec.npub(Data(repeating:2,count:32)),"display_name":"Hidden","is_visible":false]]]
        let choices = try NStackDiscovery.agents(fixtures)
        XCTAssertEqual(choices.count,1); XCTAssertEqual(choices[0].id,npub); XCTAssertEqual(choices[0].label,"Agent")
        XCTAssertThrowsError(try NStackDiscovery.agents(["error":"denied"]))
    }
    func testIdleQueueDoesNotRequestNetworkOrBusyLoop() async throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        let queue = NStackTransfers(root:root); var calls = 0
        MockNStackProtocol.handler = { _ in calls += 1; return (200,[:]) }
        queue.setAvailability(active:true,signer:npub,api:api())
        try await Task.sleep(for:.milliseconds(30))
        XCTAssertEqual(calls,0); XCTAssertTrue(queue.jobs.isEmpty)
    }
}

extension NStackTests {
    func testHTTPAPIAdvertisedFallbackPinsHTTPSAndPresignedHasNoAuth() async throws {
        let root = temp(); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer {try? FileManager.default.removeItem(at:root)}
        let file = root.appendingPathComponent("audio"); try Data([1,2,3]).write(to:file)
        let object = UUID().uuidString; var urls:[String] = []
        MockNStackProtocol.handler = { request in
            urls.append(request.url!.absoluteString)
            if request.url!.host == "nstack.example" { XCTAssertNotNil(request.value(forHTTPHeaderField:"Authorization")); XCTAssertEqual(request.value(forHTTPHeaderField:"Content-Type"),"application/json") }
            else { XCTAssertNil(request.value(forHTTPHeaderField:"Authorization")) }
            return (200,[:])
        }
        let api = api()
        try await api.putFile(file,upload:"http://nstack.example/api/v4/storage/" + object,origin:"https://nstack.example",object:object,mime:"audio/mp4",size:3)
        try await api.putFile(file,upload:"https://storage.example/bucket/object?signature=opaque",origin:"https://nstack.example",object:object,mime:"audio/mp4",size:3)
        XCTAssertEqual(urls.first,"https://nstack.example/api/v4/storage/" + object)
        XCTAssertEqual(urls.last,"https://storage.example/bucket/object?signature=opaque")
    }
    func testImmediateLockUnlockBeforeCancelledWorkerUnwindsResumes() async throws {
        let root = temp(); defer {try? FileManager.default.removeItem(at:root)}
        let queue = NStackTransfers(root:root); let file = root.appendingPathComponent("audio"); try Data([1]).write(to:file)
        try queue.enqueue(record(),destination:destination(),audio:file,corrected:"text")
        var requests = 0
        MockNStackProtocol.handler = { _ in requests += 1; throw URLError(.notConnectedToInternet) }
        let api = api()
        queue.setAvailability(active:true,signer:npub,api:api)
        queue.setAvailability(active:false,signer:nil,api:api)
        queue.setAvailability(active:true,signer:npub,api:api)
        for _ in 0..<200 where queue.jobs[0].state != "failed" {try await Task.sleep(for:.milliseconds(10))}
        XCTAssertEqual(queue.jobs[0].state,"failed"); XCTAssertEqual(requests,1)
        try await Task.sleep(for:.milliseconds(20)); XCTAssertEqual(requests,1)
    }
}


extension NStackTests {
    func testStrictStorageByteCountsAndIntegrityErrors() throws {
        for json in ["0", "101", "9223372036854775807", "\"0\"", "\"101\"", "\"9223372036854775807\""] {
            let value = try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
            XCTAssertNoThrow(try StorageMetadata.byteCount(value), json)
        }
        for json in ["true", "false", "-1", "1.5", "1.01", "9223372036854775808", "null", "[]", "{}", "\"-1\"", "\"+1\"", "\"1.0\"", "\"1e2\"", "\" 101\"", "\"101 \"", "\"\"", "\"１２\"", "\"9223372036854775808\""] {
            let value = try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
            XCTAssertThrowsError(try StorageMetadata.byteCount(value), json)
        }
        XCTAssertThrowsError(try StorageMetadata.byteCount(nil))
        XCTAssertFalse(try StorageMetadata.isCompleted([:]))
        XCTAssertFalse(try StorageMetadata.isCompleted(["completed_at":NSNull()]))
        XCTAssertThrowsError(try StorageMetadata.isCompleted(["completed_at":42]))
        XCTAssertThrowsError(try StorageMetadata.isCompleted(["completed_at":""]))
        let file = TransferFile(name:"audio",mime:"audio/mp4",size:101,checksum:String(repeating:"a",count:64))
        XCTAssertNoThrow(try StorageMetadata.validateCompleted(["completed_at":"done","size_bytes":"101","sha256_hex":file.checksum], file:file))
        for (metadata, expected) in [
            (["completed_at":"done","size_bytes":"bad","sha256_hex":file.checksum] as [String:Any], NStackError.storageMetadata),
            (["completed_at":"done","size_bytes":101,"sha256_hex":"bad"], NStackError.storageMetadata),
            (["completed_at":"done","size_bytes":102,"sha256_hex":file.checksum], NStackError.storageMismatch),
            (["completed_at":"done","size_bytes":"101","sha256_hex":String(repeating:"b",count:64)], NStackError.storageMismatch),
            (["size_bytes":"101","sha256_hex":file.checksum], NStackError.storageIncomplete)
        ] {
            XCTAssertThrowsError(try StorageMetadata.validateCompleted(metadata,file:file)) { error in
                XCTAssertEqual(error.localizedDescription,expected.localizedDescription)
            }
        }
    }

    func testStringReadbackAndRestartFailedJobRetriesOriginalCompletedAudio() async throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        let queue = NStackTransfers(root:root); let r = record(); let d = destination()
        let audio = root.appendingPathComponent("source"); try Data([1,2,3]).write(to:audio)
        try queue.enqueue(r,destination:d,audio:audio,corrected:"Original text")
        let initial = queue.jobs[0]
        var prepares = 0; var puts:[String:Int] = [:]; var objects:[String:(Int,String,Bool)] = [:]
        var malformedOnce = true; var posted:[String:Any] = [:]
        MockNStackProtocol.handler = { req in
            let path = req.url!.path
            var bytes = req.httpBody ?? Data()
            if let stream = req.httpBodyStream {
                stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating:0,count:4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count); if n <= 0 { break }; bytes.append(contentsOf:buffer.prefix(n)) }
            }
            let body = (try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any] ?? [:]
            if path.hasSuffix("/prepare") {
                prepares += 1; let id = UUID().uuidString
                objects[id] = (body["size_bytes"] as! Int,body["sha256_hex"] as! String,false)
                return (201,["object_id":id,"upload_url":"https://nstack.example/api/v4/storage/" + id])
            }
            if path.hasSuffix("/messages") { posted = body; return (201,["message":["id":UUID().uuidString]]) }
            let id = path.split(separator:"/")[3].description
            if req.httpMethod == "PUT" { puts[id,default:0] += 1; return (200,[:]) }
            if path.hasSuffix("/complete") { objects[id]!.2 = true; return (200,[:]) }
            let object = objects[id]!
            var metadata:[String:Any] = ["size_bytes":String(object.0),"sha256_hex":object.1]
            if object.2 {
                metadata["completed_at"] = "2026-01-01"
                if malformedOnce { malformedOnce = false; metadata["size_bytes"] = "invalid" }
            }
            return (200,metadata)
        }
        queue.setAvailability(active:true,signer:npub,api:api())
        for _ in 0..<200 where queue.jobs[0].state != "failed" { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(queue.jobs[0].state,"failed")
        XCTAssertTrue(queue.jobs[0].notice?.contains("invalid size") == true)
        let audioID = try XCTUnwrap(queue.jobs[0].files[0].objectID)
        XCTAssertFalse(queue.jobs[0].files[0].complete)
        XCTAssertEqual(prepares,1); XCTAssertEqual(puts[audioID],1)
        let restored = NStackTransfers(root:root)
        var changed = d; changed.channel = UUID().uuidString; changed.prompt = "Changed prompt"
        try restored.save(changed)
        restored.setAvailability(active:true,signer:npub,api:api())
        XCTAssertEqual(restored.jobs[0].state,"failed") // unlock alone never silently retries a failure
        restored.retry(initial.id)
        for _ in 0..<200 where restored.jobs[0].state != "sent" { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(restored.jobs[0].state,"sent")
        XCTAssertEqual(prepares,2); XCTAssertEqual(puts[audioID],1)
        XCTAssertEqual(restored.jobs[0].files[0].objectID,audioID)
        XCTAssertTrue(restored.jobs[0].files.allSatisfy(\.complete))
        XCTAssertEqual(restored.jobs[0].destination,d); XCTAssertEqual(restored.jobs[0].body,initial.body)
        XCTAssertEqual(posted["client_request_id"] as? String,initial.id.uuidString)
        XCTAssertEqual(posted["body"] as? String,initial.body)
        XCTAssertTrue(FileManager.default.fileExists(atPath:audio.path))
    }

    func testUploadButtonRetriesExistingSnapshotWithoutExportOrRetarget() throws {
        let root = temp(); let transferRoot = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-transfers")
        defer { try? FileManager.default.removeItem(at:root); try? FileManager.default.removeItem(at:transferRoot) }
        let model = RecorderModel(root:root,audioExport:{ _ in XCTFail("Retry must not export again"); throw NStackError.incomplete })
        let audio = root.appendingPathComponent("audio"); try Data([1]).write(to:audio)
        let r = record(); let d = destination()
        try model.transfers.enqueue(r,destination:d,audio:audio,corrected:"Immutable")
        var ledger = NStackTransfers.Ledger(jobs:model.transfers.jobs,intents:[],destination:nil)
        ledger.jobs[0].state = "failed"; ledger.jobs[0].files[0].objectID = UUID().uuidString
        try JSONEncoder().encode(ledger).write(to:transferRoot.appendingPathComponent("ledger.json"))
        let restored = RecorderModel(root:root,audioExport:{ _ in XCTFail("Retry must not export again"); throw NStackError.incomplete })
        restored.upload(r,destination:destination())
        XCTAssertEqual(restored.transfers.jobs.count,1)
        XCTAssertEqual(restored.transfers.jobs[0].id,ledger.jobs[0].id)
        XCTAssertEqual(restored.transfers.jobs[0].files,ledger.jobs[0].files)
        XCTAssertEqual(restored.transfers.jobs[0].destination,d)
        XCTAssertEqual(restored.transfers.jobs[0].state,"paused_locked")
        restored.background(); model.background()
    }

    func testForegroundUnlockPolicyDoesNotLoopOrRequireIdentity() {
        var policy = ForegroundUnlockPolicy()
        XCTAssertFalse(policy.request(active:false,exists:true,unlocked:false))
        XCTAssertFalse(policy.request(active:true,exists:false,unlocked:false))
        XCTAssertFalse(policy.request(active:true,exists:true,unlocked:true))
        XCTAssertTrue(policy.request(active:true,exists:true,unlocked:false))
        XCTAssertFalse(policy.request(active:true,exists:true,unlocked:false)) // dismiss/internal navigation
        policy.background()
        XCTAssertTrue(policy.request(active:true,exists:true,unlocked:false))
    }
}


extension NStackTests {
    func testLocalSnapshotMismatchStopsBeforeNetworkAndKeepsOriginal() async throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        let queue = NStackTransfers(root:root); let audio = root.appendingPathComponent("source")
        try Data([1,2,3]).write(to:audio)
        try queue.enqueue(record(),destination:destination(),audio:audio,corrected:"text")
        try Data([3,2,1]).write(to:root.appendingPathComponent(queue.jobs[0].id.uuidString).appendingPathComponent("recording.m4a"))
        var calls = 0; MockNStackProtocol.handler = { _ in calls += 1; return (200,[:]) }
        queue.setAvailability(active:true,signer:npub,api:api())
        for _ in 0..<200 where queue.jobs[0].state != "failed" { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(queue.jobs[0].state,"failed"); XCTAssertEqual(calls,0)
        XCTAssertEqual(queue.jobs[0].notice,NStackError.snapshotMismatch.localizedDescription)
        XCTAssertEqual(try Data(contentsOf:audio),Data([1,2,3]))
    }
}

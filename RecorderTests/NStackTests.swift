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
        queue.rememberNew(r); XCTAssertEqual(queue.status(r.id),"Waiting for transcription or upload preparation")
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
    func testRecentConversationLimitValidationPersistenceAndNewestUniqueSelection() throws {
        XCTAssertEqual(NStackTransfers.validatedRecentConversationLimit(nil),5)
        XCTAssertEqual(NStackTransfers.validatedRecentConversationLimit("21"),5)
        XCTAssertEqual(NStackTransfers.validatedRecentConversationLimit(true),5)
        XCTAssertEqual(NStackTransfers.validatedRecentConversationLimit(0),5)
        XCTAssertEqual(NStackTransfers.validatedRecentConversationLimit(51),5)
        XCTAssertEqual(NStackTransfers.validatedRecentConversationLimit(21),21)

        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        let destination = destination(), sharedConversation = UUID()
        var oldest = TransferJob(recordingID:UUID(),destination:destination,title:"Old",body:"",createdAt:Date(timeIntervalSince1970:1),files:[],conversationID:sharedConversation)
        oldest.state = "sent"; oldest.threadID = "thread"
        var followup = TransferJob(recordingID:UUID(),destination:destination,title:"Follow up",body:"",createdAt:Date(timeIntervalSince1970:2),files:[],conversationID:sharedConversation)
        followup.state = "sent"; followup.threadID = "thread"
        let newest = TransferJob(recordingID:UUID(),destination:destination,title:"Newest",body:"",createdAt:Date(timeIntervalSince1970:3),files:[],conversationID:UUID())
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try JSONEncoder().encode(NStackTransfers.Ledger(jobs:[oldest,followup,newest],intents:[],destination:nil)).write(to:root.appendingPathComponent("ledger.json"))

        let suite = "RecentConversationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let transfers = NStackTransfers(root:root,defaults:defaults)
        XCTAssertTrue(transfers.saveRecentConversationLimit("21"))
        XCTAssertEqual(transfers.recentConversationLimit,21)
        XCTAssertEqual(transfers.recentConversationJobs.map(\.title),["Newest","Follow up"])
        XCTAssertEqual(NStackTransfers(root:root,defaults:defaults).recentConversationLimit,21)
        XCTAssertFalse(transfers.saveRecentConversationLimit("banana"))
        XCTAssertFalse(transfers.saveRecentConversationLimit("51"))
        XCTAssertEqual(transfers.recentConversationLimit,21)
    }

    func testConversationStatusAndGreyRetryKeepImmutableDestination() throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        let immutable = destination()
        var local = TransferJob(recordingID:UUID(),destination:immutable,title:"Pending",body:"",files:[],state:"failed",notice:"Offline",conversationID:UUID(),dialogueMode:.agent)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try JSONEncoder().encode(NStackTransfers.Ledger(jobs:[local],intents:[],destination:nil)).write(to:root.appendingPathComponent("ledger.json"))
        let transfers = NStackTransfers(root:root)
        XCTAssertEqual(transfers.conversationStatus(for:transfers.jobs[0]),.failed)
        transfers.sendPendingConversation(transfers.jobs[0].id)
        XCTAssertEqual(transfers.jobs[0].state,"paused_locked")
        XCTAssertEqual(transfers.jobs[0].destination,immutable)

        local.state = "sent"; local.threadID = "thread"
        try JSONEncoder().encode(NStackTransfers.Ledger(jobs:[local],intents:[],destination:nil)).write(to:root.appendingPathComponent("ledger.json"))
        let sent = NStackTransfers(root:root)
        XCTAssertEqual(sent.conversationStatus(for:sent.jobs[0]),.waiting)
        let conversation = try XCTUnwrap(sent.jobs[0].conversationID)
        XCTAssertTrue(sent.storeReply(DialogueReply(id:"reply",body:"Done",sender:"Rick",createdAt:nil,audioObjectID:nil),for:conversation))
        XCTAssertEqual(sent.conversationStatus(for:sent.jobs[0]),.replied)
    }

    func testAudioFirstStopSkipsSpeechAndCreatesHonestUploadSnapshot() async throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        var speechCalls = 0
        let model = RecorderModel(root:root,speech:{ _,_ in
            speechCalls += 1
            return LocalTranscript(text:"must not run",locale:"en")
        },audioExport:{ _ in
            let file = root.appendingPathComponent(UUID().uuidString + ".m4a")
            try Data([1,2,3]).write(to:file); return file
        })
        var d = destination(); d.automatic = false
        try model.transfers.save(d)
        var recording = Recording(title:"Audio first")
        recording.segments = ["segment.m4a"]
        recording.dialogueRoute = DialogueRouteSnapshot(mode:.agent,destination:d,threadID:nil)
        try model.store!.save(recording); model.active = recording

        model.stop(publishAudioOnly:true)
        for _ in 0..<300 where model.transfers.jobs.isEmpty || model.preparingUpload { try await Task.sleep(for:.milliseconds(10)) }

        XCTAssertEqual(speechCalls,0)
        let saved = try XCTUnwrap(model.recordings.first(where:{$0.id == recording.id}))
        XCTAssertEqual(saved.deliveryContent,.audioOnly)
        XCTAssertEqual(saved.transcriptionState,.none)
        let job = try XCTUnwrap(model.transfers.jobs.first)
        XCTAssertTrue(job.body.contains("Please transcribe and process it on the agent/server"))
        XCTAssertTrue(job.body.contains("No transcript is attached"))
        XCTAssertTrue(job.body.hasPrefix("@[Agent](mention:agent:\(d.recipient!))"))
        XCTAssertFalse(job.body.contains("Full corrected transcript"))
        let artifactURL = model.transfers.root.appendingPathComponent(job.id.uuidString).appendingPathComponent("transcript.json")
        let artifact = try JSONSerialization.jsonObject(with:Data(contentsOf:artifactURL)) as! [String:Any]
        XCTAssertEqual(artifact["transcription_status"] as? String,"not_requested")
        XCTAssertEqual(artifact["transcription_requested"] as? String,"agent_or_server")
        XCTAssertEqual(artifact["transcript_attached"] as? Bool,false)
        XCTAssertNil(artifact["raw_transcript"])
        XCTAssertNil(artifact["corrected_transcript"])
        var postedJob = job
        for index in postedJob.files.indices { postedJob.files[index].objectID = UUID().uuidString }
        let payload = try api().message(postedJob)
        let mention = try XCTUnwrap((payload["mentions"] as? [[String:String]])?.first)
        XCTAssertEqual(mention["npub"],d.recipient)
        XCTAssertEqual(mention["label"],d.recipientLabel)
        XCTAssertEqual(postedJob.destination.channel,d.channel)

        model.startTranscription(saved,download:false)
        for _ in 0..<300 where model.recordings.first(where:{$0.id == recording.id})?.transcriptionState != .complete { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(speechCalls,1,"A retained audio-first recording can still be transcribed later by explicit request")
        model.background()
    }

    func testAudioOnlySnapshotPersistsAcrossRelaunchWithoutTranscript() throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        let queue = NStackTransfers(root:root), d = destination()
        var recording = Recording(title:"Persist audio first")
        recording.state = .saved; recording.segments = ["segment.m4a"]
        recording.deliveryContent = .audioOnly
        let audio = root.appendingPathComponent("source.m4a"); try Data([7,8,9]).write(to:audio)
        try queue.enqueue(recording,destination:d,audio:audio,corrected:"")

        let restored = NStackTransfers(root:root)
        let job = try XCTUnwrap(restored.jobs.first)
        XCTAssertEqual(job.recordingID,recording.id)
        XCTAssertTrue(job.body.contains("No transcript is attached"))
        XCTAssertEqual(job.files.map(\.name),["recording.m4a","transcript.json"])
    }

    func testAudioFirstRelaunchResumesIntentAndManualRetryReusesSnapshot() async throws {
        let root = temp()
        let transferRoot = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-transfers")
        defer { try? FileManager.default.removeItem(at:root); try? FileManager.default.removeItem(at:transferRoot) }
        let store = try RecordingStore(root:root)
        var recording = Recording(title:"Relaunch audio first")
        recording.state = .saved; recording.segments = ["segment.m4a"]; recording.deliveryContent = .audioOnly
        recording.dialogueRoute = DialogueRouteSnapshot(mode:.agent,destination:destination(),threadID:nil)
        try store.save(recording)
        let queue = NStackTransfers(root:transferRoot)
        XCTAssertTrue(queue.rememberNew(recording,force:true))

        var speechCalls = 0, exports = 0
        let launched = RecorderModel(root:root,speech:{ _,_ in
            speechCalls += 1; return LocalTranscript(text:"unexpected",locale:"en")
        },audioExport:{ _ in
            exports += 1
            let file = root.appendingPathComponent("relaunch-export.m4a")
            try Data([4,5,6]).write(to:file); return file
        })
        for _ in 0..<300 where launched.transfers.jobs.isEmpty || launched.preparingUpload { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(speechCalls,0)
        XCTAssertEqual(exports,1)
        XCTAssertEqual(launched.recordings.first?.deliveryContent,.audioOnly)
        let immutable = try XCTUnwrap(launched.transfers.jobs.first)

        var ledger = NStackTransfers.Ledger(jobs:launched.transfers.jobs,intents:launched.transfers.intents,destination:nil)
        ledger.jobs[0].state = "failed"
        try JSONEncoder().encode(ledger).write(to:transferRoot.appendingPathComponent("ledger.json"),options:.atomic)
        launched.background()

        let retried = RecorderModel(root:root,speech:{ _,_ in
            XCTFail("Retry must not start local transcription")
            return LocalTranscript(text:"unexpected",locale:"en")
        },audioExport:{ _ in
            XCTFail("Retry must reuse the immutable snapshot")
            throw NStackError.incomplete
        })
        retried.uploadAudioOnly(recording)
        XCTAssertEqual(retried.transfers.jobs.count,1)
        XCTAssertEqual(retried.transfers.jobs[0].id,immutable.id)
        XCTAssertEqual(retried.transfers.jobs[0].files,immutable.files)
        XCTAssertEqual(retried.transfers.jobs[0].body,immutable.body)
        XCTAssertEqual(retried.transfers.jobs[0].state,"paused_locked")
        retried.background()
    }

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

extension NStackTests {
    func testDialogueModePersistenceAndImmutableRouteSnapshot() throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        let queue = NStackTransfers(root:root)
        let normal = destination()
        var channel = normal; channel.channel = UUID().uuidString; channel.channelLabel = "Home / Ideas"; channel.recipient = nil; channel.recipientLabel = nil
        var agent = normal; agent.prompt = "Summarise this and propose the next action."
        try queue.saveRoute(normal,mode:.normal)
        try queue.saveRoute(channel,mode:.channel)
        try queue.saveRoute(agent,mode:.agent)
        try queue.setMode(.channel)
        let snapshot = try XCTUnwrap(queue.captureRoute())
        XCTAssertEqual(snapshot.mode,.channel); XCTAssertEqual(snapshot.destination,channel)

        var changed = channel; changed.channel = UUID().uuidString; changed.prompt = "Changed later"
        try queue.saveRoute(changed,mode:.channel)
        XCTAssertEqual(snapshot.destination,channel)
        let restored = NStackTransfers(root:root)
        XCTAssertEqual(restored.routing.mode,.channel); XCTAssertEqual(restored.routing.channel,changed); XCTAssertEqual(restored.routing.agent,agent)

        var recording = record(); recording.dialogueRoute = snapshot
        let decoded = try JSONDecoder().decode(Recording.self,from:JSONEncoder().encode(recording))
        XCTAssertEqual(decoded.dialogueRoute,snapshot)
    }

    func testChannelAndAgentPayloadsUseOneCanonicalIdentity() throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        let queue = NStackTransfers(root:root), audio = root.appendingPathComponent("audio")
        try Data([1]).write(to:audio)
        var channel = destination(); channel.recipient = nil; channel.recipientLabel = nil
        var first = record(); first.id = UUID()
        try queue.enqueue(first,route:DialogueRouteSnapshot(mode:.channel,destination:channel,threadID:nil),audio:audio,corrected:"Channel message")
        var channelJob = queue.jobs[0]; for i in channelJob.files.indices { channelJob.files[i].objectID = UUID().uuidString }
        let channelPayload = try api().message(channelJob)
        XCTAssertNil(channelPayload["mentions"]); XCTAssertFalse(channelJob.body.contains("mention:agent:"))

        var second = record(); second.id = UUID()
        try queue.enqueue(second,route:DialogueRouteSnapshot(mode:.agent,destination:destination(),threadID:nil),audio:audio,corrected:"Agent message")
        var agentJob = queue.jobs[1]; for i in agentJob.files.indices { agentJob.files[i].objectID = UUID().uuidString }
        let agentPayload = try api().message(agentJob)
        let structured = try XCTUnwrap((agentPayload["mentions"] as? [[String:String]])?.first)
        XCTAssertEqual(structured["npub"],destination().recipient)
        XCTAssertTrue(agentJob.body.hasPrefix("@[\(structured["label"]!)](mention:agent:\(structured["npub"]!))"))
    }

    func testInitialThreadAndSameThreadFollowupPayloads() throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        let queue = NStackTransfers(root:root), audio = root.appendingPathComponent("audio")
        try Data([1]).write(to:audio)
        let conversation = UUID(), thread = UUID().uuidString
        var first = record(); first.id = UUID()
        try queue.enqueue(first,route:DialogueRouteSnapshot(conversationID:conversation,mode:.agent,destination:destination(),threadID:nil),audio:audio,corrected:"First")
        let initial = try api { _,tags,_ in XCTAssertFalse(tags.contains(where:{$0.first == "thread_id"})) }.message(queue.jobs[0])
        XCTAssertEqual(initial["create_thread"] as? Bool,true); XCTAssertNil(initial["thread_id"])

        var second = record(); second.id = UUID()
        try queue.enqueue(second,route:DialogueRouteSnapshot(conversationID:conversation,mode:.agent,destination:destination(),threadID:thread),audio:audio,corrected:"Follow up")
        let follow = try api { _,tags,_ in XCTAssertTrue(tags.contains(["thread_id",thread])) }.message(queue.jobs[1])
        XCTAssertEqual(follow["thread_id"] as? String,thread); XCTAssertNil(follow["create_thread"])
        XCTAssertEqual(follow["client_request_id"] as? String,queue.jobs[1].id.uuidString)
        XCTAssertEqual(queue.jobs[1].conversationID,conversation)
    }

    func testReplyRetrievalAcceptsLiveNullDeletionAndNewestInheritedAudio() async throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        let queue = NStackTransfers(root:root), audio = root.appendingPathComponent("audio")
        try Data([1]).write(to:audio)
        try queue.enqueue(record(),route:DialogueRouteSnapshot(mode:.agent,destination:destination(),threadID:nil),audio:audio,corrected:"First")
        var ledger = NStackTransfers.Ledger(jobs:queue.jobs,intents:[],destination:nil)
        ledger.jobs[0].state = "sent"; ledger.jobs[0].messageID = "mine"; ledger.jobs[0].threadID = UUID().uuidString
        try JSONEncoder().encode(ledger).write(to:root.appendingPathComponent("ledger.json"))
        let restored = NStackTransfers(root:root); var calls = 0
        MockNStackProtocol.handler = { request in
            calls += 1; XCTAssertTrue(request.url!.query!.contains("effective_transcript=true"))
            if calls == 1 {
                XCTAssertNil(URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name == "cursor"}))
                return (200,["messages":[
                    ["id":"mine","body":"My request","record_state":"active","deleted_at":NSNull(),"created_at":"2026-10-16T01:00:00.123Z","metadata":["recorder":["version":1]]],
                    ["id":"older","body":"First answer","record_state":"active","deleted_at":NSNull(),"created_at":"2026-10-16T01:01:00.234Z","inherited":true,"read_only":true],
                    ["id":"other-recorder","body":"Recorder follow-up","record_state":"active","deleted_at":NSNull(),"created_at":"2026-10-16T01:01:30.000Z","metadata":["recorder":["version":1]]]
                ],"next_cursor":"page + two"])
            }
            XCTAssertEqual(URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name == "cursor"})?.value,"page + two")
            return (200,["messages":[
                ["id":"deleted","body":"","record_state":"deleted","deleted_at":"2026-10-16T01:01:30.000Z"],
                ["id":"reply","body":"Here is the answer","record_state":"active","deleted_at":NSNull(),"created_by_actor_label":"Rick","created_at":"2026-10-16T01:02:00.345Z","attachments":[["mime_type":"audio/mp4","storage_object_id":"audio-object"]],"owning_thread_id":"parent","effective_thread_id":"child","inherited":true,"read_only":true]
            ],"next_cursor":NSNull()])
        }
        restored.setAvailability(active:true,signer:npub,api:api())
        await restored.refreshReply(for:restored.jobs[0].id)
        let reply = try XCTUnwrap(restored.replies[restored.jobs[0].conversationID!])
        XCTAssertEqual(reply.body,"Here is the answer"); XCTAssertEqual(reply.audioObjectID,"audio-object"); XCTAssertEqual(reply.sender,"Rick")
        XCTAssertNotNil(reply.createdAt)
        restored.setAvailability(active:false,signer:nil,api:api())
        await restored.refreshReply(for:restored.jobs[0].id)
        XCTAssertEqual(calls,2); XCTAssertTrue(restored.replyNotice?.contains("foreground") == true)
    }

    func testReplyRetrievalEmptyThreadAndMalformedActiveReplyAreDistinct() async throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        let queue = NStackTransfers(root:root), audio = root.appendingPathComponent("audio")
        try Data([1]).write(to:audio)
        try queue.enqueue(record(),route:DialogueRouteSnapshot(mode:.agent,destination:destination(),threadID:nil),audio:audio,corrected:"First")
        var ledger = NStackTransfers.Ledger(jobs:queue.jobs,intents:[],destination:nil)
        ledger.jobs[0].state = "sent"; ledger.jobs[0].messageID = "mine"; ledger.jobs[0].threadID = UUID().uuidString
        try JSONEncoder().encode(ledger).write(to:root.appendingPathComponent("ledger.json"))
        let restored = NStackTransfers(root:root); var malformed = false
        MockNStackProtocol.handler = { _ in
            if malformed {
                return (200,["messages":[["id":"reply","record_state":"active","deleted_at":NSNull()]],"next_cursor":NSNull()])
            }
            return (200,["messages":[],"next_cursor":NSNull()])
        }
        restored.setAvailability(active:true,signer:npub,api:api())
        await restored.refreshReply(for:restored.jobs[0].id)
        XCTAssertTrue(restored.replyNotice?.contains("No new reply yet") == true)

        malformed = true
        await restored.refreshReply(for:restored.jobs[0].id)
        XCTAssertEqual(restored.replyNotice,NStackError.malformed.localizedDescription)
    }

    func testReplyPollingImmediateStopResumeOverlapAndDeduplication() async throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        let queue = NStackTransfers(root:root), audio = root.appendingPathComponent("audio")
        try Data([1]).write(to:audio)
        try queue.enqueue(record(),route:DialogueRouteSnapshot(mode:.agent,destination:destination(),threadID:nil),audio:audio,corrected:"First")
        var ledger = NStackTransfers.Ledger(jobs:queue.jobs,intents:[],destination:nil)
        ledger.jobs[0].state = "sent"; ledger.jobs[0].messageID = "mine"; ledger.jobs[0].threadID = UUID().uuidString
        try JSONEncoder().encode(ledger).write(to:root.appendingPathComponent("ledger.json"))
        let restored = NStackTransfers(root:root), jobID = ledger.jobs[0].id
        let conversation = try XCTUnwrap(ledger.jobs[0].conversationID)
        var calls = 0
        MockNStackProtocol.handler = { _ in
            calls += 1
            return (200,["messages":[["id":"one-reply","body":"Answer","record_state":"active","deleted_at":NSNull()]],"next_cursor":NSNull()])
        }
        restored.setAvailability(active:true,signer:npub,api:api())
        var delays = 0
        await restored.pollReplies(for:jobID,autoPlay:false) { duration in
            XCTAssertEqual(duration,NStackTransfers.replyPollInterval)
            delays += 1
            restored.setAvailability(active:false,signer:nil,api:self.api())
        }
        XCTAssertEqual(calls,1); XCTAssertEqual(delays,1)
        XCTAssertEqual(restored.replies[conversation]?.id,"one-reply")

        restored.setAvailability(active:true,signer:npub,api:api())
        await restored.pollReplies(for:jobID,autoPlay:false) { _ in throw CancellationError() }
        XCTAssertEqual(calls,2, "Resuming starts with another immediate check")

        let another = UUID()
        XCTAssertTrue(restored.beginReplyRefresh(for:jobID))
        XCTAssertFalse(restored.beginReplyRefresh(for:another), "Manual and automatic reads cannot overlap")
        restored.finishReplyRefresh(for:another); XCTAssertEqual(restored.replyRefreshJobID,jobID)
        restored.finishReplyRefresh(for:jobID); XCTAssertNil(restored.replyRefreshJobID)
        let same = try XCTUnwrap(restored.replies[conversation])
        XCTAssertFalse(restored.storeReply(same,for:conversation), "The same reply is not presented twice")
        XCTAssertTrue(restored.claimReplyPlayback(same,for:jobID))
        XCTAssertFalse(restored.claimReplyPlayback(same,for:jobID), "Auto-play is claimed only once")
        let restarted = NStackTransfers(root:root)
        let state = try XCTUnwrap(restarted.replyStates[conversation])
        XCTAssertEqual(state.lastPlayedID,same.id); XCTAssertNil(state.lastRespondedID)
        try restarted.deleteFinishedLocalArtifacts(ledger.jobs[0].recordingID)
        XCTAssertNil(NStackTransfers(root:root).replyStates[conversation], "Finished local cleanup removes reply round metadata")
    }

    func testResponseIsPendingOrSendingUntilSameThreadPostSucceeds() async throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        let queue = NStackTransfers(root:root), audio = root.appendingPathComponent("audio")
        try Data([1]).write(to:audio)
        try queue.enqueue(record(),route:DialogueRouteSnapshot(mode:.agent,destination:destination(),threadID:nil),audio:audio,corrected:"First")
        var ledger = NStackTransfers.Ledger(jobs:queue.jobs,intents:[],destination:nil)
        ledger.jobs[0].state = "sent"; ledger.jobs[0].messageID = "mine"; ledger.jobs[0].threadID = UUID().uuidString
        try JSONEncoder().encode(ledger).write(to:root.appendingPathComponent("ledger.json"))

        let prepared = NStackTransfers(root:root), parentID = ledger.jobs[0].id
        let conversation = try XCTUnwrap(ledger.jobs[0].conversationID)
        let reply = DialogueReply(id:"reply-to-answer",body:"Answer",sender:"Rick",createdAt:nil,audioObjectID:nil)
        XCTAssertTrue(prepared.storeReply(reply,for:conversation))
        var responseRoute = try XCTUnwrap(prepared.followupRoute(for:ledger.jobs[0]))
        responseRoute.respondingToReplyID = reply.id
        var response = record(); response.title = "Response"; response.dialogueRoute = responseRoute
        prepared.rememberNew(response)
        XCTAssertEqual(prepared.responseStatus(to:reply,for:parentID),.pending)
        XCTAssertNil(prepared.replyStates[conversation]?.lastRespondedID)

        try prepared.enqueue(response,route:responseRoute,audio:audio,corrected:"Follow up")
        XCTAssertEqual(prepared.responseStatus(to:reply,for:parentID),.pending)
        var deliveryLedger = NStackTransfers.Ledger(jobs:prepared.jobs,intents:prepared.intents,destination:nil,replyStates:prepared.replyStates)
        let responseIndex = try XCTUnwrap(deliveryLedger.jobs.firstIndex(where:{$0.recordingID == response.id}))
        deliveryLedger.jobs[responseIndex].state = "queued"
        for fileIndex in deliveryLedger.jobs[responseIndex].files.indices {
            deliveryLedger.jobs[responseIndex].files[fileIndex].objectID = UUID().uuidString
            deliveryLedger.jobs[responseIndex].files[fileIndex].complete = true
        }
        try JSONEncoder().encode(deliveryLedger).write(to:root.appendingPathComponent("ledger.json"))

        let delivery = NStackTransfers(root:root)
        MockNStackProtocol.handler = { _ in (500,["error":"not sent"]) }
        delivery.setAvailability(active:true,signer:npub,api:api())
        for _ in 0..<200 where delivery.jobs[responseIndex].state != "failed" { try await Task.sleep(for:.milliseconds(10)) }
        if case .failed = delivery.responseStatus(to:reply,for:parentID) {} else { XCTFail("A rejected post must remain visibly unsent") }
        XCTAssertNil(delivery.replyStates[conversation]?.lastRespondedID)

        let releasePost = DispatchSemaphore(value:0)
        MockNStackProtocol.handler = { request in
            XCTAssertTrue(request.url!.path.hasSuffix("/messages"))
            _ = releasePost.wait(timeout:.now() + 5)
            return (201,["message":["id":"accepted-follow-up","thread_id":ledger.jobs[0].threadID!]])
        }
        delivery.retry(delivery.jobs[responseIndex].id)
        for _ in 0..<200 where delivery.jobs[responseIndex].state != "posting" { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(delivery.responseStatus(to:reply,for:parentID),.sending)
        XCTAssertNil(delivery.replyStates[conversation]?.lastRespondedID,"Posting is not a successful response")
        releasePost.signal()
        for _ in 0..<200 where delivery.jobs[responseIndex].state != "sent" { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(delivery.responseStatus(to:reply,for:parentID),.sent)
        XCTAssertEqual(delivery.replyStates[conversation]?.lastRespondedID,reply.id)
        XCTAssertEqual(NStackTransfers(root:root).replyStates[conversation]?.lastRespondedID,reply.id,"Successful response state survives restart")
    }

    func testLegacyNormalSetupSeedsNewModesWithoutPersistingOrRetargeting() throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let normal = destination()
        let encoded = try JSONSerialization.jsonObject(with:JSONEncoder().encode(normal))
        let legacy:[String:Any] = ["jobs":[],"intents":[],"destination":encoded]
        try NostrCodec.json(legacy).write(to:root.appendingPathComponent("ledger.json"),options:.atomic)

        let restored = NStackTransfers(root:root)
        let channel = try XCTUnwrap(restored.setupSeed(for:.channel,signer:npub))
        XCTAssertEqual(channel.destination,normal); XCTAssertFalse(channel.saved)
        let agent = try XCTUnwrap(restored.setupSeed(for:.agent,signer:npub))
        XCTAssertEqual(agent.destination.workspace,normal.workspace); XCTAssertFalse(agent.saved)
        XCTAssertNil(restored.routing.channel); XCTAssertNil(restored.routing.agent)
        XCTAssertTrue(restored.replyStates.isEmpty)
        XCTAssertNil(restored.setupSeed(for:.channel,signer:NostrCodec.npub(Data(repeating:2,count:32))))

        var savedAgent = normal; savedAgent.prompt = "Existing agent route"
        try restored.saveRoute(savedAgent,mode:.agent)
        let existing = try XCTUnwrap(restored.setupSeed(for:.agent,signer:npub))
        XCTAssertTrue(existing.saved); XCTAssertEqual(existing.destination,savedAgent)
        XCTAssertEqual(NStackTransfers(root:root).routing.agent,savedAgent)
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

extension NStackTests {
    func testCanonicalAgentIdentityOverridesLegacyPresentationAndPermissionFlags() throws {
        let legacy = NostrCodec.npub(Data(repeating:2,count:32))
        let entries: [[String:Any]] = [
            ["agent_npub":npub,"display_name":"Rick","actor":["npub":legacy,"label":"Legacy"],"is_visible":true,"metadata":["can_instruct":true]],
            ["agent_npub":legacy,"display_name":"Hidden","is_visible":false],
            ["agent_npub":legacy,"display_name":"Denied","metadata":["can_instruct":false]],
            ["agent_npub":legacy,"display_name":"Archived","archived_at":"2026-01-01"],
            ["agent_npub":"invalid","display_name":"Never infer","actor":["npub":legacy]],
        ]
        let agents = try NStackDiscovery.agents(["workspace_agents":entries])
        XCTAssertEqual(agents.map(\.id),[npub]); XCTAssertEqual(agents.map(\.label),["Rick"])
        XCTAssertTrue(try NStackDiscovery.agents(["workspace_agents":[]]).isEmpty)
        XCTAssertThrowsError(try NStackDiscovery.agents(["error":"denied"]))
    }

    func testChannelTitlesAndDMParticipantNamesNeverBecomeRoutingAuthority() throws {
        let other = NostrCodec.npub(Data(repeating:2,count:32)); let id = UUID().uuidString
        let labels = NStackDiscovery.memberLabels([["actor":["npub":other,"display_name":"Colleague"]]])
        let scope: [String:Any] = ["name":"DMs"]
        let dm: [String:Any] = ["id":id,"name":"DM: " + other,"kind":"dm","participant_npubs":[npub,other]]
        XCTAssertEqual(try NStackDiscovery.channel(dm,scope:scope,signer:npub,labels:labels).label,"DMs / Colleague · DM")
        var intentional = dm; intentional["name"] = "DM: Audio review"
        XCTAssertEqual(try NStackDiscovery.channel(intentional,scope:scope,signer:npub,labels:labels).label,"DMs / DM: Audio review · DM")
        var named = dm; named["title"] = "Recording discussion"
        XCTAssertEqual(try NStackDiscovery.channel(named,scope:scope,signer:npub,labels:labels).label,"DMs / Recording discussion · DM")
        XCTAssertEqual(try NStackDiscovery.channel(["id":id,"title":"Actual title","name":"Fallback","kind":"channel"],scope:["title":"Actual scope"],signer:npub,labels:[:]).label,"Actual scope / Actual title")
        XCTAssertTrue(try NStackDiscovery.agents(["workspace_agents":[]]).isEmpty) // Human DM participants are labels, never agents.
    }

    func testFullDiscoveryAcrossScopesAndCursorPagesBeyondDefaultLimit() async throws {
        let workspace = NStackChoice(id:UUID().uuidString,label:"Workspace",app:npub)
        let scope = UUID().uuidString, dmScope = UUID().uuidString, dmID = UUID().uuidString
        let other = NostrCodec.npub(Data(repeating:2,count:32))
        let rows: [[String:Any]] = (0..<61).map { ["id":UUID().uuidString,"title":"Channel \($0)","kind":"channel"] }
        var channelRequests = 0
        MockNStackProtocol.handler = { request in
            let url = request.url!; let query = URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems ?? []
            if url.lastPathComponent != "sync" && url.lastPathComponent != "me" { XCTAssertEqual(query.first { $0.name == "limit" }?.value,"200") }
            switch url.path.components(separatedBy:"/").last! {
            case "sync", "me": return (404,[:])
            case "workspace-agents": return (200,["workspace_agents":[["agent_npub":other,"display_name":"Rick"]],"next_cursor":NSNull()])
            case "members": return (200,["members":[["actor":["npub":self.npub,"display_name":"Me"]]]])
            case "scopes": return (200,["scopes":[["id":scope,"name":"Home"],["id":dmScope,"name":"DMs"]]])
            case "channels":
                channelRequests += 1
                if url.path.contains(dmScope) { return (200,["channels":[["id":dmID,"name":"DM: " + other,"kind":"dm","participant_npubs":[self.npub,other]]]]) }
                if let cursor = query.first(where: { $0.name == "cursor" }) { XCTAssertEqual(cursor.value,"page+/= 2"); return (200,["channels":Array(rows.dropFirst(50))]) }
                return (200,["channels":Array(rows.prefix(50)),"next_cursor":"page+/= 2"])
            default: XCTFail("Unexpected discovery route"); return (404,[:])
            }
        }
        let result = try await api().discoverChannels(origin:"https://nstack.example",workspace:workspace,signer:npub)
        XCTAssertEqual(result.channels.count,62); XCTAssertEqual(channelRequests,3)
        XCTAssertEqual(result.channels.last?.label,"DMs / Rick · DM")
        XCTAssertEqual(result.agents.first?.id,other); XCTAssertNil(result.directoryError)
    }

    func testDirectoryFailureIsDistinctFromEmptyAndDoesNotHideChannels() async throws {
        let workspace = NStackChoice(id:UUID().uuidString,label:"Workspace",app:npub)
        let scope = UUID().uuidString
        for denied in [true,false] {
            MockNStackProtocol.handler = { request in
                switch request.url!.lastPathComponent {
                case "workspace-agents": return denied ? (403,["error":"denied"]) : (200,["workspace_agents":[]])
                case "members": return (403,[:])
                case "scopes": return (200,["scopes":[["id":scope,"name":"Home"]]])
                default: return (200,["channels":[["id":UUID().uuidString,"name":"General"]]])
                }
            }
            let result = try await api().discoverChannels(origin:"https://nstack.example",workspace:workspace,signer:npub)
            XCTAssertEqual(result.channels.count,1); XCTAssertTrue(result.agents.isEmpty)
            XCTAssertEqual(result.directoryError != nil,denied); XCTAssertNotNil(result.labelNotice)
        }
    }

    func testDiscoveryRejectsCursorLoopsAndUnpageableServerCap() async throws {
        MockNStackProtocol.handler = { _ in (200,["channels":[],"next_cursor":"repeated"]) }
        do { _ = try await api().list(origin:"https://nstack.example",path:"/api/v4/channels",key:"channels"); XCTFail("Cursor loop accepted") } catch { XCTAssertTrue(error is NStackError) }
        MockNStackProtocol.handler = { _ in (200,["channels":Array(repeating:["id":"fixture"],count:200),"next_cursor":NSNull()]) }
        do { _ = try await api().list(origin:"https://nstack.example",path:"/api/v4/channels",key:"channels"); XCTFail("Unproven full discovery accepted") } catch NStackError.discoveryLimit {} catch { XCTFail("Wrong error: \(error)") }
    }
}


extension NStackTests {
    func testSavedSetupRestoresExactSelectionsWithoutRetargeting() {
        let saved = destination()
        let selections = NStackDiscovery.savedSelections(saved)
        XCTAssertEqual(selections.workspace.id,saved.workspace)
        XCTAssertEqual(selections.workspace.label,saved.workspaceLabel)
        XCTAssertEqual(selections.workspace.app,saved.appNpub)
        XCTAssertEqual(selections.channel.id,saved.channel)
        XCTAssertEqual(selections.channel.label,saved.channelLabel)
    }
}

extension NStackTests {
    func testSyncMetadataDiscoversBeyondScopeListCapWithoutPagingMessageHistory() async throws {
        let scope = UUID().uuidString
        let rows: [[String:Any]] = (0..<251).map { ["id":UUID().uuidString,"scope_id":scope,"name":"Channel \($0)"] }
        var syncRequests = 0
        MockNStackProtocol.handler = { request in
            switch request.url!.lastPathComponent {
            case "workspace-agents": return (200,["workspace_agents":[]])
            case "members": return (200,["members":[]])
            case "sync":
                syncRequests += 1
                XCTAssertEqual(request.url!.query,"limit=1")
                return (200,["full_snapshot":true,"snapshot_complete":false,"has_more":true,"next_cursor":"message-bundle-page","scopes":[["id":scope,"name":"Home"]],"channels":rows])
            default: XCTFail("Scope list or unrelated message pagination requested"); return (404,[:])
            }
        }
        let result = try await api().discoverChannels(origin:"https://nstack.example",workspace:NStackChoice(id:UUID().uuidString,label:"Workspace",app:npub),signer:npub)
        XCTAssertEqual(result.channels.count,251); XCTAssertEqual(syncRequests,1)
        XCTAssertNil(result.channelError); XCTAssertNil(result.labelNotice)
    }

    func testDirectlyGrantedChannelsIncludedInFallbackAndAgentsSurviveChannelFailure() async throws {
        let scope = UUID().uuidString, directScope = UUID().uuidString, directID = UUID().uuidString
        for failChannels in [false,true] {
            MockNStackProtocol.handler = { request in
                switch request.url!.lastPathComponent {
                case "workspace-agents": return (200,["workspace_agents":[["agent_npub":self.npub,"display_name":"Rick"]]])
                case "members": return (200,["members":[]])
                case "sync": return (404,[:])
                case "scopes": return (200,["scopes":[["id":scope,"name":"Home"]]])
                case "me": return (200,["visible":["scopes":[["id":directScope,"name":"DMs"]],"channels":[["id":directID,"scope_id":directScope,"name":"Intentional DM name","kind":"dm"]]]])
                default: return failChannels ? (403,[:]) : (200,["channels":[]])
                }
            }
            let result = try await api().discoverChannels(origin:"https://nstack.example",workspace:NStackChoice(id:UUID().uuidString,label:"Workspace",app:npub),signer:npub)
            XCTAssertEqual(result.agents.first?.label,"Rick"); XCTAssertNil(result.directoryError)
            XCTAssertEqual(result.channelError != nil,failChannels)
            if !failChannels { XCTAssertEqual(result.channels.first?.id,directID); XCTAssertEqual(result.channels.first?.label,"DMs / Intentional DM name · DM"); XCTAssertNotNil(result.labelNotice) }
        }
    }
}

import XCTest
@testable import PeteRecorder

final class V11PersistenceTests: XCTestCase {
    func testV1ManifestMigrationPreservesFilesAndTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        var r = Recording(title: "Existing v1"); r.state = .saved; r.transcript = "Nosta, 123."
        r.segments = ["original.m4a"]; try store.save(r)
        let manifest = store.directory(r.id).appendingPathComponent("metadata.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
        for key in ["correctedTranscript", "cleanupDraft", "transcriptionState", "transcriptionNotice", "deliveryContent"] { json.removeValue(forKey: key) }
        json["schemaVersion"] = 1
        try JSONSerialization.data(withJSONObject: json).write(to: manifest)
        let bytes = Data([1,2,3,4]); try bytes.write(to: store.audio(r, "original.m4a"))
        var restored = try XCTUnwrap(store.recover().first)
        XCTAssertEqual(restored.id, r.id); XCTAssertEqual(restored.transcript, r.transcript)
        XCTAssertEqual(restored.transcriptionState, .complete); XCTAssertNil(restored.correctedTranscript)
        XCTAssertEqual(restored.deliveryContent, .transcriptAndAudio)
        restored.correctedTranscript = "Nostr, 123."; restored.cleanupDraft = "Nostr, 123!"
        try store.save(restored)
        XCTAssertEqual(try store.load().first, restored)
        XCTAssertEqual(try Data(contentsOf: store.audio(r, "original.m4a")), bytes)
    }
    func testRunningQueueRecoversWithoutWipingDraftOrVocabulary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        var r = Recording(title: "Recover"); r.state = .saved; r.transcriptionState = .running
        r.transcript = "Original"; r.correctedTranscript = "Edited"; r.cleanupDraft = "Draft"
        try store.save(r)
        let vocabulary = VocabularyStore(url: root.appendingPathComponent("vocabulary.json"))
        let rules = [VocabularyCorrection(heard: "nosta", replacement: "nostr")]
        try vocabulary.save(rules)
        let recovered = try XCTUnwrap(store.recover().first)
        XCTAssertEqual(recovered.transcriptionState, .queued)
        XCTAssertEqual(recovered.transcript, "Original"); XCTAssertEqual(recovered.correctedTranscript, "Edited"); XCTAssertEqual(recovered.cleanupDraft, "Draft")
        XCTAssertEqual(try vocabulary.load(), rules)
        XCTAssertTrue(store.warnings.isEmpty)
        XCTAssertEqual(try store.recover().first, recovered)
    }
    func testCorrectionsBoundariesPunctuationCaseAndNonCascade() {
        let rules = [VocabularyCorrection(heard: "nosta", replacement: "nostr"), VocabularyCorrection(heard: "wing man", replacement: "Wingman")]
        XCTAssertEqual(TranscriptCorrections.apply("Nosta, NOSTA! nosta; nostagram, xnosta, nosta2, nosta_name. wing man?", vocabulary: rules),
                       "Nostr, NOSTR! nostr; nostagram, xnosta, nosta2, nosta_name. Wingman?")
        let cascade = [VocabularyCorrection(heard: "a", replacement: "b"), VocabularyCorrection(heard: "b", replacement: "c")]
        XCTAssertEqual(TranscriptCorrections.apply("a b", vocabulary: cascade), "b c")
        let longest = [VocabularyCorrection(heard: "new", replacement: "old"), VocabularyCorrection(heard: "new york", replacement: "Perth")]
        XCTAssertEqual(TranscriptCorrections.apply("new york, new", vocabulary: longest), "Perth, old")
        XCTAssertEqual(TranscriptCorrections.apply("Nosta", vocabulary: []), "Nosta")
    }
    func testExactWordOccurrenceAndChunkRetention() {
        let text = "nosta, nosta! café 🐦 nosta."
        let words = TranscriptCorrections.words(text)
        XCTAssertEqual(TranscriptCorrections.replacingWord(in: text, range: words[1], with: "nostr"), "nosta, nostr! café 🐦 nosta.")
        let long = String(repeating: "名字 123. nosta! ", count: 2000)
        let chunks = LocalCleanup.chunks(long)
        XCTAssertEqual(chunks.joined(), long); XCTAssertTrue(chunks.allSatisfy { $0.utf8.count <= 1200 })
        XCTAssertTrue(chunks.count > 1)
    }
    @MainActor
    func testEditDraftAcceptRejectRetainsRawAndVocabularyManagement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = RecorderModel(root: root); model.background()
        var r = Recording(title: "Review"); r.state = .saved; r.transcript = "nosta, 123."
        try model.store!.save(r); model.recordings = [r]
        let rule = VocabularyCorrection(heard: "nosta", replacement: "nostr")
        model.saveVocabulary([rule]); model.applyVocabulary(r.id)
        XCTAssertEqual(model.recordings[0].reviewText, "nostr, 123.")
        var edited = model.recordings[0]; edited.cleanupDraft = "Draft 123."; model.replace(edited)
        model.reviewDraft(r.id, accept: false)
        XCTAssertEqual(model.recordings[0].reviewText, "nostr, 123."); XCTAssertNil(model.recordings[0].cleanupDraft)
        edited = model.recordings[0]; edited.cleanupDraft = "Accepted 123."; model.replace(edited)
        model.reviewDraft(r.id, accept: true)
        XCTAssertEqual(model.recordings[0].reviewText, "Accepted 123.")
        XCTAssertEqual(try model.store!.load()[0].transcript, "nosta, 123.")
        var newRule = rule; newRule.replacement = "Nostr protocol"; model.saveVocabulary([newRule])
        XCTAssertEqual(try VocabularyStore(url: root.appendingPathComponent("vocabulary.json")).load(), [newRule])
        model.saveVocabulary([]); XCTAssertTrue(model.vocabulary.isEmpty)
    }
}

private final class MemorySecrets: VaultSecretStore {
    var value: Data?
    func read() throws -> Data? { value }
    func write(_ data: Data) throws { value = data }
}
final class IdentityVaultTests: XCTestCase {
    // Bech32 encoding is confined to test fixtures. Scalar 1 is public synthetic test data.
    private func nsec(_ bytes: [UInt8]) -> String {
        let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
        var acc: UInt32 = 0; var bits = 0; var data: [UInt32] = []
        for b in bytes { acc = ((acc << 8) | UInt32(b)) & 0xffff; bits += 8; while bits >= 5 { bits -= 5; data.append((acc >> bits) & 31) } }
        if bits > 0 { data.append((acc << (5 - bits)) & 31) }
        let hrp = Array("nsec".utf8)
        let values = hrp.map { UInt32($0 >> 5) } + [0] + hrp.map { UInt32($0 & 31) } + data + [UInt32](repeating: 0, count: 6)
        let generators: [UInt32] = [0x3b6a57b2,0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3]
        var chk: UInt32 = 1
        for v in values { let top = chk >> 25; chk = ((chk & 0x1ffffff) << 5) ^ v; for i in 0..<5 where (top >> i) & 1 != 0 { chk ^= generators[i] } }
        chk ^= 1
        let checksum = (0..<6).map { (chk >> (5 * (5 - $0))) & 31 }
        return "nsec1" + (data + checksum).map { String(alphabet[Int($0)]) }.joined()
    }
    func testSyntheticValidationRejectsChecksumMixedCaseZeroAndOutOfRange() throws {
        let scalar = [UInt8](repeating: 0, count: 31) + [1]
        let value = nsec(scalar)
        XCTAssertEqual(try NsecValidation.decode(value), Data(scalar))
        XCTAssertEqual(try NsecValidation.decode(value.uppercased()), Data(scalar))
        XCTAssertThrowsError(try NsecValidation.decode(value.dropLast() + "q"))
        XCTAssertThrowsError(try NsecValidation.decode("N" + value.dropFirst()))
        XCTAssertThrowsError(try NsecValidation.decode(nsec([UInt8](repeating: 0, count: 32))))
        XCTAssertThrowsError(try NsecValidation.decode(nsec([UInt8](repeating: 255, count: 32))))
        XCTAssertThrowsError(try NsecValidation.decode("npub" + value.dropFirst(4)))
    }
    func testEncryptionUnlockWrongPINTamperAndExplicitRemove() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = MemorySecrets(); let url = root.appendingPathComponent("vault.json")
        let vault = IdentityVault(url: url, secrets: secrets)
        let value = nsec([UInt8](repeating: 0, count: 31) + [1])
        XCTAssertThrowsError(try vault.create(nsec: value, pin: "abc")); XCTAssertNil(secrets.value)
        try vault.create(nsec: value, pin: "123456"); XCTAssertTrue(vault.isUnlocked)
        let original = try Data(contentsOf: url)
        XCTAssertFalse(String(decoding: original, as: UTF8.self).contains(value))
        XCTAssertFalse(String(decoding: original, as: UTF8.self).contains("123456"))
        XCTAssertEqual(secrets.value?.count, 32)
        let envelope = try JSONDecoder().decode(IdentityVault.Envelope.self, from: original)
        XCTAssertEqual(envelope.iterations, 210000); XCTAssertEqual(envelope.salt.count, 16)
        vault.lock(); XCTAssertFalse(vault.isUnlocked)
        XCTAssertThrowsError(try vault.unlock(pin: "999999")); XCTAssertFalse(vault.isUnlocked)
        XCTAssertEqual(try Data(contentsOf: url), original)
        try vault.unlock(pin: "123456"); XCTAssertTrue(vault.isUnlocked)
        XCTAssertThrowsError(try vault.create(nsec: value, pin: "654321")); XCTAssertEqual(try Data(contentsOf: url), original)
        var tampered = envelope; tampered.sealed[tampered.sealed.count - 1] ^= 1
        try JSONEncoder().encode(tampered).write(to: url)
        XCTAssertThrowsError(try vault.unlock(pin: "123456")); XCTAssertFalse(vault.isUnlocked); XCTAssertTrue(vault.exists)
        try original.write(to: url)
        let fresh = IdentityVault(url: url, secrets: secrets); try fresh.unlock(pin: "123456"); XCTAssertTrue(fresh.isUnlocked)
        let recording = root.appendingPathComponent("audio.m4a"); try Data([1,2]).write(to: recording)
        try fresh.remove(); XCTAssertFalse(fresh.exists); XCTAssertTrue(FileManager.default.fileExists(atPath: recording.path))
        try fresh.create(nsec: value, pin: "123456")
        let second = try JSONDecoder().decode(IdentityVault.Envelope.self, from: Data(contentsOf: url))
        XCTAssertNotEqual(second.salt, envelope.salt); XCTAssertNotEqual(second.sealed, envelope.sealed)
        secrets.value = nil; XCTAssertThrowsError(try fresh.unlock(pin: "123456")); XCTAssertTrue(fresh.exists)
    }
}

@MainActor
final class TranscriptionQueueTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func export(_ r: Recording) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try Data([0]).write(to: url); return url
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("Queue did not reach expected state")
    }
    func testMicrophonePreferenceAvailabilityIsExplicit() {
        XCTAssertEqual(RecorderModel.preferenceLabel(name: "USB mic", available: false), "USB mic unavailable · recording blocked")
        XCTAssertEqual(RecorderModel.preferenceLabel(name: "USB mic", available: nil), "USB mic · preference (availability unchecked)")
        XCTAssertEqual(RecorderModel.preferenceLabel(name: "USB mic", available: true), "USB mic · preference")
        XCTAssertEqual(RecorderModel.preferenceLabel(name: "System default", available: nil), "System default")
    }
    func testStopAutomaticallyQueuesInstalledOnlyAndRetainsAudioOnFailureThenRetry() async throws {
        var downloads: [Bool] = []
        let model = RecorderModel(root: root, speech: { _, download in
            downloads.append(download)
            if !download { throw RecorderError.modelRequired }
            return LocalTranscript(text: "nosta, 42.", locale: "en-AU")
        }, audioExport: export)
        model.saveVocabulary([VocabularyCorrection(heard: "nosta", replacement: "nostr")])
        var r = Recording(title: "Save"); r.segments = ["existing.m4a"]; try model.store!.save(r)
        let audio = model.store!.audio(r, "existing.m4a"); try Data([1,2,3]).write(to: audio)
        model.active = r; model.stop()
        XCTAssertEqual(model.recordings[0].transcriptionState, .queued)
        try await wait { model.recordings[0].transcriptionState == .failed && !model.transcribing }
        XCTAssertEqual(downloads, [false]); XCTAssertTrue(model.recordings[0].transcriptionNotice!.contains("not installed"))
        XCTAssertEqual(try Data(contentsOf: audio), Data([1,2,3]))
        model.startTranscription(model.recordings[0], download: true)
        try await wait { model.recordings[0].transcriptionState == .complete }
        XCTAssertEqual(downloads, [false, true]); XCTAssertEqual(model.recordings[0].transcript, "nosta, 42.")
        XCTAssertEqual(model.recordings[0].reviewText, "nostr, 42.")
    }
    func testCaptureDefersAndForegroundRecoversWithoutBusyLockOrStaleEdits() async throws {
        var calls = 0
        let model = RecorderModel(root: root, speech: { _, _ in
            calls += 1
            if calls == 1 { try await Task.sleep(nanoseconds: 60_000_000_000) }
            else { try await Task.sleep(nanoseconds: 100_000_000) }
            return LocalTranscript(text: "raw", locale: "en")
        }, audioExport: export)
        var r = Recording(title: "Queued"); r.state = .saved; r.transcriptionState = .queued
        try model.store!.save(r); model.recordings = [r]; model.resumeTranscriptionQueue()
        try await wait { calls == 1 }
        XCTAssertFalse(model.busy)
        model.active = Recording(title: "New capture"); model.prioritizeCapture()
        try await wait { !model.transcribing }
        XCTAssertEqual(model.recordings[0].transcriptionState, .queued); XCTAssertEqual(calls, 1)
        model.background(); model.active = nil; model.foreground()
        try await wait { calls == 2 }
        model.rename(r, title: "Changed concurrently")
        model.editTranscript(r.id, text: "user edit")
        try await wait { model.recordings[0].transcriptionState == .complete }
        XCTAssertEqual(model.recordings[0].title, "Changed concurrently"); XCTAssertEqual(model.recordings[0].reviewText, "user edit")
        XCTAssertEqual(model.recordings[0].transcript, "raw")
    }
    func testExplicitCancellationDoesNotAutoRetryAndDeleteDoesNotResurrect() async throws {
        var calls = 0
        let model = RecorderModel(root: root, speech: { _, _ in calls += 1; try await Task.sleep(nanoseconds: 60_000_000_000); return LocalTranscript(text: "stale", locale: "en") }, audioExport: export)
        var r = Recording(title: "Cancel"); r.state = .saved; r.transcriptionState = .queued
        try model.store!.save(r); model.recordings = [r]; model.resumeTranscriptionQueue()
        try await wait { calls == 1 }; model.cancelTranscription()
        try await wait { !model.transcribing }
        XCTAssertEqual(model.recordings[0].transcriptionState, .cancelled)
        model.foreground(); XCTAssertEqual(calls, 1)
        model.startTranscription(r, download: false); try await wait { calls == 2 }
        model.delete(r); try await wait { !model.transcribing }
        XCTAssertTrue(model.recordings.isEmpty); XCTAssertTrue(try model.store!.load().isEmpty)
    }
    func testLaunchResumesPersistedRunningQueueInstalledOnly() async throws {
        let store = try RecordingStore(root: root)
        var r = Recording(title: "Relaunch"); r.state = .saved; r.transcriptionState = .running
        try store.save(r)
        var downloads: [Bool] = []
        let model = RecorderModel(root: root, speech: { _, download in downloads.append(download); return LocalTranscript(text: "Recovered", locale: "en") }, audioExport: export)
        try await wait { model.recordings[0].transcriptionState == .complete }
        XCTAssertEqual(downloads, [false]); XCTAssertEqual(model.recordings[0].id, r.id)
        XCTAssertEqual(try store.load()[0].transcript, "Recovered")
    }
}

extension IdentityVaultTests {
    func testNostrSigningInsideSyntheticVaultAndLockedRefusal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let vault = IdentityVault(url:root.appendingPathComponent("vault.json"),secrets:MemorySecrets())
        try vault.create(nsec:nsec([UInt8](repeating:0,count:31) + [1]),pin:"123456")
        let event = try vault.sign(kind:1,tags:[["t","é / 😀"]],content:"Synthetic Nostr verification",createdAt:1700000000)
        XCTAssertEqual(event.pubkey,"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")
        XCTAssertEqual(event.id,NostrCodec.hash(try NostrCodec.json([0,event.pubkey,event.created_at,event.kind,event.tags,event.content])))
        XCTAssertTrue(NostrCodec.validNpub(try vault.signerNpub()))
        let attachment = XCTAttachment(data:try JSONEncoder().encode(event),uniformTypeIdentifier:"public.json")
        attachment.name = "Synthetic scalar-one Nostr event"; attachment.lifetime = .keepAlways; add(attachment)
        // Public synthetic event only; allows independent nostr-tools verification after the suite.
        try JSONEncoder().encode(event).write(to:FileManager.default.temporaryDirectory.appendingPathComponent("recorder-synthetic-event.json"))
        vault.lock(); XCTAssertThrowsError(try vault.signerNpub()); XCTAssertThrowsError(try vault.sign(kind:1,tags:[],content:""))
    }
}


extension IdentityVaultTests {
    @MainActor func testInjectedIdentityModelReopensExistingVaultWithoutMigrationOrUnauthenticatedUnlock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let secrets = MemorySecrets(); let url = root.appendingPathComponent("vault.json")
        let original = IdentityVault(url:url,secrets:secrets)
        try original.create(nsec:nsec([UInt8](repeating:0,count:31) + [1]),pin:"123456")
        original.lock()
        let bytes = try Data(contentsOf:url)
        let model = IdentityModel(vault:IdentityVault(url:url,secrets:secrets))
        XCTAssertTrue(model.exists); XCTAssertFalse(model.unlocked); XCTAssertNil(model.npub)
        model.perform { try $0.unlock(pin:"999999") }
        XCTAssertFalse(model.unlocked); XCTAssertNil(model.npub); XCTAssertNotNil(model.notice)
        model.perform { try $0.unlock(pin:"123456") }
        XCTAssertTrue(model.unlocked); XCTAssertNotNil(model.npub); XCTAssertNil(model.notice)
        model.lock(); XCTAssertFalse(model.unlocked); XCTAssertNil(model.npub)
        XCTAssertEqual(try Data(contentsOf:url),bytes)
    }
}

import XCTest
import AVFoundation
@testable import PeteRecorder

@MainActor
final class ReplyVoiceTests: XCTestCase {
    func testPersistenceDefaultRemovalAndUnavailableRecovery() throws {
        let suite = "ReplyVoiceTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let installed = try XCTUnwrap(AVSpeechSynthesisVoice.speechVoices().first)
        var catalog = [installed]
        let voice = ReplyVoice(defaults: defaults, available: { catalog })
        XCTAssertEqual(voice.selectedID, "")
        voice.select(installed.identifier)
        let restored = ReplyVoice(defaults: defaults, available: { catalog })
        XCTAssertEqual(restored.selectedID, installed.identifier)
        XCTAssertEqual(restored.utterance("Reply").voice?.identifier, installed.identifier)
        catalog = []
        let fallback = restored.utterance("Still readable")
        XCTAssertTrue(restored.unavailable)
        XCTAssertEqual(fallback.voice?.identifier, AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier)?.identifier)
        XCTAssertEqual(restored.selectedID, installed.identifier, "A temporary absence must not erase the preference")
        catalog = [installed]
        XCTAssertEqual(restored.utterance("Available again").voice?.identifier, installed.identifier)
        XCTAssertFalse(restored.unavailable)
        restored.select("")
        XCTAssertNil(defaults.object(forKey: ReplyVoice.key))
        XCTAssertEqual(ReplyVoice(defaults: defaults).selectedID, "")
        XCTAssertTrue(ReplyVoice.label(installed).contains(installed.name))
        XCTAssertTrue(ReplyVoice.label(installed).contains(installed.language))
    }

    func testTextPlaybackUsesSavedVoiceAndFallbackWithoutChangingLedger() throws {
        let suite = "ReplyVoiceTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let installed = try XCTUnwrap(AVSpeechSynthesisVoice.speechVoices().last)
        var spoken: [AVSpeechUtterance] = []
        let transfers = NStackTransfers(root: root, defaults: defaults, speakReply: { spoken.append($0) })
        let ledger = root.appendingPathComponent("ledger.json")
        let before = try? Data(contentsOf: ledger)
        transfers.replyVoice.select(installed.identifier)
        let reply = DialogueReply(id: "synthetic-reply", body: "A text answer", sender: "Test", createdAt: nil, audioObjectID: nil)
        transfers.toggleReplyPlayback(reply, for: UUID())
        XCTAssertEqual(spoken.count, 1)
        XCTAssertEqual(spoken.last?.speechString, reply.body)
        XCTAssertEqual(spoken.last?.voice?.identifier, installed.identifier)
        XCTAssertEqual(transfers.playingReplyID, reply.id)
        transfers.stopReply()
        XCTAssertNil(transfers.playingReplyID)
        transfers.replyVoice.select("removed.voice.identifier")
        transfers.toggleReplyPlayback(reply, for: UUID())
        XCTAssertEqual(spoken.count, 2)
        XCTAssertTrue(transfers.replyVoice.unavailable)
        XCTAssertEqual(spoken.last?.voice?.identifier, AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier)?.identifier)
        XCTAssertEqual(try? Data(contentsOf: ledger), before)
        transfers.stopReply()
        let restored = NStackTransfers(root: root, defaults: defaults)
        XCTAssertEqual(restored.replyVoice.selectedID, "removed.voice.identifier")
        XCTAssertTrue(restored.jobs.isEmpty)
    }
}

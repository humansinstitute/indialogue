import AVFoundation
import SwiftUI

/// Device-local preference, independent of the transfer ledger and identity.
@MainActor
final class ReplyVoice: ObservableObject {
    static let key = "replySpeechVoiceIdentifier.v1"
    @Published private(set) var selectedID: String
    @Published private(set) var voices: [AVSpeechSynthesisVoice] = []
    private let defaults: UserDefaults
    private let available: () -> [AVSpeechSynthesisVoice]

    init(defaults: UserDefaults = .standard,
         available: @escaping () -> [AVSpeechSynthesisVoice] = { AVSpeechSynthesisVoice.speechVoices() }) {
        self.defaults = defaults
        self.available = available
        selectedID = defaults.string(forKey: Self.key) ?? ""
        refresh()
    }
    func refresh() {
        voices = available().sorted {
            ($0.language, $0.name, $0.identifier) < ($1.language, $1.name, $1.identifier)
        }
    }
    var unavailable: Bool { !selectedID.isEmpty && !voices.contains { $0.identifier == selectedID } }
    func select(_ identifier: String) {
        selectedID = identifier
        if identifier.isEmpty { defaults.removeObject(forKey: Self.key) }
        else { defaults.set(identifier, forKey: Self.key) }
    }
    func utterance(_ text: String) -> AVSpeechUtterance {
        // Re-enumerate at playback: a downloaded voice may have been removed in Settings.
        refresh()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voices.first { $0.identifier == selectedID }
            ?? AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier)
        return utterance
    }
    static func label(_ voice: AVSpeechSynthesisVoice) -> String {
        let language = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
        return "\(voice.name) · \(language) (\(voice.language))"
    }
}

struct ReplyVoiceSettings: View {
    @ObservedObject var voice: ReplyVoice
    @ObservedObject var model: RecorderModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var preview = AVSpeechSynthesizer()
    var body: some View {
        Form {
            Section("Text reply voice") {
                Picker("Voice", selection: Binding(get: { voice.selectedID }, set: { preview.stopSpeaking(at: .immediate); voice.select($0) })) {
                    Text("System Default").tag("")
                    if voice.unavailable { Text("Saved voice unavailable").tag(voice.selectedID) }
                    ForEach(voice.voices, id: \.identifier) { item in Text(ReplyVoice.label(item)).tag(item.identifier) }
                }.accessibilityIdentifier("replyVoicePicker")
                if voice.unavailable {
                    Text("Your saved voice is unavailable. Text replies use System Default until it is available again or you choose another voice.")
                }
                Button("Preview voice") {
                    model.transfers.stopReply()
                    preview.stopSpeaking(at: .immediate)
                    preview.speak(voice.utterance("Hello Pete. This is the voice for text replies in In Dialogue."))
                }.disabled(model.active != nil || model.busy || model.playing != nil)
                    .accessibilityIdentifier("previewReplyVoice")
                Button("Stop preview") { preview.stopSpeaking(at: .immediate) }
                Text("Saved automatically on this iPhone. Only voices available to iOS speech are listed. Manage downloaded voices in the iPhone’s accessibility speech settings, then return here. Attached reply audio plays in preference to this voice.").font(.footnote)
            }
        }.navigationTitle("Reply voice")
            .onAppear { voice.refresh() }
            .onDisappear { preview.stopSpeaking(at: .immediate) }
            .onChange(of: scenePhase) { _, phase in
                preview.stopSpeaking(at: .immediate)
                if phase == .active { voice.refresh() }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in voice.refresh() }
    }
}

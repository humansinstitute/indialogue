import SwiftUI

struct IdentitySettings: View {
    @ObservedObject var model: IdentityModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var nsec = ""
    @State private var pin = ""
    @State private var confirmPIN = ""
    @State private var remove = false
    @State private var mismatch = false
    private func clear() { nsec = ""; pin = ""; confirmPIN = "" }
    var body: some View {
        Form {
            Section("Identity") {
                Text(model.exists ? (model.unlocked ? "Imported identity · unlocked" : "Imported identity · locked") : "No imported identity")
                Text("Stored locally using your PIN and this app’s Keychain secret. No connection or upload. Keep your own backup of the nsec.").font(.footnote)
                if model.exists {
                    if model.unlocked { Button("Lock") { model.lock(); clear() } }
                    else {
                        SecureField("PIN", text: $pin).keyboardType(.numberPad)
                        Button("Unlock") { model.perform { try $0.unlock(pin: pin) }; clear() }
                    }
                    Button("Remove identity…", role: .destructive) { remove = true }
                } else {
                    SecureField("Paste nsec", text: $nsec).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Create PIN (4–12 digits)", text: $pin).keyboardType(.numberPad)
                    SecureField("Confirm PIN", text: $confirmPIN).keyboardType(.numberPad)
                    Button("Import identity") {
                        guard pin == confirmPIN else { mismatch = true; clear(); return }
                        model.perform { try $0.create(nsec: nsec, pin: pin) }; clear()
                    }
                }
            }
            if let notice = model.notice { Text(notice) }
        }.navigationTitle("Identity")
            .confirmationDialog("Remove imported identity? Keep a backup before removing. Recordings will be retained. Importing a replacement requires this explicit removal.", isPresented: $remove, titleVisibility: .visible) {
                Button("Remove identity", role: .destructive) { model.perform { try $0.remove() }; clear() }
            }
            .alert("PINs do not match", isPresented: $mismatch) { Button("OK", role: .cancel) {} }
            .onChange(of: scenePhase) { _, phase in if phase != .active { clear() } }
            .onDisappear { clear() }
    }
}

struct VocabularySettings: View {
    @ObservedObject var model: RecorderModel
    @State private var editing: VocabularyCorrection?
    @State private var heard = ""
    @State private var replacement = ""
    @State private var editor = false
    var body: some View {
        List {
            Section {
                Text("Teach names and common misses. Corrections match whole words or phrases, preserve surrounding punctuation, and follow the original capitalization.").font(.footnote)
                Button("Add correction") { editing = nil; heard = ""; replacement = ""; editor = true }
                if model.vocabulary.isEmpty { Text("Example: nosta → nostr. Add it only if useful to you.").font(.footnote) }
            }
            ForEach(model.vocabulary) { rule in
                Button("\(rule.heard) → \(rule.replacement)") { editing = rule; heard = rule.heard; replacement = rule.replacement; editor = true }
            }.onDelete { indices in var rules = model.vocabulary; rules.remove(atOffsets: indices); model.saveVocabulary(rules) }
        }.navigationTitle("Vocabulary")
            .alert(editing == nil ? "Add correction" : "Edit correction", isPresented: $editor) {
                TextField("Heard word or phrase", text: $heard)
                TextField("Replacement", text: $replacement)
                Button("Save") {
                    let source = heard.trimmingCharacters(in: .whitespacesAndNewlines)
                    let target = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !source.isEmpty, !target.isEmpty else { return }
                    var rules = model.vocabulary
                    let rule = VocabularyCorrection(id: editing?.id ?? UUID(), heard: source, replacement: target)
                    if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule } else { rules.append(rule) }
                    model.saveVocabulary(rules)
                }
                if let editing { Button("Remove", role: .destructive) { model.saveVocabulary(model.vocabulary.filter { $0.id != editing.id }) } }
                Button("Cancel", role: .cancel) {}
            }
    }
}

struct TranscriptReview: View {
    @ObservedObject var model: RecorderModel
    let recordingID: UUID
    @State private var wordRange: NSRange?
    @State private var sourceText = ""
    @State private var heard = ""
    @State private var replacement = ""
    @State private var reusable = false
    @State private var editText = ""
    @State private var editing = false
    private var r: Recording? { model.recordings.first { $0.id == recordingID } }
    var body: some View {
        if let r {
            VStack(alignment: .leading, spacing: 12) {
                Text("Transcript review").font(.headline)
                if r.reviewText.isEmpty { Text("No speech detected.") }
                else {
                    Text("Tap a word to correct it.").font(.caption)
                    WordReview(text: r.reviewText) { range in
                        sourceText = r.reviewText; wordRange = range
                        heard = (r.reviewText as NSString).substring(with: range); replacement = heard; reusable = false
                    }.frame(minHeight: 140, maxHeight: 260)
                }
                Button("Edit transcript") { editText = r.reviewText; editing = true }
                Button("Apply saved vocabulary") { model.applyVocabulary(recordingID) }
                DisclosureGroup("Original transcript") { Text(r.transcript ?? "").textSelection(.enabled) }
                Text(LocalCleanup.status()).font(.footnote)
                Button("Clean up on device") { model.cleanUp(recordingID) }.disabled(model.cleaning || model.active != nil || r.reviewText.isEmpty)
                if model.cleaning { ProgressView(); Button("Cancel cleanup") { model.cancelCleanup() } }
                if let status = model.cleanupStatus { Text(status).font(.footnote) }
                if let draft = r.cleanupDraft {
                    Text("Draft — review carefully").font(.headline)
                    Text(draft).textSelection(.enabled)
                    Button("Accept draft") { model.reviewDraft(recordingID, accept: true) }
                    Button("Reject draft", role: .destructive) { model.reviewDraft(recordingID, accept: false) }
                }
            }.buttonStyle(.borderless)
            .sheet(isPresented: Binding(get: { wordRange != nil }, set: { if !$0 { wordRange = nil } })) {
                NavigationStack {
                    Form {
                        Text("Replace: \(heard)")
                        TextField("Replacement", text: $replacement).autocorrectionDisabled()
                        Toggle("Save reusable correction", isOn: $reusable)
                        Button("Apply") {
                            guard let range = wordRange, let latest = self.r, latest.reviewText == sourceText, !replacement.isEmpty else { wordRange = nil; return }
                            model.editTranscript(recordingID, text: TranscriptCorrections.replacingWord(in: sourceText, range: range, with: replacement))
                            if reusable {
                                var rules = model.vocabulary
                                if let index = rules.firstIndex(where: { $0.heard.lowercased() == heard.lowercased() }) { rules[index].replacement = replacement }
                                else { rules.append(VocabularyCorrection(heard: heard, replacement: replacement)) }
                                model.saveVocabulary(rules)
                            }
                            wordRange = nil
                        }
                    }.navigationTitle("Correct word").toolbar { Button("Cancel") { wordRange = nil } }
                }
            }
            .sheet(isPresented: $editing) {
                NavigationStack {
                    TextEditor(text: $editText).padding().navigationTitle("Edit transcript")
                        .toolbar {
                            Button("Cancel") { editing = false }
                            Button("Save") { model.editTranscript(recordingID, text: editText); editing = false }
                        }
                }
            }
        }
    }
}

/// Native, selectable text with exact occurrence links; punctuation and whitespace stay intact.
struct WordReview: UIViewRepresentable {
    let text: String
    var tapped: (NSRange) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true; view.backgroundColor = .clear
        view.adjustsFontForContentSizeCategory = true; view.delegate = context.coordinator
        view.accessibilityLabel = "Transcript. Tap a linked word to correct it."
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        let attributed = NSMutableAttributedString(string: text, attributes: [.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label])
        for range in TranscriptCorrections.words(text) {
            let url = URL(string: "recorder-word://\(range.location)/\(range.length)")!
            attributed.addAttribute(.link, value: url, range: range)
        }
        view.attributedText = attributed
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: WordReview
        init(_ parent: WordReview) { self.parent = parent }
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            let range = textItem.range
            return UIAction { [weak self] _ in self?.parent.tapped(range) }
        }
    }
}

/// Once dismissed, remain quiet until a real background/foreground cycle.
struct ForegroundUnlockPolicy {
    private(set) var requested = false
    mutating func background() { requested = false }
    mutating func request(active: Bool, exists: Bool, unlocked: Bool) -> Bool {
        guard active, exists, !unlocked, !requested else { return false }
        requested = true
        return true
    }
}

struct IdentityUnlock: View {
    @ObservedObject var model: IdentityModel
    let done: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var pin = ""
    @FocusState private var pinFocused: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Unlock your imported identity to resume eligible NStack uploads. You can continue recording while locked.")
                    SecureField("PIN", text: $pin).keyboardType(.numberPad)
                        .focused($pinFocused).accessibilityIdentifier("identityUnlockPIN")
                    Button("Unlock identity") {
                        model.perform { try $0.unlock(pin: pin) }
                        pin = ""
                        if model.unlocked { done() }
                    }.disabled(pin.isEmpty).accessibilityIdentifier("identityUnlockButton")
                    if let notice = model.notice { Text(notice) }
                }
            }.navigationTitle("Unlock identity")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Continue locked") { pin = ""; done() } } }
        }.onAppear { pinFocused = true }
            .onDisappear { pin = "" }
            .onChange(of: scenePhase) { _, phase in if phase != .active { pin = "" } }
    }
}

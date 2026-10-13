import SwiftUI
import UIKit

@main
struct PeteRecorderApp: App {
    @StateObject private var model = RecorderModel()
    var body: some Scene { WindowGroup { RecorderView(model: model) } }
}

struct ShareFile: Identifiable { let id = UUID(); let url: URL }
struct RecorderView: View {
    @ObservedObject var model: RecorderModel
    @State private var selected: Recording?
    @State private var renameText = ""
    @State private var renameTarget: Recording?
    @State private var deleteTarget: Recording?
    @State private var downloadTarget: Recording?
    @State private var share: ShareFile?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        Label(model.active == nil ? "Ready to record" : "Recording", systemImage: model.active == nil ? "mic" : "record.circle.fill")
                            .font(.title2.bold()).foregroundStyle(model.active == nil ? Color.primary : .red)
                        if model.active != nil {
                            Text(Duration.seconds(model.elapsed).formatted(.time(pattern: .hourMinuteSecond))).font(.largeTitle.monospacedDigit())
                                .accessibilityLabel("Recording duration")
                                .accessibilityValue(Duration.seconds(model.elapsed).formatted(.time(pattern: .hourMinuteSecond)))
                        }
                        Text("Actual input: \(model.actualInput)").font(.callout)
                        Button("Find available microphones") { Task { await model.prepareInputs() } }.buttonStyle(.borderless).disabled(model.busy)
                        Menu("Choose microphone", systemImage: "mic.badge.plus") {
                            ForEach(model.inputs, id: \.uid) { input in Button(input.portName) { model.selectInput(input) } }
                            if model.inputs.isEmpty { Text("No selectable input available") }
                        }.buttonStyle(.borderless).disabled(model.inputs.isEmpty || model.busy)
                        Button {
                            if model.active != nil { model.stop() } else { Task { await model.start() } }
                        } label: {
                            Label(model.active == nil ? "Start recording" : "Stop and save", systemImage: model.active == nil ? "record.circle" : "stop.circle.fill")
                                .font(.title3.bold()).foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 10)
                        }.buttonStyle(.borderedProminent).tint(model.active == nil ? Color(red: 0.75, green: 0.08, blue: 0.12) : .blue)
                            .disabled(model.busy || model.store == nil).accessibilityIdentifier("recordButton")
                        Text("Audio stays on this iPhone. Active recording can continue while locked or in the background. Force quit stops capture.").font(.footnote).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }
                if let warning = model.message {
                    Section("Notice") {
                        Text(warning).foregroundStyle(.primary).accessibilityIdentifier("notice")
                        Button("Dismiss notice") { model.message = nil }
                    }
                }
                Section("Recordings · \(model.recordings.count)") {
                    if model.recordings.isEmpty { Text("Your saved recordings will appear here.").foregroundStyle(.secondary) }
                    ForEach(model.recordings) { r in
                        Button { selected = r } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(r.title).font(.headline).foregroundStyle(.primary)
                                Text(r.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                Text("\(Duration.seconds(r.duration).formatted(.time(pattern: .hourMinuteSecond))) · \(r.state.rawValue.capitalized)").font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }.accessibilityHint("Opens playback, sharing and recording details")
                    }
                }
            }.navigationTitle("Pete Recorder")
                .overlay { if model.busy { VStack {
                    ProgressView("Working… audio stays local")
                    if model.transcribing { Button("Cancel transcription") { model.cancelTranscription() } }
                }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
                .sheet(item: $selected) { r in details(r) }
                .sheet(item: $share) { ShareSheet(url: $0.url) }
                .alert("Rename recording", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
                    TextField("Recording name", text: $renameText)
                    Button("Save") { if let r = renameTarget { model.rename(r, title: renameText) }; renameTarget = nil }
                    Button("Cancel", role: .cancel) { renameTarget = nil }
                }
                .confirmationDialog("Delete recording and all its audio?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), titleVisibility: .visible) {
                    Button("Delete permanently", role: .destructive) { if let r = deleteTarget { model.delete(r) }; deleteTarget = nil }
                }
                .alert("Download language model?", isPresented: Binding(get: { downloadTarget != nil }, set: { if !$0 { downloadTarget = nil } })) {
                    Button("Download and transcribe") { if let r = downloadTarget { model.startTranscription(r, download: true) }; downloadTarget = nil }
                    Button("Cancel", role: .cancel) { downloadTarget = nil }
                } message: { Text("Apple may download a speech model using network and storage. Saved audio is processed on this device and is never uploaded by this app.") }
        }
    }
    func details(_ original: Recording) -> some View {
        let r = model.recordings.first(where: { $0.id == original.id }) ?? original
        return NavigationStack {
            List {
                Section {
                    Text(r.title).font(.title2.bold())
                    Text(r.createdAt.formatted())
                    Text("\(r.segments.count) AAC segments · \(r.state.rawValue)")
                    Button(model.playing == r.id ? "Stop playback" : "Play recording", systemImage: model.playing == r.id ? "stop.fill" : "play.fill") { model.play(r) }.disabled(model.active != nil || model.busy)
                    Button("Share AAC m4a", systemImage: "square.and.arrow.up") {
                        selected = nil
                        Task {
                            model.busy = true
                            defer { model.busy = false }
                            do { share = ShareFile(url: try await model.export(r)) } catch { model.report(error) }
                        }
                    }.disabled(model.busy || model.active != nil)
                    Button("Rename", systemImage: "pencil") { selected = nil; renameText = r.title; renameTarget = r }.disabled(model.busy)
                    Button("Delete", systemImage: "trash", role: .destructive) { selected = nil; deleteTarget = r }.disabled(model.busy)
                }
                Section("Local transcription") {
                    Text(model.speechStatus).font(.footnote)
                    if model.transcribing {
                        ProgressView("Transcribing on device…")
                        Button("Cancel transcription") { model.cancelTranscription() }
                    }
                    Button("Transcribe with installed model") { model.startTranscription(r, download: false) }.disabled(model.busy || model.active != nil)
                    Button("Download model & transcribe…") { selected = nil; downloadTarget = r }.disabled(model.busy || model.active != nil)
                    if let text = r.transcript { Text(text.isEmpty ? "No speech detected." : text).textSelection(.enabled) }
                }
                if let warning = model.message { Section("Notice") { Text(warning).foregroundStyle(.primary) } }
                Section("Recording history") { ForEach(Array(r.events.enumerated()), id: \.offset) { Text($0.element).font(.footnote) } }
            }.navigationTitle("Recording").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { selected = nil } }
        }
    }
}
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

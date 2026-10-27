import SwiftUI
import UIKit

@main
struct PeteRecorderApp: App {
    @UIApplicationDelegateAdaptor(RecorderAppDelegate.self) private var appDelegate
    @StateObject private var model: RecorderModel
    @StateObject private var identity: IdentityModel
    init() {
        #if DEBUG && targetEnvironment(simulator)
        _identity = StateObject(wrappedValue: ProcessInfo.processInfo.arguments.contains("--synthetic-unlock") ? SyntheticUnlockIdentity.make() : IdentityModel())
        #else
        _identity = StateObject(wrappedValue: IdentityModel())
        #endif
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--synthetic-retention") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("UIRetention-" + UUID().uuidString)
            _model = StateObject(wrappedValue: RecorderModel(root: root))
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--synthetic-meter") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("UIMeter-" + UUID().uuidString)
            let model = RecorderModel(root: root)
            model.showSyntheticCaptureFeedback()
            _model = StateObject(wrappedValue: model)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--synthetic-conversation") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("UIConversation-" + UUID().uuidString)
            let transferRoot = root.deletingLastPathComponent()
                .appendingPathComponent(root.lastPathComponent + "-transfers")
            let destination = NStackDestination(
                origin:"https://example.invalid", signer:"synthetic-signer", workspace:UUID().uuidString,
                workspaceLabel:"Synthetic", appNpub:"synthetic-app", channel:UUID().uuidString,
                channelLabel:"Rick", recipient:nil, recipientLabel:nil,
                prompt:"Please review this recording.", automatic:false
            )
            var waiting = TransferJob(recordingID:UUID(),destination:destination,title:"Waiting",body:"",createdAt:Date().addingTimeInterval(-120),files:[],conversationID:UUID())
            waiting.state = "sent"; waiting.threadID = "synthetic-thread"
            let local = TransferJob(recordingID:UUID(),destination:destination,title:"Local",body:"",createdAt:Date().addingTimeInterval(-30),files:[],conversationID:UUID())
            try? FileManager.default.createDirectory(at:transferRoot,withIntermediateDirectories:true)
            try? JSONEncoder().encode(NStackTransfers.Ledger(jobs:[waiting,local],intents:[],destination:destination))
                .write(to:transferRoot.appendingPathComponent("ledger.json"),options:.atomic)
            _model = StateObject(wrappedValue:RecorderModel(root:root))
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--synthetic-review") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("UIReview-" + UUID().uuidString)
            let model = RecorderModel(root: root)
            var recording = Recording(title: "Synthetic transcript review")
            recording.state = .saved; recording.transcript = "nosta, 123. nosta!"; recording.transcriptionState = .complete
            try? model.store?.save(recording); model.recordings = [recording]
            _model = StateObject(wrappedValue: model)
            return
        }
        #endif
        _model = StateObject(wrappedValue: RecorderModel())
    }
    var body: some Scene { WindowGroup { RecorderView(model:model,identity:identity) } }
}

struct ShareFile: Identifiable { let id = UUID(); let url: URL }
private struct ReplyPollingKey: Hashable {
    let jobID: UUID
    let active: Bool
    let signer: String?
}
struct RecorderView: View {
    @ObservedObject var model: RecorderModel
    @ObservedObject var transfers: NStackTransfers
    init(model: RecorderModel, identity: IdentityModel? = nil) {
        self.model = model; self.transfers = model.transfers
        _identity = StateObject(wrappedValue: identity ?? IdentityModel())
    }
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var identity: IdentityModel
    @State private var unlockOpen = false
    @State private var unlockPolicy = ForegroundUnlockPolicy()
    @State private var menuOpen = false
    @State private var pendingRecording: Recording?
    @State private var micOpen = false
    @State private var routeOpen = false
    @State private var criticalNotice = false
    @State private var selected: Recording?
    @State private var renameText = ""
    @State private var renameTarget: Recording?
    @State private var deleteTarget: Recording?
    @State private var downloadTarget: Recording?
    @State private var share: ShareFile?
    @State private var conversationsExpanded = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                Spacer()
                Picker("Conversation profile", selection: Binding(
                    get: { transfers.routing.mode },
                    set: { mode in
                        do { try transfers.setMode(mode) }
                        catch { model.report(error) }
                    }
                )) {
                    ForEach(DialogueMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("dialogueMode")
                Button { micOpen = true; Task { await model.prepareInputs() } } label: {
                    HStack(spacing:8) {
                        Image(systemName:"mic.fill")
                        VStack(alignment:.leading,spacing:1) {
                            Text(model.actualInput).font(.caption.weight(.semibold)).lineLimit(1)
                            Text(model.preferredInputAvailable == false ? "Saved microphone unavailable · System default" : "Tap to choose microphone")
                                .font(.caption2).lineLimit(1)
                        }
                    }
                    .frame(maxWidth:.infinity)
                    .padding(.vertical,3)
                    .foregroundStyle(activeMicrophoneSelected ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("microphoneControl")
                .disabled(model.busy)
                if model.active != nil {
                    CaptureLevelView(levels: model.levels)
                    Text(Duration.seconds(model.elapsed).formatted(.time(pattern: .hourMinuteSecond)))
                        .font(.largeTitle.monospacedDigit()).accessibilityLabel("Recording duration")
                }
                if model.active == nil {
                    Button { Task { await model.start() } } label: {
                        Label("New recording", systemImage:"record.circle").font(.title3.bold()).frame(maxWidth:.infinity).padding(.vertical,12)
                    }.buttonStyle(.borderedProminent).tint(.red)
                        .disabled((model.busy && !model.preparingUpload) || model.store == nil).accessibilityIdentifier("recordButton")
                } else {
                    Button { model.stop(publishAudioOnly:true) } label: {
                        Label("Stop, upload & publish audio",systemImage:"arrow.up.circle.fill").font(.title3.bold()).frame(maxWidth:.infinity).padding(.vertical,12)
                    }.buttonStyle(.borderedProminent).tint(.red).disabled(model.store == nil).accessibilityIdentifier("publishAudioButton")
                    Button { model.stop() } label: {
                        Label("Stop and transcribe locally",systemImage:"stop.circle.fill").frame(maxWidth:.infinity).padding(.vertical,8)
                    }.buttonStyle(.bordered).disabled(model.store == nil).accessibilityIdentifier("recordButton")
                }
                if model.active == nil, !transfers.recentConversationJobs.isEmpty {
                    conversations
                }
                Spacer()
                }.padding(24)
            }.refreshable { await transfers.refreshRecentReplies() }
                .navigationTitle("In Dialogue")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { menuOpen = true } label: {
                            Image(systemName: model.message == nil ? "line.3.horizontal" : "line.3.horizontal.circle.fill")
                        }.accessibilityLabel(model.message == nil ? "Menu" : "Menu, notice available").accessibilityIdentifier("menuButton")
                    }
                }
                .sheet(isPresented: $menuOpen, onDismiss: {
                    if let pendingRecording, !(identity.exists && !identity.unlocked && !unlockPolicy.requested) { selected = pendingRecording }
                    self.pendingRecording = nil
                    requestUnlock()
                }) { menu }
                .sheet(isPresented: $micOpen, onDismiss: { requestUnlock() }) { microphones }
                .sheet(isPresented:$routeOpen,onDismiss:{ requestUnlock() }) {
                    NavigationStack {
                        NStackSettings(transfers:transfers,identity:identity)
                            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { routeOpen = false } } }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.foreground(); requestUnlock() }
                    else if phase == .background { unlockOpen = false; unlockPolicy.background(); model.background(); transfers.enterBackground() }
                }
                .onChange(of: model.message) { _, value in if value != nil { criticalNotice = true } }
                .alert("Recorder notice", isPresented: $criticalNotice) {
                    Button("OK", role: .cancel) {}
                } message: { Text(model.message ?? "See Notices in the menu.") }
                .sheet(item: $selected, onDismiss: { requestUnlock() }) { r in details(r) }
                .sheet(item: $share, onDismiss: { model.sharingID = nil; model.runRetention(); requestUnlock() }) { ShareSheet(url: $0.url) }
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
                } message: { Text("Apple may download a speech model using network and storage. Transcription runs on this device. NStack uploads occur only with your saved setup or explicit Upload.") }
        }.onChange(of:identity.npub) { _,_ in refreshTransfers() }
        .onChange(of:model.active) { _,_ in refreshTransfers() }
        .onChange(of:scenePhase) { _,_ in refreshTransfers() }
        .onAppear {
            refreshTransfers(); requestUnlock()
            if !transfers.recentConversationJobs.isEmpty { conversationsExpanded = true }
        }
        .fullScreenCover(isPresented: $unlockOpen, onDismiss: { refreshTransfers() }) {
            IdentityUnlock(model: identity) { unlockOpen = false; refreshTransfers() }
        }
    }
    var activeMicrophoneSelected: Bool {
        !["No active input", "Microphone inactive"].contains(model.actualInput)
    }
    var conversations: some View {
        DisclosureGroup(isExpanded:$conversationsExpanded) {
            VStack(spacing:8) {
                ForEach(transfers.recentConversationJobs) { job in conversationRow(job) }
            }.padding(.top,6)
        } label: {
            HStack {
                Text("Conversation").font(.headline).foregroundStyle(.primary)
                Spacer()
                Button { Task { await transfers.refreshRecentReplies() } } label: {
                    Image(systemName:"arrow.clockwise")
                        .frame(width:44,height:44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh recent conversations")
                .accessibilityHint("Checks for new replies")
                .accessibilityIdentifier("refreshConversations")
            }
        }
        .padding()
        .background(.thinMaterial,in:RoundedRectangle(cornerRadius:16))
        .accessibilityIdentifier("recentConversations")
    }
    func conversationRow(_ job: TransferJob) -> some View {
        let unobscured = !menuOpen && !micOpen && !routeOpen && !unlockOpen && selected == nil && share == nil
            && renameTarget == nil && deleteTarget == nil && downloadTarget == nil && !criticalNotice
        let poll = ReplyPollingKey(jobID:job.id,active:job.id == transfers.latestConversationJob?.id && scenePhase == .active && model.active == nil && unobscured,signer:identity.npub)
        let status = transfers.conversationStatus(for:job)
        let reply = job.conversationID.flatMap { transfers.replies[$0] }
        let followupRoute = transfers.followupRoute(for:job)
        return VStack(alignment:.leading,spacing:6) {
            Text(job.createdAt,style:.relative).font(.caption).foregroundStyle(.secondary)
            HStack(spacing:8) {
                Button {
                    if status == .local || status == .failed { transfers.sendPendingConversation(job.id) }
                    else if let reply { transfers.toggleReplyPlayback(reply,for:job.id) }
                } label: {
                    ZStack(alignment:.bottomTrailing) {
                        Image(systemName:replyPlaybackIcon(reply:reply))
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                            .frame(maxWidth:.infinity,minHeight:48)
                            .background(statusColor(status),in:RoundedRectangle(cornerRadius:10))
                        Image(systemName:statusBadgeIcon(status))
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
                .buttonStyle(.plain)
                .disabled(status == .waiting)
                .accessibilityLabel(statusLabel(status))
                .accessibilityHint(status == .local || status == .failed ? "Sends this recording to its saved destination" : status == .replied ? "Plays the latest reply" : "")
                .accessibilityIdentifier("conversationPlayStatus")

                Button {
                    guard var route = followupRoute else { return }
                    route.respondingToReplyID = reply?.id
                    Task { await model.start(route:route) }
                } label: {
                    Image(systemName:"mic.fill")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .frame(maxWidth:.infinity,minHeight:48)
                        .background(Color.blue,in:RoundedRectangle(cornerRadius:10))
                }
                .buttonStyle(.plain)
                .disabled(followupRoute == nil)
                .accessibilityLabel("Record response")
                .accessibilityHint("Starts a recording in this conversation")
                .accessibilityIdentifier("conversationRecord")
            }
            if let conversation = job.conversationID, let reply = transfers.replies[conversation] {
                let responseStatus = transfers.responseStatus(to:reply,for:job.id)
                DisclosureGroup("Show reply") {
                    Text(reply.body).frame(maxWidth:.infinity,alignment:.leading).accessibilityIdentifier("replyText")
                    if case .failed(let notice) = responseStatus {
                        if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                        Button("Retry response",systemImage:"arrow.clockwise") { transfers.retryResponse(to:reply,for:job.id) }
                    }
                }
            } else if let notice = job.notice, status == .failed {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical,4).accessibilityElement(children:.contain)
            .task(id:poll) {
                guard poll.active, poll.signer == job.destination.signer else { return }
                refreshTransfers()
                await transfers.pollReplies(for:job.id)
            }
    }
    func replyPlaybackIcon(reply: DialogueReply?) -> String {
        if let reply, transfers.playingReplyID == reply.id { return "stop.fill" }
        return "play.fill"
    }
    func statusBadgeIcon(_ status: ConversationDeliveryStatus) -> String {
        switch status {
        case .local: return "paperplane.fill"
        case .waiting: return "clock.fill"
        case .replied: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
    func statusColor(_ status: ConversationDeliveryStatus) -> Color {
        switch status { case .local:return .gray; case .waiting:return .orange; case .replied:return .green; case .failed:return .gray }
    }
    func statusLabel(_ status: ConversationDeliveryStatus) -> String {
        switch status { case .local:return "Not sent. Tap to send"; case .waiting:return "Sent. Waiting for reply"; case .replied:return "Reply available"; case .failed:return "Not sent. Tap to retry" }
    }
    func requestUnlock() {
        guard scenePhase == .active, identity.exists, !identity.unlocked, !unlockPolicy.requested else { return }
        // Let an existing sheet finish dismissing before presenting authentication.
        if menuOpen { menuOpen = false; return }
        if micOpen { micOpen = false; return }
        if routeOpen { routeOpen = false; return }
        if selected != nil { selected = nil; return }
        if share != nil { share = nil; return }
        if unlockPolicy.request(active: scenePhase == .active, exists: identity.exists, unlocked: identity.unlocked) { unlockOpen = true }
    }
    func refreshTransfers() {
        if scenePhase == .active { transfers.enterForeground() }
        transfers.setAvailability(active:model.active == nil, signer:identity.npub, api:NStackAPI { try identity.sign(kind:$0,tags:$1,content:$2) })
    }
    var microphones: some View {
        NavigationStack {
            List {
                Section("Preference") {
                    Text(model.microphonePreferenceLabel)
                    Text("The preference is used when available. iOS chooses the actual route.").font(.footnote)
                    Button("System default") { model.selectSystemInput() }
                }
                Section("Actual current route") { Text(model.actualInput) }
                Section("Supported inputs") {
                    ForEach(model.inputs, id: \.uid) { input in Button(input.portName) { model.selectInput(input) } }
                    if model.inputs.isEmpty { Text("No selectable inputs available.") }
                }
                if let notice = model.message { Section("Notice") { Text(notice) } }
            }.navigationTitle("Microphone").toolbar { Button("Done") { micOpen = false } }
        }
    }
    var menu: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink("NStack") { NStackSettings(transfers:transfers,identity:identity) }
                    NavigationLink("NStack uploads") { NStackHistory(transfers:transfers) }
                    NavigationLink("Identity") { IdentitySettings(model: identity) }
                    NavigationLink("Reply voice") { ReplyVoiceSettings(voice: transfers.replyVoice, model: model) }
                    NavigationLink("Settings") { RecordingRetentionSettings(model: model) }
                    NavigationLink("Vocabulary") { VocabularySettings(model: model) }
                    NavigationLink("Notices and status") {
                        List {
                            if let notice = model.message {
                                Text(notice).accessibilityIdentifier("notice")
                                Button("Dismiss notice") { model.message = nil }
                            }
                            Text(model.speechStatus)
                            Text(LocalCleanup.status())
                            Text("Transcription is deferred while recording and while the app is suspended. It resumes when the app is active. Audio stays local.")
                            if model.transcribing { Button("Cancel transcription") { model.cancelTranscription() } }
                        }.navigationTitle("Notices and status")
                    }
                }
                Section("Diagnostics") {
                    if let destination = transfers.diagnosticsDestinationLabel { Text(destination).font(.footnote) }
                    Button("Send diagnostics") { model.sendDiagnostics() }
                        .accessibilityIdentifier("sendDiagnostics")
                    Text("Manually sends the last hour of operational events to the configured NStack channel as a private JSON report. No audio, transcript or message content. Unlock the matching identity first. Pending reports survive relaunch; retry in NStack uploads.").font(.footnote)
                    if let status = transfers.diagnosticsStatus { Text(status).textSelection(.enabled) }
                    if let notice = model.diagnosticsNotice { Text(notice).accessibilityIdentifier("diagnosticsNotice") }
                }
                Section("Recordings · \(model.recordings.count)") {
                    if model.recordings.isEmpty { Text("No saved recordings.") }
                    ForEach(model.recordings) { r in
                        Button { pendingRecording = r; menuOpen = false } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(r.title).font(.headline)
                                Text("\(Duration.seconds(r.duration).formatted(.time(pattern: .hourMinuteSecond))) · \(r.state.rawValue.capitalized)").font(.caption)
                                if let notice = r.transcriptionNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }.navigationTitle("Menu").toolbar { Button("Done") { menuOpen = false } }
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
                            model.sharingID = r.id
                            model.busy = true
                            defer { model.busy = false }
                            do { share = ShareFile(url: try await model.export(r)) } catch { model.sharingID = nil; model.report(error) }
                        }
                    }.disabled(model.busy || model.active != nil)
                    Button("Rename", systemImage: "pencil") { selected = nil; renameText = r.title; renameTarget = r }.disabled(model.busy)
                    Button("Delete", systemImage: "trash", role: .destructive) { selected = nil; deleteTarget = r }.disabled(model.busy)
                }
                Section("NStack delivery") {
                    if let status = transfers.status(r.id) { Text(status) }
                    if transfers.jobs.last(where: { $0.recordingID == r.id && $0.state != "cancelled" })?.state == "failed" {
                        Button("Retry upload · same snapshot") { model.upload(r) }.disabled(model.busy || model.active != nil)
                    } else if !transfers.jobs.contains(where: { $0.recordingID == r.id && $0.state != "cancelled" }) {
                        Button("Upload corrected transcript and audio") { model.upload(r) }.disabled(model.busy || model.active != nil || r.transcriptionState != .complete)
                        Button("Upload audio for agent/server transcription") { model.uploadAudioOnly(r) }.disabled(model.busy || model.active != nil)
                    }
                    Text("Choose corrected text plus audio, or send only the saved audio and ask the receiving agent/server to transcribe it. Unaccepted cleanup drafts are excluded.").font(.footnote)
                }
                Section("Local transcription") {
                    Text(model.speechStatus).font(.footnote)
                    if model.transcribing {
                        ProgressView("Transcribing on device…")
                        Button("Cancel transcription") { model.cancelTranscription() }
                    }
                    Button("Transcribe with installed model") { model.startTranscription(r, download: false) }.disabled(model.busy || model.active != nil)
                    Button("Download model & transcribe…") { selected = nil; downloadTarget = r }.disabled(model.busy || model.active != nil)
                    if let notice = r.transcriptionNotice { Text(notice).font(.footnote) }
                    if r.transcript != nil { TranscriptReview(model: model, recordingID: r.id) }
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

#if DEBUG && targetEnvironment(simulator)
private final class SyntheticUnlockSecrets: VaultSecretStore {
    var value: Data?
    func read() throws -> Data? { value }
    func write(_ data: Data) throws { value = data }
}
private enum SyntheticUnlockIdentity {
    @MainActor static func make() -> IdentityModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SyntheticUnlock-" + UUID().uuidString)
        let vault = IdentityVault(url:root.appendingPathComponent("vault.json"),secrets:SyntheticUnlockSecrets())
        // Public synthetic scalar one; never a real identity or Keychain secret.
        try? vault.create(nsec:"nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqsmhltgl",pin:"123456")
        vault.lock()
        return IdentityModel(vault:vault)
    }
}
#endif

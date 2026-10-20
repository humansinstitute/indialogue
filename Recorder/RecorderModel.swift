import SwiftUI
import AVFoundation
import UIKit

@MainActor
final class RecorderModel: NSObject, ObservableObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    @Published var recordings: [Recording] = []
    @Published var active: Recording?
    @Published var vocabulary: [VocabularyCorrection] = []
    @Published var selectedInputName: String = UserDefaults.standard.string(forKey: "preferredInputName") ?? "System default"
    @Published var preferredInputAvailable: Bool?
    var microphonePreferenceLabel: String { Self.preferenceLabel(name: selectedInputName, available: preferredInputAvailable) }
    static func preferenceLabel(name: String, available: Bool?) -> String {
        if name == "System default" { return name }
        switch available {
        case true: return name + " · preference"
        case false: return name + " unavailable · System default"
        case nil: return name + " · preference (availability unchecked)"
        }
    }
    private var selectedInputUID: String? = UserDefaults.standard.string(forKey: "preferredInputUID")
    private var vocabularyStore: VocabularyStore?
    private var vocabularyReadable = true
    @Published private(set) var retention: RecordingRetention
    @Published var retentionNotice: String?
    private let retentionDefaults: UserDefaults
    private let protectedDataAvailable: () -> Bool
    private var exportsInProgress: [UUID: Int] = [:]
    private var cleanupID: UUID?
    private let cleanup: ((String, [VocabularyCorrection]) async throws -> String)?
    var sharingID: UUID?
    private var suspended = false
    private var deferredTranscription = false
    private var downloadRequests: Set<UUID> = []
    private var transcriptionID: UUID?
    private let speech: ([URL], Bool) async throws -> LocalTranscript
    private let audioExport: ((Recording) async throws -> URL)?
    @Published var cleanupStatus: String?
    @Published var cleaning = false
    private var cleanupTask: Task<Void, Never>?
    @Published var actualInput = "Microphone inactive"
    @Published var inputs: [AVAudioSessionPortDescription] = []
    @Published var message: String?
    @Published var elapsed: Double = 0
    @Published var playing: UUID?
    @Published var busy = false
    @Published var transcribing = false
    private var transcriptionTask: Task<Void, Never>?
    @Published var speechStatus = "Local transcription requires iOS 26 and a supported device/language."
    let store: RecordingStore?
    let transfers: NStackTransfers
    private var snapshotTask: Task<Void, Never>?
    @Published var levels = CaptureLevels()
    private var routeHistory = CaptureRouteHistory()
    #if DEBUG && targetEnvironment(simulator)
    private var syntheticFeedback = false
    func showSyntheticCaptureFeedback() {
        syntheticFeedback = true
        active = Recording(title: "Synthetic meter")
        actualInput = "Synthetic microphone"
        levels.start()
        for value: Float in [-65, -55, -48, -40, -25, -12, -6, -18, -32, -50] { levels.append(decibels: value) }
    }
    #endif
    private var startupInterrupted = false
    private var capturePending = false
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var playbackRecord: Recording?
    private var playbackIndex = 0
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let session = AVAudioSession.sharedInstance()

    init(root requestedRoot: URL? = nil,
         speech: @escaping ([URL], Bool) async throws -> LocalTranscript = { try await LocalSpeech.transcribe($0, download: $1) },
         audioExport: ((Recording) async throws -> URL)? = nil,
         cleanup: ((String, [VocabularyCorrection]) async throws -> String)? = nil,
         retentionDefaults: UserDefaults? = nil,
         protectedDataAvailable: @escaping () -> Bool = { UIApplication.shared.isProtectedDataAvailable }) {
        let defaults = retentionDefaults ?? requestedRoot.flatMap { UserDefaults(suiteName: "RecorderTests." + $0.lastPathComponent) } ?? .standard
        self.retentionDefaults = defaults
        self.retention = RecordingRetention.load(from: defaults)
        self.protectedDataAvailable = protectedDataAvailable
        self.speech = speech; self.audioExport = audioExport; self.cleanup = cleanup
        var loaded: [Recording] = []
        var failure: String?
        var candidate: RecordingStore?
        do {
            let root = try requestedRoot ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Recordings")
            let s = try RecordingStore(root: root)
            loaded = try s.recover()
            candidate = s
            if !s.warnings.isEmpty { failure = s.warnings.joined(separator: "\n") }
        } catch { failure = "Library unavailable: \(error.localizedDescription). Existing files have not been deleted." }
        transfers = NStackTransfers(root: requestedRoot.map { $0.deletingLastPathComponent().appendingPathComponent($0.lastPathComponent + "-transfers") } ?? (candidate?.root.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory).appendingPathComponent("NStack"))
        store = candidate
        super.init()
        recordings = loaded; message = failure
        if let candidate {
            vocabularyStore = VocabularyStore(url: candidate.root.appendingPathComponent("vocabulary.json"))
            do { vocabulary = try vocabularyStore!.load() }
            catch { vocabularyReadable = false; message = "Vocabulary unreadable; original file retained. \(error.localizedDescription)" }
        }
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in self?.notification(note) }
            })
        }
        transfers.onIdle = { [weak self] in self?.runRetention() }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.runRetention() }
        })
        runRetention()
        Task { speechStatus = await LocalSpeech.status(); resumeTranscriptionQueue(); resumeUploadSnapshots() }
    }
    func saveRetention(enabled: Bool, days: String) -> Bool {
        guard let count = RecordingRetention.parseDays(days) else {
            retentionNotice = RecordingRetention.validationMessage; return false
        }
        let policy = RecordingRetention(enabled: enabled, days: count)
        do {
            try policy.save(to: retentionDefaults); retention = policy; retentionNotice = nil
            runRetention(); return true
        } catch { retentionNotice = error.localizedDescription; return false }
    }
    /// Synchronous on the main actor: eligibility cannot race with a new job or playback.
    func runRetention(now: Date = Date()) {
        guard retention.enabled, !suspended, protectedDataAvailable(), let store,
              !capturePending, !busy, snapshotTask == nil, transfers.retentionReady else { return }
        if retentionNotice?.hasPrefix("Automatic deletion could not finish.") == true { retentionNotice = nil }
        for r in recordings where retention.expires(r, now: now) {
            guard r.state != .recording, active?.id != r.id, playing != r.id,
                  transcriptionID != r.id, cleanupID != r.id, exportsInProgress[r.id, default: 0] == 0, sharingID != r.id,
                  ![.queued, .running].contains(r.transcriptionState),
                  !transfers.retentionProtects(r.id) else { continue }
            do {
                try transfers.deleteFinishedLocalArtifacts(r.id)
                try store.delete(r)
                recordings.removeAll { $0.id == r.id }
            } catch {
                retentionNotice = "Automatic deletion could not finish. It will retry when the app is active: \(error.localizedDescription)"
            }
        }
    }
    func refreshRoute() {
        let availableInputs = session.availableInputs
        inputs = availableInputs ?? []
        if let uid = selectedInputUID {
            if let availableInputs { preferredInputAvailable = availableInputs.contains { $0.uid == uid } }
            else if active != nil { preferredInputAvailable = session.currentRoute.inputs.contains { $0.uid == uid } }
            // Deactivation may hide availableInputs; retain the last known availability.
        } else { preferredInputAvailable = nil }
        actualInput = session.currentRoute.inputs.map { port in
            port.portName + (port.selectedDataSource.map { " · " + $0.dataSourceName } ?? "")
        }.joined(separator: ", ")
        if actualInput.isEmpty { actualInput = "No active input" }
    }
    private var routeSnapshot: [CaptureInput] {
        session.currentRoute.inputs.map { CaptureInput(uid: $0.uid, source: $0.selectedDataSource?.dataSourceID.stringValue, name: $0.portName) }
    }
    func prepareInputs() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            message = "Microphone access denied. Enable it in Settings → Privacy & Security → Microphone → Pete Recorder."
            return
        }
        do {
            guard active == nil, playing == nil else { refreshRoute(); return }
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            refreshRoute()
        } catch { report(error) }
    }
    func selectInput(_ input: AVAudioSessionPortDescription) {
        do {
            try session.setPreferredInput(input)
            selectedInputUID = input.uid; selectedInputName = input.portName
            UserDefaults.standard.set(input.uid, forKey: "preferredInputUID")
            UserDefaults.standard.set(input.portName, forKey: "preferredInputName")
            refreshRoute()
            if var r = active { r.events.append("Input preference: \(input.portName); actual: \(actualInput)"); try persist(r); active = r }
        } catch { report(error); if active != nil { stop(interrupted: true) } }
    }
    func selectSystemInput() {
        do {
            try session.setPreferredInput(nil)
            selectedInputUID = nil; selectedInputName = "System default"
            UserDefaults.standard.removeObject(forKey: "preferredInputUID")
            UserDefaults.standard.removeObject(forKey: "preferredInputName")
            refreshRoute()
        } catch { report(error) }
    }
    func start(route requestedRoute: DialogueRouteSnapshot? = nil) async {
        guard !capturePending, active == nil, (!busy || snapshotTask != nil), let store else { return }
        // Capture routing before any permission prompt, audio-session wait or mutable settings read.
        let immutableRoute = requestedRoute ?? transfers.captureRoute()
        capturePending = true; startupInterrupted = false; defer { capturePending = false }
        if let snapshotTask { snapshotTask.cancel(); await snapshotTask.value }
        prioritizeCapture()
        message = nil
        busy = true; defer { busy = false; if active == nil { resumeTranscriptionQueue() } }
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard allowed else { message = "Microphone access denied. Enable it in Settings → Privacy & Security → Microphone → Pete Recorder."; return }
        stopPlayback()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            let requestedInput = selectedInputUID.flatMap { uid in session.availableInputs?.first { $0.uid == uid } }
            try session.setPreferredInput(requestedInput) // A vanished preference must not masquerade as an actual route.
            // Route selection can complete asynchronously. Yield without opening another capture.
            try await waitForPreferredCaptureInput(uid: requestedInput?.uid, current: { self.routeSnapshot },
                                                   interrupted: { self.startupInterrupted })
            guard !startupInterrupted else { throw RecorderError.capture }
            try Task.checkCancellation()
            refreshRoute()
            var r = Recording(title: Date.now.formatted(date: .abbreviated, time: .shortened))
            r.dialogueRoute = immutableRoute
            r.events.append("Started with \(actualInput)")
            if preferredInputAvailable == false { r.events.append("Preferred microphone unavailable: \(selectedInputName). Actual route: \(actualInput)") }
            try store.save(r) // Intent is durable before the microphone starts.
            active = r; elapsed = 0
            levels.start()
            try beginSegment()
            refreshRoute()
            routeHistory.start(routeSnapshot)
            if var started = active {
                started.events[0] = "Started with \(actualInput)"
                if let requestedInput, !session.currentRoute.inputs.contains(where: { $0.uid == requestedInput.uid }) {
                    started.events.append("Preferred microphone request not yet reflected in actual route: \(selectedInputName); actual: \(actualInput)")
                }
                try persist(started); active = started
            }
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            report(error)
            if active != nil { stop(interrupted: true) }
            else { try? session.setActive(false, options: .notifyOthersOnDeactivation); refreshRoute() }
        }
    }
    private func beginSegment() throws {
        guard var r = active, let store else { return }
        let available = try store.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard available > 20_000_000 else { throw RecorderError.storage }
        let name = String(format: "segment-%05d.m4a", r.segments.count)
        r.segments.append(name)
        try store.save(r) // Persist path before capture, including incomplete files.
        active = r
        let next = try AVAudioRecorder(url: store.audio(r, name), settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96000])
        next.delegate = self
        next.isMeteringEnabled = !suspended
        guard next.prepareToRecord() else { throw RecorderError.capture }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: next.url.path)
        guard next.record(forDuration: 15) else { throw RecorderError.capture }
        recorder = next
    }
    private func tick() {
        guard let r = active, let recorder else { return }
        elapsed = r.duration + recorder.currentTime
        guard !suspended, recorder.isRecording else { return }
        recorder.updateMeters()
        levels.append(decibels: recorder.averagePower(forChannel: 0))
    }
    private func closeSegment() throws {
        guard var r = active else { return }
        let elapsedInSegment = recorder?.currentTime ?? 0
        let finished = recorder; recorder = nil; finished?.stop()
        if let finished, let audio = try? AVAudioPlayer(contentsOf: finished.url) {
            r.duration += audio.duration
        } else { r.duration += elapsedInSegment }
        active = r
        try persist(r)
    }
    func stop(interrupted: Bool = false, publishAudioOnly: Bool = false) {
        timer?.invalidate(); timer = nil
        levels.stop(); routeHistory.stop()
        guard active != nil else { return }
        var finalSegmentFailed = false
        do { try closeSegment() } catch { finalSegmentFailed = true; report(error) }
        var delivery: (recording: Recording, force: Bool)?
        if var r = active {
            r.state = interrupted || finalSegmentFailed ? .interrupted : .saved
            if !interrupted && !finalSegmentFailed {
                if publishAudioOnly {
                    r.deliveryContent = .audioOnly
                    r.transcriptionState = .none
                    r.transcriptionNotice = "Local transcription skipped. Audio will be transcribed by the agent/server."
                    r.events.append("Saved for audio-first delivery without local transcription.")
                    delivery = (r, true)
                } else {
                    r.deliveryContent = .transcriptAndAudio
                    r.transcriptionState = .queued
                    r.transcriptionNotice = "Queued for transcription using installed speech model."
                    delivery = (r, false)
                }
            }
            if interrupted || finalSegmentFailed { r.events.append("Capture stopped unexpectedly; inspect saved audio before resuming a new recording.") }
            do { try persist(r) }
            catch { delivery = nil; report(error) }
            recordings.removeAll { $0.id == r.id }; recordings.insert(r, at: 0)
        }
        active = nil; elapsed = 0
        if let delivery, !transfers.rememberNew(delivery.recording, force:delivery.force), delivery.force {
            message = "Audio saved, but it cannot publish until an NStack destination is configured."
        }
        runRetention()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        refreshRoute()
        resumeTranscriptionQueue(); resumeUploadSnapshots()
    }
    private func notification(_ note: Notification) {
        if note.name == AVAudioSession.routeChangeNotification {
            refreshRoute()
            if let uid = selectedInputUID,
               (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
               let previous = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription,
               previous.inputs.contains(where: { $0.uid == uid }), !session.currentRoute.inputs.contains(where: { $0.uid == uid }) {
                preferredInputAvailable = false
            }
            if var r = active {
                let change = routeHistory.observe(routeSnapshot, capturing: recorder?.isRecording == true)
                if change.changed {
                    let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
                    r.events.append("Route changed: \(actualInput) (reason \(reason))")
                    do { try persist(r); active = r } catch { report(error); stop(interrupted: true); return }
                }
                if change.lostInput {
                    message = "Input unavailable or capture stopped after route change. Saved segments retained."
                    stop(interrupted: true)
                }
            }
        } else if note.name == AVAudioSession.mediaServicesWereResetNotification ||
            (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue {
            if capturePending { startupInterrupted = true }
            message = "Audio interrupted. Saved segments retained. Start a new recording when ready."
            stop(interrupted: true); stopPlayback()
        }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in guard self.recorder === recorder else { return }; self.message = "Audio encoding failed: \(error?.localizedDescription ?? "unknown error")"; self.stop(interrupted: true) }
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            guard self.recorder === recorder, self.active != nil else { return }
            if flag {
                do { try self.closeSegment(); try self.beginSegment() }
                catch { self.report(error); self.stop(interrupted: true) }
            } else { self.message = "Recording stopped unexpectedly."; self.stop(interrupted: true) }
        }
    }
    private func persist(_ r: Recording) throws { try store?.save(r) }
    func rename(_ r: Recording, title: String) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !busy else { return }
        var edited = recordings.first(where: { $0.id == r.id }) ?? r; edited.title = name
        do { try persist(edited); replace(edited) } catch { report(error) }
    }
    func delete(_ r: Recording) {
        guard !busy else { return }
        if transcriptionID == r.id { cancelTranscription() }
        cancelCleanup()
        if playing == r.id { stopPlayback() }
        do { try store?.delete(r); recordings.removeAll { $0.id == r.id } } catch { report(error) }
    }
    func replace(_ r: Recording) { if let i = recordings.firstIndex(where: { $0.id == r.id }) { recordings[i] = r } }
    func play(_ r: Recording) {
        guard active == nil else { return }
        if playing == r.id { stopPlayback(); return }
        stopPlayback()
        do {
            try session.setCategory(.playback); try session.setActive(true)
            playbackRecord = r; playbackIndex = 0; playing = r.id
            try playSegment()
        } catch { report(error); stopPlayback() }
    }
    private func playSegment() throws {
        guard let r = playbackRecord, let store else { stopPlayback(); return }
        while playbackIndex < r.segments.count {
            do {
                player = try AVAudioPlayer(contentsOf: store.audio(r, r.segments[playbackIndex]))
                player?.delegate = self
                guard player?.play() == true else { throw RecorderError.capture }
                return
            } catch {
                message = "Playback skipped unreadable segment \(r.segments[playbackIndex]). Original file retained."
                playbackIndex += 1
            }
        }
        stopPlayback()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            if !flag { self.message = "Playback interrupted or failed. Original audio retained." }
            self.playbackIndex += 1
            do { try self.playSegment() } catch { self.report(error); self.stopPlayback() }
        }
    }
    func stopPlayback() { Task { @MainActor [weak self] in self?.runRetention() }; player?.stop(); player = nil; playing = nil; playbackRecord = nil; if active == nil { try? session.setActive(false, options: .notifyOthersOnDeactivation) } }
    func export(_ r: Recording, requireComplete: Bool = false) async throws -> URL {
        exportsInProgress[r.id, default: 0] += 1
        defer { exportsInProgress[r.id, default: 0] -= 1 }
        if requireComplete && r.state != .saved { throw NStackError.incomplete }
        guard let store else { throw RecorderError.capture }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw RecorderError.capture }
        var time = CMTime.zero
        var skipped: [String] = []
        for name in r.segments {
            do {
                let asset = AVURLAsset(url: store.audio(r, name))
                let duration = try await asset.load(.duration)
                guard let source = try await asset.loadTracks(withMediaType: .audio).first else { throw RecorderError.capture }
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: time)
                time = time + duration
            } catch { skipped.append(name) }
        }
        if requireComplete && !skipped.isEmpty { throw NStackError.incomplete }
        try Task.checkCancellation()
        guard time > .zero else { throw RecorderError.capture }
        if !skipped.isEmpty { message = "Shared playable audio only. Unreadable segments omitted: \(skipped.joined(separator: ", ")). Original files retained." }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(r.id.uuidString + "-" + UUID().uuidString + ".m4a")
        try? FileManager.default.removeItem(at: output)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { throw RecorderError.capture }
        try await exporter.export(to: output, as: .m4a)
        return output
    }
    func startTranscription(_ r: Recording, download: Bool) {
        guard active == nil, !busy, let current = recordings.first(where: { $0.id == r.id }) else { return }
        if download { downloadRequests.insert(r.id) }
        updateTranscription(current.id, state: .queued, notice: "Queued for local transcription.")
        resumeTranscriptionQueue()
    }
    func updateTranscription(_ id: UUID, state: Recording.TranscriptionState, notice: String?) {
        guard var r = recordings.first(where: { $0.id == id }) else { return }
        r.transcriptionState = state; r.transcriptionNotice = notice
        do { try persist(r); replace(r) } catch { report(error) }
    }
    func resumeTranscriptionQueue() {
        guard !suspended, active == nil, !busy, transcriptionTask == nil,
              let r = recordings.reversed().first(where: { $0.transcriptionState == .queued }) else { return }
        deferredTranscription = false; transcriptionID = r.id
        let download = downloadRequests.remove(r.id) != nil
        transcriptionTask = Task { await transcribe(r, download: download) }
    }
    func cancelTranscription() {
        deferredTranscription = false
        if let id = transcriptionID { updateTranscription(id, state: .cancelled, notice: "Transcription cancelled. Audio retained; retry from this recording.") }
        transcriptionTask?.cancel()
    }
    func prioritizeCapture() { snapshotTask?.cancel(); deferTranscription(); cancelCleanup() }
    func deferTranscription() {
        if let id = transcriptionID {
            deferredTranscription = true
            updateTranscription(id, state: .queued, notice: "Transcription deferred for capture or app suspension. Audio retained.")
            transcriptionTask?.cancel()
        }
    }
    func background() { recorder?.isMeteringEnabled = false; levels.pause(); snapshotTask?.cancel(); suspended = true; deferTranscription(); cancelCleanup() }
    func foreground() {
        suspended = false; recorder?.isMeteringEnabled = true; levels.pause()
        refreshRoute(); runRetention(); resumeTranscriptionQueue(); resumeUploadSnapshots()
        #if DEBUG && targetEnvironment(simulator)
        if syntheticFeedback { showSyntheticCaptureFeedback() }
        #endif
    }
    private func transcribe(_ r: Recording, download: Bool) async {
        transcribing = true
        defer {
            transcribing = false; transcriptionID = nil; transcriptionTask = nil
            runRetention(); resumeTranscriptionQueue(); resumeUploadSnapshots()
        }
        do {
            try Task.checkCancellation()
            guard active == nil, !suspended else { throw CancellationError() }
            updateTranscription(r.id, state: .running, notice: "Transcribing on device…")
            let audio: URL
            if let audioExport { audio = try await audioExport(r) }
            else { audio = try await export(r) }
            defer { try? FileManager.default.removeItem(at: audio) }
            try Task.checkCancellation()
            let text = try await speech([audio], download)
            try Task.checkCancellation()
            guard var edited = recordings.first(where: { $0.id == r.id }) else { return }
            // Keep edits/drafts if the user retries speech recognition.
            edited.transcript = text.text; edited.transcriptionLocale = text.locale
            if edited.correctedTranscript == nil { edited.correctedTranscript = TranscriptCorrections.apply(text.text, vocabulary: vocabulary) }
            edited.transcriptionState = .complete; edited.transcriptionNotice = "Transcription complete."
            try persist(edited); replace(edited)
        } catch is CancellationError {
            if deferredTranscription { updateTranscription(r.id, state: .queued, notice: "Deferred; will retry when app is active and capture is idle.") }
        } catch {
            if Task.isCancelled {
                if deferredTranscription { updateTranscription(r.id, state: .queued, notice: "Deferred; audio retained.") }
            } else { updateTranscription(r.id, state: .failed, notice: error.localizedDescription) }
        }
    }
    func resumeUploadSnapshots() {
        guard !capturePending, snapshotTask == nil, transcriptionTask == nil, active == nil, !suspended, !transcribing else { return }
        guard let intent = transfers.intents.first(where: { intent in intent.notice == nil && recordings.contains { $0.id == intent.recordingID && $0.deliveryReady } }), let r = recordings.first(where: { $0.id == intent.recordingID }) else { return }
        upload(r, destination:intent.destination, route:intent.route)
    }
    var preparingUpload: Bool { snapshotTask != nil }
    func upload(_ r: Recording, destination: NStackDestination? = nil, route: DialogueRouteSnapshot? = nil) {
        guard snapshotTask == nil, transcriptionTask == nil, active == nil, !suspended, !busy else { message = "Upload deferred while capture or local work is active."; return }
        if let job = transfers.jobs.last(where: { $0.recordingID == r.id && $0.state != "cancelled" }) {
            if job.state == "failed" || job.state.hasPrefix("paused_") { transfers.retry(job.id) }
            return
        }
        let immutableRoute = route ?? r.dialogueRoute ?? transfers.intents.first(where: { $0.recordingID == r.id })?.route
        guard let d = immutableRoute?.destination ?? destination ?? transfers.intents.first(where: { $0.recordingID == r.id })?.destination ?? transfers.destination else { message = "Configure NStack first."; return }
        snapshotTask = Task {
            busy = true
            defer { busy = false; snapshotTask = nil; runRetention(); resumeTranscriptionQueue(); resumeUploadSnapshots() }
            do {
                guard r.deliveryReady else { throw NStackError.incomplete }
                let corrected = r.deliveryContent == .audioOnly ? "" : TranscriptCorrections.apply(r.reviewText, vocabulary:vocabulary)
                let audio: URL
                if let audioExport { audio = try await audioExport(r) } else { audio = try await export(r, requireComplete:true) }
                defer { try? FileManager.default.removeItem(at:audio) }
                try Task.checkCancellation()
                try transfers.enqueue(r,route:immutableRoute ?? DialogueRouteSnapshot(mode:.normal,destination:d,threadID:nil),audio:audio,corrected:corrected)
            } catch { if !(error is CancellationError) { transfers.snapshotFailed(r.id,error:error); report(error) } }
        }
    }
    func uploadAudioOnly(_ original: Recording) {
        guard var r = recordings.first(where: { $0.id == original.id }), r.state == .saved else { return }
        if transcriptionID == r.id { cancelTranscription() }
        r.deliveryContent = .audioOnly
        r.transcriptionState = .none
        r.transcriptionNotice = "Local transcription skipped. Audio will be transcribed by the agent/server."
        r.events.append("Prepared for audio-first delivery without local transcription.")
        do {
            try persist(r); replace(r)
            if !transfers.jobs.contains(where: { $0.recordingID == r.id && $0.state != "cancelled" }),
               !transfers.rememberNew(r, force: true) {
                message = "Audio saved, but it cannot publish until an NStack destination is configured."
            }
            upload(r)
        } catch { report(error) }
    }
    func saveVocabulary(_ rules: [VocabularyCorrection]) {
        guard vocabularyReadable else { message = "Vocabulary file unreadable. File retained; cannot overwrite it."; return }
        do { try vocabularyStore?.save(rules); vocabulary = rules } catch { report(error) }
    }
    func editTranscript(_ id: UUID, text: String) {
        guard var r = recordings.first(where: { $0.id == id }) else { return }
        r.correctedTranscript = text; r.cleanupDraft = nil
        do { try persist(r); replace(r) } catch { report(error) }
    }
    func applyVocabulary(_ id: UUID) {
        guard let r = recordings.first(where: { $0.id == id }) else { return }
        editTranscript(id, text: TranscriptCorrections.apply(r.reviewText, vocabulary: vocabulary))
    }
    func cleanUp(_ id: UUID) {
        guard cleanupTask == nil, active == nil, let r = recordings.first(where: { $0.id == id }), !r.reviewText.isEmpty else { return }
        cleanupID = id
        cleaning = true; cleanupStatus = "Cleaning up on device…"
        let source = r.reviewText; let rules = vocabulary
        cleanupTask = Task {
            defer { cleanupTask = nil; cleanupID = nil; cleaning = false; runRetention() }
            do {
                let draft: String
                if let cleanup { draft = try await cleanup(source, rules) }
                else { draft = try await LocalCleanup.draft(source, vocabulary: rules) { [weak self] progress in self?.cleanupStatus = progress } }
                try Task.checkCancellation()
                guard var latest = recordings.first(where: { $0.id == id }), latest.reviewText == source else { cleanupStatus = "Transcript changed; request a new draft."; return }
                latest.cleanupDraft = draft; try persist(latest); replace(latest)
                cleanupStatus = "Draft ready. Review before accepting."
            } catch { cleanupStatus = Task.isCancelled ? "Cleanup cancelled. Transcript retained." : error.localizedDescription }
        }
    }
    func cancelCleanup() { cleanupTask?.cancel() }
    func reviewDraft(_ id: UUID, accept: Bool) {
        guard var r = recordings.first(where: { $0.id == id }) else { return }
        if accept, let draft = r.cleanupDraft { r.correctedTranscript = draft }
        r.cleanupDraft = nil
        do { try persist(r); replace(r) } catch { report(error) }
    }
    func report(_ error: Error) { message = error.localizedDescription }
}

enum RecorderError: LocalizedError {
    case storage, capture, unavailable, modelRequired
    var errorDescription: String? {
        switch self {
        case .storage: "Not enough free storage (20 MB reserve). Recording stopped; saved audio retained."
        case .capture: "Audio operation failed. Saved segments retained; an incomplete segment may need recovery."
        case .unavailable: "Local transcription is unavailable on this OS, device or language. Audio remains available."
        case .modelRequired: "Language model is not installed. Use Download model & transcribe to explicitly download it from Apple. Audio stays on this device."
        }
    }
}

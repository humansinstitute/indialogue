package com.wingmanbefree.indialogue

import android.app.Application
import android.content.Intent
import android.media.MediaPlayer
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import java.io.File
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString

class DialogueApp : Application() {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    lateinit var root: File
        private set

    lateinit var library: Library
        private set

    lateinit var identity: Identity
        private set

    lateinit var models: Models
        private set

    lateinit var transfers: Transfers
        private set

    val recordings = MutableStateFlow<List<Recording>>(emptyList())
    val notice = MutableStateFlow("")
    val modelStatus = MutableStateFlow("")
    val active = MutableStateFlow<String?>(null)
    val capturePending = MutableStateFlow(false)
    val elapsed = MutableStateFlow(0L)
    val levels = MutableStateFlow<List<Float>>(emptyList())
    val input = MutableStateFlow(0)
    val route = MutableStateFlow("System default")
    val foreground = MutableStateFlow(false)
    val revision = MutableStateFlow(0)
    var preferredInput: InputPreference? by mutableStateOf(null)
        private set

    var rules: List<Rule> by mutableStateOf(emptyList())
        private set

    var retention by mutableStateOf(Retention())
        private set

    private var settingsReadable = true
    private var vocabularyReadable = true
    private var speechStorageBlocked = false
    private var worker: Job? = null
    private var cleanupJob: Job? = null
    private var modelJob: Job? = null
    private var transferJob: Job? = null
    private var snapshotJob: Job? = null
    var cleaningId: String? by mutableStateOf(null)
        private set

    var playingId: String? by mutableStateOf(null)
        private set

    var sharingId: String? by mutableStateOf(null)
        private set

    private var player: MediaPlayer? = null
    private var stoppingJobs = false
    private var speechOwner: String? = null
    private var transferOwner: String? = null
    private var playbackGeneration = 0L
    internal var speechEngine: suspend (List<File>) -> String = { models.transcribe(it) }
    internal var transferEngine: suspend (Transfer, NStackAPI, () -> Unit) -> Unit =
        { job, api, gate ->
            transfers.send(job, api, gate)
        }
    internal var playbackExport: suspend (String) -> File = { id ->
        withContext(Dispatchers.IO) { export(id) }
    }

    override fun onCreate() {
        super.onCreate()
        root = File(noBackupFilesDir, "dialogue").apply { mkdirs() }
        library = Library(File(root, "recordings"))
        identity =
            Identity(
                File(root, "identity/vault.json"),
                KeystoreSecret(File(root, "identity/installation.json")),
            )
        models = Models(File(root, "models")) { s -> modelStatus.value = s }
        transfers = Transfers(File(root, "transfers"))
        try {
            File(root, "vocabulary.json").readTextOrNull()?.let {
                rules = codec.decodeFromString(it)
            }
        } catch (e: Exception) {
            vocabularyReadable = false
            notice.value = "Vocabulary unreadable; retained: ${e.message}"
        }
        try {
            File(root, "retention.json").readTextOrNull()?.let {
                retention = codec.decodeFromString(it)
            }
        } catch (e: Exception) {
            settingsReadable = false
            notice.value = "Retention settings unreadable; automatic deletion disabled."
        }
        try {
            File(root, "input.json").readTextOrNull()?.let {
                preferredInput = codec.decodeFromString(it)
            }
        } catch (e: Exception) {
            notice.value = "Microphone preference unreadable; using system default."
        }
        recordings.value = library.all(true)
        if (library.warnings.isNotEmpty()) notice.value = library.warnings.joinToString("\n")
        if (!transfers.readable)
            notice.value =
                "Upload ledger unreadable; uploads and retention disabled; files retained."
    }

    fun chooseInput(device: android.media.AudioDeviceInfo?) {
        val preference = device?.let {
            InputPreference(it.type, it.productName.toString(), it.address)
        }
        if (preference == null) {
            val file = File(root, "input.json")
            if (file.exists()) check(file.delete())
        } else atomic(File(root, "input.json"), codec.encodeToString(preference))
        preferredInput = preference
        input.value = device?.id ?: 0
        refresh()
    }

    fun preferredDevice(): android.media.AudioDeviceInfo? {
        val p = preferredInput ?: return null
        return getSystemService(android.media.AudioManager::class.java)
            .getDevices(android.media.AudioManager.GET_DEVICES_INPUTS)
            .firstOrNull {
                it.type == p.type && it.productName.toString() == p.name && it.address == p.address
            }
    }

    fun inputLabel(): String =
        preferredInput?.let {
            it.name +
                if (preferredDevice() == null) " unavailable · System default" else " · preference"
        } ?: "System default"

    fun refresh() {
        recordings.value = library.all()
        revision.value++
        if (library.warnings.isNotEmpty()) notice.value = library.warnings.joinToString("\n")
    }

    fun update(id: String, change: (Recording) -> Unit) {
        val r = library.get(id)
        check(r.state != "recording") { "Finish recording before editing this item." }
        change(r)
        library.save(r)
        refresh()
    }

    fun action(block: () -> Unit) {
        try {
            block()
            revision.value++
        } catch (e: Exception) {
            notice.value = e.message ?: "Operation failed; files retained."
        }
    }

    fun startCapture() {
        if (stoppingJobs || active.value != null || capturePending.value) return
        capturePending.value = true
        val previous = listOfNotNull(worker, cleanupJob, modelJob, transferJob, snapshotJob)
        prioritizeCapture()
        scope.launch {
            previous.forEach { it.join() }
            action {
                if (!foreground.value) {
                    capturePending.value = false
                    error("Return to the app to start microphone capture.")
                }
                try {
                    ContextCompat.startForegroundService(
                        this@DialogueApp,
                        Intent(this@DialogueApp, CaptureService::class.java),
                    )
                } catch (e: Exception) {
                    capturePending.value = false
                    throw e
                }
            }
        }
    }

    fun stopCapture() {
        startService(Intent(this, CaptureService::class.java).setAction("stop"))
    }

    fun prioritizeCapture() {
        stoppingJobs = true
        worker?.cancel()
        cleanupJob?.cancel()
        modelJob?.cancel()
        transferJob?.cancel()
        snapshotJob?.cancel()
        stopPlayback()
        levels.value = emptyList()
        scope.launch {
            worker?.join()
            cleanupJob?.join()
            modelJob?.join()
            transferJob?.join()
            snapshotJob?.join()
            stoppingJobs = false
        }
    }

    fun onForeground() {
        speechStorageBlocked = false
        foreground.value = true
        levels.value = emptyList()
        refresh()
        resume()
    }

    fun onBackground() {
        foreground.value = false
        levels.value = emptyList()
        worker?.cancel()
        cleanupJob?.cancel()
        modelJob?.cancel()
        transferJob?.cancel()
        snapshotJob?.cancel()
    }

    fun resume() {
        if (
            !foreground.value ||
                active.value != null ||
                stoppingJobs ||
                capturePending.value ||
                snapshotJob != null
        )
            return
        if (worker == null && cleanupJob == null && modelJob == null && !speechStorageBlocked) {
            val r = recordings.value.firstOrNull { it.speech == "queued" }
            if (r != null) {
                speechOwner = r.id
                worker = scope.launch {
                    try {
                        update(r.id) {
                            it.speech = "running"
                            it.notice = null
                        }
                        val text =
                            speechEngine(r.segments.map { File(library.directory(r.id), it) })
                        ensureActive()
                        update(r.id) {
                            it.raw = text
                            if (it.edited == null) it.edited = Corrections.apply(text, rules)
                            it.speech = "complete"
                            it.notice = null
                        }
                    } catch (e: Exception) {
                        try {
                            update(r.id) {
                                if (it.speech == "cancelled") return@update
                                it.speech = if (e is CancellationException) "queued" else "failed"
                                it.notice =
                                    if (e is CancellationException)
                                        "Deferred until foreground and idle capture."
                                    else e.message
                            }
                        } catch (statusError: Exception) {
                            speechStorageBlocked = true
                            notice.value =
                                "Cannot persist speech status; queue paused and audio retained. Fix storage and retry: ${statusError.message}"
                        }
                    } finally {
                        worker = null
                        speechOwner = null
                        refresh()
                        resume()
                    }
                }
                return
            }
        }
        if (worker != null || cleanupJob != null || modelJob != null) return
        val automatic =
            recordings.value.firstOrNull {
                it.autoDestination != null && it.speech == "complete" && it.state == "saved"
            }
        if (automatic != null) {
            makeSnapshot(automatic, automatic.autoDestination!!, true)
            return
        }
        if (transferJob == null && transfers.readable) {
            var changed = false
            transfers.jobs
                .filter { it.state == "queued" || it.state.startsWith("paused_") }
                .forEach {
                    val state =
                        when {
                            !identity.unlocked -> "paused_locked"
                            it.destination.signer != identity.npub() -> "paused_identity"
                            else -> "queued"
                        }
                    if (it.state != state) {
                        it.state = state
                        changed = true
                    }
                }
            if (changed)
                action {
                    transfers.persist()
                    revision.value++
                }
        }
        if (transferJob == null && identity.unlocked && transfers.readable) {
            val job =
                transfers.jobs.firstOrNull {
                    (it.state == "queued" || it.state.startsWith("paused_")) &&
                        it.destination.signer == identity.npub()
                }
            if (job != null) {
                transferOwner = job.id
                transferJob = scope.launch {
                    try {
                        val gate = {
                            check(
                                foreground.value &&
                                    active.value == null &&
                                    identity.unlocked &&
                                    identity.npub() == job.destination.signer
                            ) {
                                "Delivery deferred until foreground, idle capture and matching identity unlock."
                            }
                        }
                        transferEngine(job, NStackAPI(identity, gate), gate)
                    } catch (e: Exception) {
                        if (job.state != "cancelled") {
                            job.state =
                                if (e is CancellationException)
                                    when {
                                        !identity.unlocked -> "paused_locked"
                                        !foreground.value -> "paused_background"
                                        else -> "paused_capture"
                                    }
                                else "failed"
                            job.notice = e.message
                        }
                        action { transfers.persist() }
                    } finally {
                        transferJob = null
                        transferOwner = null
                        refresh()
                        resume()
                    }
                }
                return
            }
        }
        retain()
    }

    fun retrySpeech(id: String) {
        action {
            update(id) {
                check(it.state != "recording")
                it.speech = "queued"
                it.notice = null
            }
            speechStorageBlocked = false
            resume()
        }
    }

    fun cancelSpeech(id: String) {
        action {
            update(id) {
                it.speech = "cancelled"
                it.notice = "Transcription cancelled; audio retained."
            }
            val owned = if (speechOwner == id) worker else null
            owned?.cancel()
            scope.launch {
                owned?.join()
                if (worker === owned && owned != null) {
                    worker = null
                    speechOwner = null
                }
                resume()
            }
        }
    }

    fun download(kind: String) {
        if (
            modelJob != null ||
                worker != null ||
                cleanupJob != null ||
                active.value != null ||
                snapshotJob != null
        ) {
            notice.value = "Wait for current audio/model job or cancel it first."
            return
        }
        modelJob = scope.launch {
            try {
                models.download(kind)
            } catch (e: Exception) {
                modelStatus.value =
                    if (e is CancellationException)
                        "Download cancelled; no incomplete model installed."
                    else "Download failed: ${e.message}"
            } finally {
                modelJob = null
                refresh()
                resume()
            }
        }
    }

    fun cancelDownload() {
        modelJob?.cancel()
    }

    fun removeModel(kind: String) {
        action {
            check(
                worker == null && cleanupJob == null && modelJob == null && active.value == null
            ) {
                "Cancel and wait for current model/audio job first."
            }
            models.remove(kind)
            refresh()
        }
    }

    fun cleanup(id: String) {
        if (
            worker != null ||
                cleanupJob != null ||
                modelJob != null ||
                active.value != null ||
                snapshotJob != null
        ) {
            notice.value = "Wait for current audio/model job."
            return
        }
        val memory = android.app.ActivityManager.MemoryInfo()
        getSystemService(android.app.ActivityManager::class.java).getMemoryInfo(memory)
        if (memory.lowMemory || memory.availMem < 1_500_000_000L) {
            notice.value =
                "Cleanup unavailable: requires about 1.5 GiB available RAM. Original transcript retained."
            return
        }
        cleaningId = id
        val original = library.get(id).review
        cleanupJob = scope.launch {
            try {
                val draft = models.clean(original, rules)
                ensureActive()
                update(id) {
                    check(it.review == original) {
                        "Transcript edited during cleanup; draft discarded."
                    }
                    it.draft = draft
                    it.draftSource = sha(original.toByteArray())
                }
            } catch (e: Exception) {
                notice.value =
                    if (e is CancellationException) "Cleanup cancelled; original retained."
                    else "Cleanup failed: ${e.message}"
            } finally {
                cleanupJob = null
                cleaningId = null
                refresh()
                resume()
            }
        }
    }

    fun cancelCleanup() {
        cleanupJob?.cancel()
    }

    fun saveRules(next: List<Rule>) {
        check(vocabularyReadable) {
            "Vocabulary file unreadable; retained and cannot be overwritten."
        }
        atomic(File(root, "vocabulary.json"), codec.encodeToString(next))
        rules = next
        refresh()
    }

    fun saveRetention(policy: Retention) {
        atomic(File(root, "retention.json"), codec.encodeToString(policy))
        retention = policy
        settingsReadable = true
        refresh()
        retain()
    }

    fun retain() {
        if (
            !settingsReadable ||
                !foreground.value ||
                active.value != null ||
                worker != null ||
                cleanupJob != null ||
                transferJob != null ||
                modelJob != null ||
                !transfers.readable ||
                snapshotJob != null
        )
            return
        val protected =
            setOfNotNull(playingId, sharingId, cleaningId) +
                transfers.jobs
                    .filter { it.state !in setOf("sent", "cancelled") }
                    .map { it.recordingId }
        recordings.value
            .filter {
                retention.eligible(it, System.currentTimeMillis(), protected, transfers.readable)
            }
            .forEach { r ->
                try {
                    deleteLocal(r)
                } catch (e: Exception) {
                    notice.value =
                        "Retention deletion failed; retry at next safe check: ${e.message}"
                }
            }
        refresh()
    }

    private fun deleteLocal(r: Recording) {
        check(
            r.id != active.value &&
                r.id != playingId &&
                r.id != sharingId &&
                r.id != cleaningId &&
                r.speech !in setOf("queued", "running") &&
                !transfers.protects(r.id) &&
                r.autoDestination == null
        ) {
            "Recording has an active or unfinished job. Cancel it before deleting."
        }
        transfers.deleteFinished(r.id)
        File(cacheDir, "exports")
            .listFiles()
            .orEmpty()
            .filter { it.name.startsWith(r.id + "-") }
            .forEach { check(it.delete()) }
        check(library.directory(r.id).deleteRecursively())
    }

    fun delete(id: String) {
        action {
            deleteLocal(library.get(id))
            refresh()
        }
    }

    fun export(id: String): File {
        val r = library.get(id)
        val file = File(cacheDir, "exports/${r.id}-${uuid()}.m4a")
        val warnings =
            AudioExport.combine(r.segments.map { File(library.directory(id), it) }, file, true)
        if (warnings.isNotEmpty())
            notice.value = "Partial export omitted unreadable segments: ${warnings.joinToString()}"
        return file
    }

    fun share(id: String, deliver: (List<File>) -> Unit) {
        if (sharingId != null) return
        sharingId = id
        scope.launch {
            try {
                val files =
                    withContext(Dispatchers.IO) {
                        val r = library.get(id)
                        val audio = export(id)
                        val text = File(audio.parentFile, "${r.id}-${uuid()}.txt")
                        text.writeText(
                            "${r.title}\n\nReviewed transcript\n${r.review}\n\nOriginal transcript\n${r.raw.orEmpty()}"
                        )
                        listOf(audio, text)
                    }
                deliver(files)
            } catch (e: Exception) {
                notice.value = "Export failed: ${e.message}"
            } finally {
                sharingId = null
                refresh()
            }
        }
    }

    fun play(id: String) {
        if (active.value != null || capturePending.value || stoppingJobs) {
            notice.value = "Playback waits until capture is stopped."
            return
        }
        stopPlayback()
        val generation = playbackGeneration
        playingId = id
        scope.launch {
            try {
                val file = playbackExport(id)
                if (
                    playingId != id ||
                        playbackGeneration != generation ||
                        active.value != null ||
                        capturePending.value ||
                        stoppingJobs
                )
                    return@launch
                player =
                    MediaPlayer().apply {
                        setDataSource(file.absolutePath)
                        prepare()
                        setOnCompletionListener {
                            stopPlayback()
                            retain()
                        }
                        setOnErrorListener { _, _, _ ->
                            notice.value = "Playback failed; audio retained."
                            stopPlayback()
                            true
                        }
                        start()
                    }
                refresh()
            } catch (e: Exception) {
                if (playbackGeneration == generation) {
                    notice.value = "Playback failed: ${e.message}"
                    stopPlayback()
                }
            }
        }
    }

    fun stopPlayback() {
        playbackGeneration++
        player?.release()
        player = null
        playingId = null
        revision.value++
    }

    fun upload(id: String) {
        action {
            val r = library.get(id)
            val existing =
                transfers.jobs.lastOrNull { it.recordingId == id && it.state != "cancelled" }
            if (existing != null) {
                if (existing.state == "sent")
                    notice.value = "This recording has already been delivered."
                else retryUpload(existing)
                return@action
            }
            val d = r.autoDestination ?: transfers.destination ?: error("Configure NStack first.")
            makeSnapshot(r, d, r.autoDestination != null)
            resume()
            refresh()
        }
    }

    private fun makeSnapshot(r: Recording, d: Destination, automatic: Boolean) {
        if (snapshotJob != null || active.value != null) {
            notice.value = "Wait until capture/export is idle."
            return
        }
        snapshotJob = scope.launch {
            var success = false
            try {
                transfers.snapshotAsync(r, d, rules) { target, checkpoint ->
                    AudioExport.combine(
                        r.segments.map { File(library.directory(r.id), it) },
                        target,
                        checkpoint = checkpoint,
                    )
                }
                if (automatic) update(r.id) { it.autoDestination = null }
                success = true
            } catch (e: Exception) {
                notice.value =
                    if (e is CancellationException)
                        "Snapshot deferred; original recording retained."
                    else "Snapshot failed: ${e.message}. Original retained; retry explicitly."
            } finally {
                snapshotJob = null
                refresh()
                if (success) resume()
            }
        }
    }

    fun retryUpload(job: Transfer) {
        action {
            check(transferOwner != job.id) { "This upload is already running." }
            transfers.retry(job)
            refresh()
            resume()
        }
    }

    fun cancelUpload(job: Transfer) {
        action {
            transfers.cancel(job)
            val owned = if (transferOwner == job.id) transferJob else null
            owned?.cancel()
            scope.launch {
                owned?.join()
                if (transferJob === owned && owned != null) {
                    transferJob = null
                    transferOwner = null
                }
                refresh()
                resume()
            }
        }
    }

    fun lock() {
        transferJob?.cancel()
        snapshotJob?.cancel()
        identity.lock()
        revision.value++
    }
}

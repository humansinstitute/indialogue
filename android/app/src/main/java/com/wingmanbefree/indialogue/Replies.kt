package com.wingmanbefree.indialogue

import android.media.MediaPlayer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.compose.runtime.*
import java.io.File
import java.net.URLEncoder
import kotlinx.coroutines.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.*

@Serializable
data class DialogueReply(val id: String, val body: String, val audioObjectId: String? = null)

/** Reply parsing is independent of playback and ignores recorder echoes and deleted records. */
fun parseReply(message: JsonObject): DialogueReply? {
    if (message.text("record_state") == "deleted" || message["deleted_at"]?.let { it != JsonNull } == true) return null
    val metadata = message["metadata"] as? JsonObject
    if (metadata?.get("recorder")?.let { it != JsonNull } == true) return null
    val id = message.text("id") ?: error("Reply missing identity")
    val body = message.text("body") ?: error("Reply missing body")
    val attachments = (message["attachments"] ?: metadata?.get("attachments")) as? JsonArray
    val audio = attachments?.map { it.jsonObject }?.firstOrNull {
        (it.text("mime_type") ?: it.text("content_type")).orEmpty().startsWith("audio/", true)
    }?.text("storage_object_id")
    audio?.let { java.util.UUID.fromString(it) }
    return DialogueReply(id, body, audio)
}

class ReplyController(private val app: DialogueApp) {
    var replies by mutableStateOf<Map<String, DialogueReply>>(emptyMap())
        private set
    var notice by mutableStateOf("")
        private set
    var playing by mutableStateOf<String?>(null)
        private set
    var refreshing by mutableStateOf(false)
        private set
    var autoListen by mutableStateOf(true)
        private set
    private val playedFile get() = File(app.root, "reply-played.json")
    private val played = linkedSetOf<String>()
    private var playedReadable = true
    private var audioCache: File? = null
    private var player: MediaPlayer? = null
    private var speech: TextToSpeech? = null
    private var playback: Job? = null
    private var generation = 0L
    private var ready = false
    private var initialization: VoiceInitialization? = null
    internal var loadMessages: suspend (Transfer) -> List<JsonObject> = { job ->
        val d = job.destination
        val thread = checkNotNull(job.threadId)
        val base = "/api/v4/flightdeck-pg/workspaces/${d.workspace}/channels/${d.channel}/messages"
        NStackAPI(app.identity, { gate(job) }).list(d.origin, base + "?thread_id=" + URLEncoder.encode(thread, "UTF-8") + "&effective_transcript=true", "messages", d.appNpub)
    }
    internal var loadAudio: suspend (Transfer, String, File) -> Unit = { job, objectId, file ->
        NStackAPI(app.identity, { gate(job) }).downloadAudio(job.destination, objectId, file)
    }
    var voices by mutableStateOf<List<android.speech.tts.Voice>>(emptyList())
        private set
    var selectedVoice by mutableStateOf<String?>(null)
        private set
    private val voiceFile get() = File(app.root, "reply-selected-voice.json")
    private val settings get() = File(app.root, "reply-voice.json")

    init {
        try {
            if (playedFile.exists()) played.addAll(codec.decodeFromString<List<String>>(playedFile.readText()).takeLast(200))
            if (voiceFile.exists()) selectedVoice = codec.decodeFromString<String?>(voiceFile.readText())
        } catch (_: Exception) { playedReadable = false; notice = "Reply playback history unreadable; automatic playback paused." }
        try { if (settings.exists()) autoListen = codec.decodeFromString<Boolean>(settings.readText()) }
        catch (_: Exception) { notice = "Reply voice settings unreadable; retained." }
    }

    fun saveAutoListen(enabled: Boolean) {
        app.action { atomic(settings, codec.encodeToString(enabled)); autoListen = enabled }
    }

    fun key(job: Transfer) = conversationKey(job)
    fun latest() = app.transfers.jobs.filter { it.route != null && it.state != "cancelled" && app.identity.unlocked && it.destination.signer == app.identity.npub() }
        .groupBy { key(it) }.values.map { it.last() }.takeLast(5).reversed()

    fun gate(job: Transfer) {
        check(app.foreground.value && app.active.value == null && !app.capturePending.value &&
            app.identity.unlocked && app.identity.npub() == job.destination.signer) {
            "Replies require foreground, idle recording and the matching unlocked identity."
        }
    }

    suspend fun refresh(requested: Transfer, autoPlay: Boolean = false) {
        val job = acceptedConversation(app.transfers.jobs, requested) ?: return
        if (refreshing) return
        refreshing = true
        try {
            gate(job)
            app.diagnostics.record(DiagnosticEvent.ReplyRefresh)
            val d = job.destination
            val own = app.transfers.jobs.filter { key(it) == key(job) }.mapNotNull { it.messageId }.toSet()
            val rows = loadMessages(job)
            val reply = rows.filter { it.text("id") !in own }.mapNotNull(::parseReply).lastOrNull()
            gate(job)
            if (reply != null) {
                app.diagnostics.record(DiagnosticEvent.ReplyReceived)
                replies = replies + (key(job) to reply)
                notice = ""
                val playedKey = "${d.signer}/${key(job)}/${reply.id}"
                if (autoPlay && autoListen && playedReadable && playedKey !in played) {
                    played.add(playedKey)
                    while (played.size > 200) played.remove(played.first())
                    atomic(playedFile, codec.encodeToString(played.toList()))
                    listen(job, reply)
                }
            } else notice = "No new reply yet."
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { app.diagnostics.record(DiagnosticEvent.ReplyFailed); notice = e.message ?: "Reply refresh failed; retry available." }
        finally { refreshing = false }
    }

    fun stop() {
        generation++
        playback?.cancel(); playback = null
        player?.release(); player = null
        speech?.stop()
        audioCache?.delete(); audioCache = null
        playing = null
    }

    fun listen(job: Transfer, reply: DialogueReply) {
        if (playing == reply.id) { stop(); return }
        stop()
        val token = generation
        playing = reply.id
        playback = app.scope.launch {
            try {
                gate(job)
                app.stopPlayback()
                if (reply.audioObjectId != null) {
                    val file = File(app.cacheDir, "reply-${uuid()}.audio")
                    audioCache = file
                    try {
                        loadAudio(job, reply.audioObjectId, file)
                        gate(job)
                        if (token != generation) { file.delete(); return@launch }
                        player = MediaPlayer().apply {
                            setDataSource(file.absolutePath); prepare()
                            setOnCompletionListener { stop(); file.delete() }
                            setOnErrorListener { _, _, _ -> notice = "Reply audio playback failed. Retry Listen."; stop(); true }
                            start()
                        }
                    } catch (e: Exception) { file.delete(); throw e }
                } else {
                    check(reply.body.isNotBlank()) { "Reply has no readable text or audio." }
                    prepareVoices()
                    check(ready) { "Android text-to-speech unavailable. Install a voice in system settings; reply text is retained." }
                    gate(job)
                    if (token != generation) return@launch
                    applyVoice()
                    speech!!.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                        override fun onStart(id: String?) {}
                        override fun onDone(id: String?) { app.scope.launch { if (token == generation && id == reply.id) stop() } }
                        @Deprecated("Platform callback") override fun onError(id: String?) {
                            app.scope.launch { if (token == generation) { notice = "Speech playback failed; reply text retained."; stop() } }
                        }
                    })
                    val chunks = reply.body.chunked((TextToSpeech.getMaxSpeechInputLength() - 100).coerceAtLeast(1))
                    chunks.forEachIndexed { index, text ->
                        check(speech!!.speak(text, if (index == 0) TextToSpeech.QUEUE_FLUSH else TextToSpeech.QUEUE_ADD,
                            null, if (index == chunks.lastIndex) reply.id else "${reply.id}/$index") == TextToSpeech.SUCCESS) { "Android voice could not read this reply." }
                    }
                }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { if (token == generation) { notice = e.message.orEmpty(); stop() } }
        }
    }

    suspend fun prepareVoices() {
        val pending = initialization ?: VoiceInitialization().also { pending ->
            initialization = pending
            speech = TextToSpeech(app) { pending.complete(it == TextToSpeech.SUCCESS) }
        }
        ready = pending.await()
        if (!ready) {
            speech?.shutdown(); speech = null; initialization = null
            error("Android text-to-speech initialization failed. Retry or install an offline voice.")
        }
        if (ready) voices = speech!!.voices.orEmpty().filter { !it.isNetworkConnectionRequired }.sortedBy { it.name }
    }

    fun chooseVoice(name: String?) {
        app.action {
            require(name == null || voices.any { it.name == name })
            atomic(voiceFile, codec.encodeToString(name))
            selectedVoice = name
        }
    }

    private fun applyVoice() {
        val voice = voices.firstOrNull { it.name == selectedVoice } ?: speech?.defaultVoice?.takeUnless { it.isNetworkConnectionRequired }
            ?: voices.firstOrNull()
        check(voice != null) { "No offline Android voice installed. Download offline voice data in Android settings." }
        check(speech!!.setVoice(voice) == TextToSpeech.SUCCESS) { "Selected voice unavailable; choose another installed voice." }
    }

    fun preview() {
        stop()
        playback = app.scope.launch {
            try {
                prepareVoices(); applyVoice()
                check(app.foreground.value && app.active.value == null && !app.capturePending.value) { "Voice preview requires idle foreground capture." }
                speech!!.speak("This is your reply voice in In Dialogue.", TextToSpeech.QUEUE_FLUSH, null, "preview")
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { notice = e.message.orEmpty() }
        }
    }

    fun responseRoute(job: Transfer, reply: DialogueReply?): DialogueRoute? =
        job.route?.takeIf { job.threadId != null }?.copy(threadId = job.threadId, respondingToReplyId = reply?.id)
}

/** Independent of the waiting coroutine: cancelling one caller cannot poison TTS initialization. */
internal class VoiceInitialization {
    private val result = CompletableDeferred<Boolean>()
    fun complete(success: Boolean) { result.complete(success) }
    suspend fun await(): Boolean = result.await()
}

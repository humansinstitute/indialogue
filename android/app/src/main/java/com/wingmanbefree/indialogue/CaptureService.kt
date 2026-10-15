package com.wingmanbefree.indialogue

import android.Manifest
import android.app.*
import android.content.*
import android.content.pm.PackageManager
import android.media.*
import android.os.*
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import java.io.File
import java.nio.ByteBuffer
import kotlin.math.log10
import kotlinx.coroutines.*

class CaptureService : Service() {
    private val app
        get() = application as DialogueApp

    private var recorder: MediaRecorder? = null
    private var record: Recording? = null
    private var segmentStart = 0L
    private var start = 0L
    private var timer: Job? = null
    private var focus: AudioFocusRequest? = null
    private var wake: PowerManager.WakeLock? = null
    private val audio
        get() = getSystemService(AudioManager::class.java)

    private val handler = Handler(Looper.getMainLooper())
    private val deviceCallback =
        object : AudioDeviceCallback() {
            override fun onAudioDevicesRemoved(devices: Array<out AudioDeviceInfo>) {
                if (
                    record != null &&
                        devices.any { it.id == recorder?.routedDevice?.id || it.id == lastRoute }
                )
                    stopCapture("Audio input disconnected; earlier segments retained.")
            }
        }
    private var lastRoute: Int? = null
    private val recordingCallback =
        object : AudioManager.AudioRecordingCallback() {
            override fun onRecordingConfigChanged(
                configs: MutableList<AudioRecordingConfiguration>
            ) {
                if (
                    Build.VERSION.SDK_INT >= 29 &&
                        recorder?.activeRecordingConfiguration?.isClientSilenced == true
                )
                    stopCapture("Android silenced microphone capture; earlier segments retained.")
            }
        }

    override fun onBind(intent: Intent?) = null

    override fun onCreate() {
        super.onCreate()
        audio.registerAudioDeviceCallback(deviceCallback, handler)
        audio.registerAudioRecordingCallback(recordingCallback, handler)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "stop") {
            stopCapture(null)
            return START_NOT_STICKY
        }
        if (record != null) return START_NOT_STICKY
        try {
            check(
                ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
                    PackageManager.PERMISSION_GRANTED
            ) {
                "Microphone permission required."
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel("capture", "Recording", NotificationManager.IMPORTANCE_LOW)
            )
            val stop =
                PendingIntent.getService(
                    this,
                    1,
                    Intent(this, CaptureService::class.java).setAction("stop"),
                    PendingIntent.FLAG_IMMUTABLE,
                )
            val open =
                PendingIntent.getActivity(
                    this,
                    0,
                    Intent(this, MainActivity::class.java),
                    PendingIntent.FLAG_IMMUTABLE,
                )
            startForeground(
                1,
                NotificationCompat.Builder(this, "capture")
                    .setSmallIcon(com.wingmanbefree.indialogue.R.drawable.ic_dialogue)
                    .setContentTitle("In Dialogue is recording")
                    .setContentText("Tap Stop and save to retain audio")
                    .setOngoing(true)
                    .setContentIntent(open)
                    .addAction(0, "Stop and save", stop)
                    .build(),
            )
            app.prioritizeCapture()
            check(app.root.usableSpace > 20 * 1024 * 1024) { "Storage below 20 MiB reserve." }
            val r =
                Recording(
                    title =
                        java.text
                            .SimpleDateFormat("d MMM yyyy HH:mm", java.util.Locale.getDefault())
                            .format(java.util.Date())
                )
            app.library.save(r)
            record = r
            app.active.value = r.id
            app.capturePending.value = false
            focus =
                AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build()
                    )
                    .setOnAudioFocusChangeListener {
                        if (it < 0) stopCapture("Audio interruption; earlier segments retained.")
                    }
                    .build()
            check(audio.requestAudioFocus(focus!!) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                "Audio input is busy."
            }
            wake =
                getSystemService(PowerManager::class.java)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "InDialogue:capture")
                    .apply { acquire(12 * 60 * 60 * 1000L) }
            start = SystemClock.elapsedRealtime()
            openSegment()
            app.refresh()
            timer =
                app.scope.launch {
                    while (isActive && record != null) {
                        delay(250)
                        try {
                            check(app.root.usableSpace > 20 * 1024 * 1024) {
                                "Storage below 20 MiB reserve."
                            }
                            val elapsed = SystemClock.elapsedRealtime() - start
                            app.elapsed.value = elapsed
                            val amplitude = recorder?.maxAmplitude ?: 0
                            val level =
                                if (amplitude <= 0) 0f
                                else
                                    ((20 * log10(amplitude / 32767.0) + 60) / 60)
                                        .toFloat()
                                        .coerceIn(0f, 1f)
                            if (app.foreground.value)
                                app.levels.value = (app.levels.value + level).takeLast(40)
                            reportRoute()
                            if (SystemClock.elapsedRealtime() - segmentStart >= 15000) {
                                closeSegment()
                                openSegment()
                            }
                        } catch (e: Exception) {
                            stopCapture("${e.message}; prior segments retained.")
                        }
                    }
                }
        } catch (e: Exception) {
            stopCapture("Cannot start recording: ${e.message}. Files retained.")
        }
        return START_NOT_STICKY
    }

    @Suppress("DEPRECATION")
    private fun openSegment() {
        val r = checkNotNull(record)
        val name = "segment-${r.segments.size}.m4a"
        r.segments += name
        app.library.save(r) // durable before opening file
        val m = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(this) else MediaRecorder()
        recorder = m
        m.setAudioSource(MediaRecorder.AudioSource.MIC)
        m.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
        m.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
        m.setAudioChannels(1)
        m.setAudioSamplingRate(44100)
        m.setAudioEncodingBitRate(96000)
        m.setOutputFile(File(app.library.directory(r.id), name).absolutePath)
        val preferred = app.preferredDevice()
        if (preferred != null) m.setPreferredDevice(preferred)
        m.setOnErrorListener { _, what, extra ->
            stopCapture("Recorder error $what/$extra; earlier segments retained.")
        }
        m.prepare()
        m.start()
        segmentStart = SystemClock.elapsedRealtime()
        handler.postDelayed({ if (recorder === m) reportRoute() }, 500)
    }

    private fun reportRoute() {
        val device = recorder?.routedDevice
        app.route.value =
            device?.let { "${it.productName} · ${inputType(it.type)}" } ?: "Android route pending"
        if (device != null && device.id != lastRoute) {
            lastRoute = device.id
            record?.let {
                it.events += "Actual input: ${app.route.value}"
                app.library.save(it)
            }
        }
    }

    private fun closeSegment() {
        val m = recorder ?: return
        recorder = null
        try {
            m.stop()
            record?.let {
                it.durationMs += SystemClock.elapsedRealtime() - segmentStart
                app.library.save(it)
            }
        } finally {
            m.release()
        }
    }

    private fun stopCapture(reason: String?) {
        timer?.cancel()
        timer = null
        var warning = reason
        try {
            closeSegment()
        } catch (e: Exception) {
            warning = (warning?.plus("\n") ?: "") + "Final segment may be unreadable: ${e.message}"
        }
        record?.let { r ->
            r.state = if (warning == null) "saved" else "interrupted"
            if (warning != null) {
                r.events += warning!!
                r.notice = warning
            } else {
                r.speech = "queued"
                r.autoDestination = app.transfers.destination?.takeIf { it.automatic }
            }
            try {
                app.library.save(r)
            } catch (e: Exception) {
                app.notice.value = "Manifest update failed; original files retained: ${e.message}"
            }
        }
        record = null
        app.active.value = null
        app.capturePending.value = false
        app.levels.value = emptyList()
        focus?.let { audio.abandonAudioFocusRequest(it) }
        focus = null
        wake?.let { if (it.isHeld) it.release() }
        wake = null
        if (warning != null) app.notice.value = warning!!
        app.refresh()
        app.resume()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        if (record != null) stopCapture("Recording service stopped; earlier audio retained.")
        audio.unregisterAudioDeviceCallback(deviceCallback)
        audio.unregisterAudioRecordingCallback(recordingCallback)
        super.onDestroy()
    }
}

fun inputType(type: Int) =
    when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_MIC -> "Built-in microphone"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "Bluetooth"
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "Headset"
        AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_USB_HEADSET -> "USB"
        else -> "Input $type"
    }

object AudioExport {
    fun combine(
        files: List<File>,
        output: File,
        allowPartial: Boolean = false,
        checkpoint: () -> Unit = {},
    ): List<String> {
        check(files.isNotEmpty()) { "No audio segments." }
        output.parentFile!!.mkdirs()
        val stage = File(output.parentFile, output.name + ".partial")
        var mux: MediaMuxer? = null
        var track = -1
        var offset = 0L
        var signature: String? = null
        val omitted = mutableListOf<String>()
        try {
            files.forEach { file ->
                checkpoint()
                val ex = MediaExtractor()
                try {
                    ex.setDataSource(file.absolutePath)
                    val t =
                        (0 until ex.trackCount).first {
                            ex.getTrackFormat(it)
                                .getString(MediaFormat.KEY_MIME)
                                ?.startsWith("audio/") == true
                        }
                    val format = ex.getTrackFormat(t)
                    val sig =
                        "${format.getString(MediaFormat.KEY_MIME)}:${format.getInteger(MediaFormat.KEY_SAMPLE_RATE)}:${format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)}"
                    if (signature != null)
                        check(signature == sig) { "Audio formats changed between segments." }
                    ex.selectTrack(t)
                    check(ex.sampleSize > 0) { "Empty audio segment" }
                    val firstTimestamp = ex.sampleTime
                    if (mux == null) {
                        mux =
                            MediaMuxer(
                                stage.absolutePath,
                                MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4,
                            )
                        track = mux!!.addTrack(format)
                        mux!!.start()
                        signature = sig
                    }
                    val buffer = ByteBuffer.allocate(1024 * 1024)
                    val info = MediaCodec.BufferInfo()
                    var last = 0L
                    while (true) {
                        checkpoint()
                        buffer.clear()
                        val n = ex.readSampleData(buffer, 0)
                        if (n < 0) break
                        last = (ex.sampleTime - firstTimestamp).coerceAtLeast(0)
                        check(ex.sampleFlags and MediaExtractor.SAMPLE_FLAG_ENCRYPTED == 0) {
                            "Encrypted audio cannot be exported."
                        }
                        val flags =
                            if (ex.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0)
                                MediaCodec.BUFFER_FLAG_KEY_FRAME
                            else 0
                        info.set(0, n, offset + last, flags)
                        mux!!.writeSampleData(track, buffer, info)
                        ex.advance()
                    }
                    offset += last + 23220
                } catch (e: Exception) {
                    if (e is CancellationException) throw e
                    if (!allowPartial)
                        throw IllegalStateException(
                            "Unreadable segment ${file.name}; complete export refused.",
                            e,
                        )
                    omitted += "${file.name}: ${e.message}"
                } finally {
                    ex.release()
                }
            }
            check(mux != null && offset > 0) { "No readable audio." }
            mux!!.stop()
            mux!!.release()
            mux = null
            check(stage.renameTo(output))
            return omitted
        } catch (e: Exception) {
            stage.delete()
            throw e
        } finally {
            runCatching { mux?.release() }
        }
    }
}

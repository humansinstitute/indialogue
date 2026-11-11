package com.wingmanbefree.indialogue

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString

/** Deliberately closed vocabulary. Never accept arbitrary operational strings or user content. */
@Serializable
enum class DiagnosticEvent { Foreground, Background, CaptureRequested, CaptureStarted, CaptureSaved, CaptureInterrupted, OperationFailed, ReplyRefresh, ReplyReceived, ReplyFailed, DeliveryStarted, DeliverySent, DeliveryFailed, IdentityLocked }

@Serializable
data class DiagnosticEntry(val at: Long, val event: DiagnosticEvent)

@Serializable
data class DiagnosticReport(val schemaVersion: Int = 1, val appVersion: String, val generatedAt: Long, val events: List<DiagnosticEntry>)

class Diagnostics(private val file: File, private val now: () -> Long = System::currentTimeMillis) {
    var readable = true
        private set
    private var entries = emptyList<DiagnosticEntry>()
    init {
        try {
            if (file.exists()) entries = codec.decodeFromString<List<DiagnosticEntry>>(file.readText())
        } catch (_: Exception) { readable = false }
    }
    fun recent(): List<DiagnosticEntry> {
        val current = now()
        return entries.filter { it.at in (current - 3_600_000)..current }.takeLast(500)
    }
    fun record(event: DiagnosticEvent) {
        if (!readable) return
        val next = (recent() + DiagnosticEntry(now(), event)).takeLast(500)
        try { atomic(file, codec.encodeToString(next)); entries = next }
        catch (_: Exception) { readable = false }
    }
    fun report(version: String): String {
        check(readable) { "Diagnostics log unreadable; retained. No report sent." }
        return codec.encodeToString(DiagnosticReport(appVersion = version, generatedAt = now(), events = recent()))
    }
}

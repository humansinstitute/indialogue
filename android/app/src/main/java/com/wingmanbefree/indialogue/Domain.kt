package com.wingmanbefree.indialogue

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.UUID
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

val codec = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
}

fun uuid() = UUID.randomUUID().toString()

fun ByteArray.hex() = joinToString("") { "%02x".format(it) }

fun String.unhex(): ByteArray {
    require(length % 2 == 0)
    return chunked(2).map { it.toInt(16).toByte() }.toByteArray()
}

fun sha(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).hex()

fun digest(file: File): String {
    val md = MessageDigest.getInstance("SHA-256")
    file.inputStream().use { stream ->
        val b = ByteArray(65536)
        while (true) {
            val n = stream.read(b)
            if (n < 0) break
            md.update(b, 0, n)
        }
    }
    return md.digest().hex()
}

fun atomic(file: File, text: String) {
    file.parentFile!!.mkdirs()
    val temp = File(file.parentFile, file.name + ".new")
    FileOutputStream(temp).use {
        it.write(text.toByteArray())
        it.fd.sync()
    }
    Files.move(
        temp.toPath(),
        file.toPath(),
        StandardCopyOption.ATOMIC_MOVE,
        StandardCopyOption.REPLACE_EXISTING,
    )
}

@Serializable
data class Recording(
    val id: String = uuid(),
    val created: Long = System.currentTimeMillis(),
    var title: String = "Recording",
    var state: String = "recording",
    val segments: MutableList<String> = mutableListOf(),
    var durationMs: Long = 0,
    val events: MutableList<String> = mutableListOf(),
    var raw: String? = null,
    var edited: String? = null,
    var draft: String? = null,
    var draftSource: String? = null,
    var speech: String = "none",
    var notice: String? = null,
    var autoDestination: Destination? = null,
) {
    val review: String
        get() = edited ?: raw.orEmpty()

    fun editReview(text: String) {
        edited = text
        draft = null
        draftSource = null
    }

    fun acceptDraft() {
        val text = checkNotNull(draft) { "No current draft." }
        check(draftSource == sha(review.toByteArray())) {
            "Draft is obsolete; generate cleanup again."
        }
        editReview(text)
    }

    fun rejectDraft() {
        draft = null
        draftSource = null
    }
}

@Serializable data class Rule(val id: String = uuid(), val heard: String, val replacement: String)

object Corrections {
    fun teach(rules: List<Rule>, heard: String, replacement: String): List<Rule> {
        val source = heard.trim()
        val target = replacement.trim()
        require(source.isNotEmpty() && target.isNotEmpty())
        val existing = rules.firstOrNull { it.heard.equals(source, true) }
        val updated = Rule(existing?.id ?: uuid(), source, target)
        return rules.filterNot { it.heard.equals(source, true) } + updated
    }

    fun adjust(replacement: String, source: String): String =
        when {
            source == source.uppercase() && source != source.lowercase() -> replacement.uppercase()
            source.firstOrNull()?.isUpperCase() == true &&
                source.drop(1) == source.drop(1).lowercase() ->
                replacement.replaceFirstChar { it.uppercase() }
            else -> replacement
        }

    fun words(text: String) =
        Regex("[\\p{L}\\p{N}_]+(?:['’][\\p{L}\\p{N}_]+)*").findAll(text).toList()

    fun apply(text: String, rules: List<Rule>): String {
        val chosen = mutableListOf<Pair<IntRange, String>>()
        rules
            .filter { it.heard.isNotBlank() }
            .sortedWith(compareByDescending<Rule> { it.heard.length }.thenBy { it.id })
            .forEach { rule ->
                Regex(
                        "(?<![\\p{L}\\p{N}_])${Regex.escape(rule.heard)}(?![\\p{L}\\p{N}_])",
                        RegexOption.IGNORE_CASE,
                    )
                    .findAll(text)
                    .forEach { m ->
                        if (
                            chosen.none {
                                it.first.first <= m.range.last && m.range.first <= it.first.last
                            }
                        )
                            chosen += m.range to adjust(rule.replacement, m.value)
                    }
            }
        var result = text
        chosen
            .sortedByDescending { it.first.first }
            .forEach { (range, replacement) -> result = result.replaceRange(range, replacement) }
        return result
    }

    fun occurrence(text: String, range: IntRange, replacement: String): String {
        require(words(text).any { it.range == range }) {
            "Transcript changed; select the word again."
        }
        return text.replaceRange(range, adjust(replacement, text.substring(range)))
    }
}

class Library(val root: File) {
    val warnings = mutableListOf<String>()

    init {
        root.mkdirs()
    }

    fun directory(id: String): File {
        UUID.fromString(id)
        return File(root, id)
    }

    @Synchronized
    fun save(r: Recording) {
        require(r.segments.all { Regex("segment-[0-9]+\\.m4a").matches(it) })
        atomic(File(directory(r.id), "manifest.json"), codec.encodeToString(r))
    }

    @Synchronized
    fun get(id: String): Recording =
        codec.decodeFromString(File(directory(id), "manifest.json").readText())

    @Synchronized
    fun all(recover: Boolean = false): List<Recording> {
        warnings.clear()
        return root
            .listFiles()
            .orEmpty()
            .filter { it.isDirectory }
            .mapNotNull { dir ->
                try {
                    val r = codec.decodeFromString<Recording>(File(dir, "manifest.json").readText())
                    require(r.id == dir.name)
                    require(r.durationMs >= 0 && r.created >= 0)
                    require(r.state in setOf("recording", "saved", "interrupted"))
                    require(
                        r.speech in
                            setOf("none", "queued", "running", "complete", "failed", "cancelled")
                    )
                    require(r.segments.all { Regex("segment-[0-9]+\\.m4a").matches(it) })
                    if (recover) {
                        var changed = false
                        if (r.state == "recording") {
                            r.state = "interrupted"
                            r.events +=
                                "Recovered after process exit; last segment may be incomplete. All segment references retained."
                            changed = true
                        }
                        if (r.speech == "running") {
                            r.speech = "queued"
                            changed = true
                        }
                        if (changed) save(r)
                    }
                    r
                } catch (e: Exception) {
                    warnings += "Unreadable folder ${dir.name}; audio retained. ${e.message}"
                    null
                }
            }
            .sortedByDescending { it.created }
    }
}

@Serializable
data class Retention(val enabled: Boolean = false, val days: Int = 30) {
    init {
        require(days in 1..3650) { "Enter whole days from 1 to 3650." }
    }

    fun eligible(
        r: Recording,
        now: Long,
        protected: Set<String>,
        ledgerReadable: Boolean,
    ): Boolean =
        enabled &&
            ledgerReadable &&
            r.id !in protected &&
            r.state != "recording" &&
            r.speech !in setOf("queued", "running") &&
            r.autoDestination == null &&
            now >= r.created &&
            now - r.created >= days * 86_400_000L
}

@Serializable data class InputPreference(val type: Int, val name: String, val address: String)

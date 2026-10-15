package com.wingmanbefree.indialogue

import java.io.File
import java.net.URI
import java.net.URLEncoder
import java.util.Base64
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody

@Serializable
data class Destination(
    val origin: String,
    val signer: String,
    val workspace: String,
    val workspaceLabel: String,
    val appNpub: String,
    val channel: String,
    val channelLabel: String,
    val prompt: String,
    val automatic: Boolean = false,
    val recipient: String? = null,
    val recipientLabel: String? = null,
) {
    fun validate() {
        NStackAPI.origin(origin)
        UUID.fromString(workspace)
        UUID.fromString(channel)
        require(Bech32.validPublic(signer) && Bech32.validPublic(appNpub) && prompt.isNotBlank())
        if (recipient != null)
            require(
                Bech32.validPublic(recipient) &&
                    !recipientLabel.isNullOrBlank() &&
                    recipientLabel.none { it in "[]()\n\r" }
            ) {
                "Invalid canonical agent identity or label."
            }
    }
}

@Serializable
data class TransferFile(
    val name: String,
    val mime: String,
    val size: Long,
    val checksum: String,
    var objectId: String? = null,
    var uploadUrl: String? = null,
    var preparing: Boolean = false,
    var complete: Boolean = false,
)

@Serializable
data class Transfer(
    val id: String = uuid(),
    val recordingId: String,
    val destination: Destination,
    val title: String,
    val body: String,
    val files: List<TransferFile>,
    var state: String = "queued",
    var notice: String? = null,
    var messageId: String? = null,
)

@Serializable
data class Ledger(
    val destination: Destination? = null,
    val jobs: MutableList<Transfer> = mutableListOf(),
)

data class Choice(val id: String, val label: String, val app: String = "")

fun JsonObject.text(key: String): String? =
    (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

fun JsonObject.rows(key: String): List<JsonObject> =
    (this[key] as? JsonArray)?.map { it.jsonObject } ?: error("Missing $key in server response")

fun jsonObject(vararg pairs: Pair<String, JsonElement>) = JsonObject(pairs.toMap())

class NStackAPI(
    private val identity: Identity,
    private val gate: () -> Unit = {},
    val client: OkHttpClient =
        OkHttpClient.Builder()
            .followRedirects(false)
            .followSslRedirects(false)
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(45, TimeUnit.SECONDS)
            .build(),
) {
    companion object {
        fun origin(value: String): String {
            val u = URI(value.trim())
            require(
                u.scheme == "https" &&
                    u.host != null &&
                    u.userInfo == null &&
                    u.rawQuery == null &&
                    u.fragment == null &&
                    u.path in listOf("", "/")
            ) {
                "Use an HTTPS origin without credentials, path, query or fragment."
            }
            return u.toString().trimEnd('/')
        }

        fun byteCount(value: JsonElement?): Long {
            val p = value as? JsonPrimitive ?: error("Invalid storage size metadata")
            val s = p.content
            require(Regex("[0-9]+").matches(s)) { "Invalid storage size metadata" }
            return s.toLongOrNull() ?: error("Storage size overflow")
        }

        fun validateMetadata(meta: JsonObject, file: TransferFile) {
            check(!meta.text("completed_at").isNullOrBlank()) {
                "Storage completion not confirmed."
            }
            check(byteCount(meta["size_bytes"]) == file.size) { "Remote size mismatch" }
            val hash = meta.text("sha256_hex") ?: error("Missing checksum")
            require(Regex("[0-9a-fA-F]{64}").matches(hash))
            check(hash.equals(file.checksum, true)) { "Remote checksum mismatch" }
        }

        fun authTags(url: String, method: String, bytes: ByteArray?) =
            listOf(listOf("u", url), listOf("method", method)) +
                (bytes?.let { listOf(listOf("payload", sha(it))) } ?: emptyList())
    }

    private suspend fun execute(request: Request): ByteArray =
        withContext(Dispatchers.IO) {
            gate()
            val call = client.newCall(request)
            val watcher = launch {
                try {
                    awaitCancellation()
                } finally {
                    call.cancel()
                }
            }
            try {
                call.execute().use { response ->
                    check(response.code in 200..299) {
                        "NStack HTTP ${response.code}; files retained. Redirects refused."
                    }
                    val data = checkNotNull(response.body).bytes()
                    currentCoroutineContext().ensureActive()
                    gate()
                    data
                }
            } finally {
                watcher.cancel()
            }
        }

    suspend fun request(
        origin: String,
        path: String,
        app: String? = null,
        method: String = "GET",
        body: JsonObject? = null,
    ): JsonObject {
        require(path.startsWith("/api/v4/") && !path.contains("..") && !path.contains('#'))
        val url = (origin(origin) + path).toHttpUrl().toString()
        val bytes = body?.toString()?.toByteArray()
        gate()
        val event = identity.sign(27235, authTags(url, method, bytes), "")
        val b =
            Request.Builder()
                .url(url)
                .header(
                    "Authorization",
                    "Nostr " + Base64.getEncoder().encodeToString(event.toString().toByteArray()),
                )
        if (app != null) b.header("x-flightdeck-pg-app-npub", app)
        b.method(method, bytes?.toRequestBody("application/json".toMediaType()))
        return codec.parseToJsonElement(execute(b.build()).toString(Charsets.UTF_8)).jsonObject
    }

    suspend fun put(file: File, url: String, d: Destination, f: TransferFile) {
        val uri = URI(url)
        val pinned = URI(origin(d.origin))
        require(uri.userInfo == null && uri.fragment == null)
        if (
            uri.host == pinned.host &&
                uri.path == "/api/v4/storage/${f.objectId}" &&
                uri.query == null &&
                uri.scheme in listOf("https", "http")
        ) {
            check(f.size <= 8 * 1024 * 1024) {
                "JSON storage fallback limited to 8 MiB; presigned storage required."
            }
            request(
                d.origin,
                uri.path,
                method = "PUT",
                body =
                    buildJsonObject {
                        put("base64_data", Base64.getEncoder().encodeToString(file.readBytes()))
                    },
            )
            return
        }
        require(uri.scheme == "https" && !uri.path.startsWith("/api/v4/")) { "Unsafe storage URL" }
        execute(
            Request.Builder().url(url).put(file.asRequestBody(f.mime.toMediaType())).build()
        ) // no Authorization on presigned PUT
    }

    suspend fun list(
        origin: String,
        path: String,
        key: String,
        app: String? = null,
    ): List<JsonObject> {
        val out = mutableListOf<JsonObject>()
        val seen = mutableSetOf<String>()
        var cursor: String? = null
        do {
            val r =
                request(
                    origin,
                    path +
                        "?limit=200" +
                        (cursor?.let { "&cursor=" + URLEncoder.encode(it, "UTF-8") } ?: ""),
                    app,
                )
            val page = r.rows(key)
            out += page
            cursor = r.text("next_cursor")
            if (cursor != null)
                check(cursor.isNotBlank() && seen.add(cursor)) { "Discovery cursor loop" }
            else
                check(r["has_more"] != JsonPrimitive(true) && page.size < 200) {
                    "Discovery capped without continuation; cannot confirm complete."
                }
        } while (cursor != null)
        return out
    }

    suspend fun workspaces(origin: String) =
        list(origin, "/api/v4/flightdeck-pg/workspaces", "workspaces").map {
            val i = it["identity"]!!.jsonObject
            Choice(i.text("workspace_id")!!, it.text("label")!!, i.text("app_npub")!!).also { c ->
                UUID.fromString(c.id)
                require(Bech32.validPublic(c.app))
            }
        }

    data class Discovery(
        val channels: List<Choice>,
        val agents: List<Choice>,
        val notice: String,
        val directoryUnavailable: Boolean,
    )

    suspend fun discover(origin: String, w: Choice): Discovery {
        val base = "/api/v4/flightdeck-pg/workspaces/${w.id}"
        val notes = mutableListOf<String>()
        var unavailable = false
        val agents =
            try {
                list(origin, "$base/workspace-agents", "workspace_agents", w.app)
                    .mapNotNull { entry ->
                        val actor = entry["actor"] as? JsonObject ?: entry
                        val npub =
                            entry.text("agent_npub")
                                ?: actor.text("npub")
                                ?: actor.text("actor_npub")
                        val hidden =
                            entry["is_visible"] == JsonPrimitive(false) ||
                                (entry["metadata"] as? JsonObject)?.get("can_instruct") ==
                                    JsonPrimitive(false) ||
                                entry.text("archived_at") != null
                        if (hidden || npub == null || !Bech32.validPublic(npub)) null
                        else
                            Choice(
                                npub,
                                entry.text("display_name")
                                    ?: entry.text("name")
                                    ?: actor.text("display_name")
                                    ?: actor.text("label")
                                    ?: "Agent",
                            )
                    }
                    .distinctBy { it.id }
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                unavailable = true
                notes +=
                    "Agent directory unavailable: ${e.message}. Obtain canonical npub from administrator."
                emptyList()
            }
        val labels = mutableMapOf<String, String>()
        try {
            list(origin, "$base/members", "members", w.app).forEach {
                val actor = it["actor"] as? JsonObject ?: it
                val key = actor.text("npub") ?: actor.text("actor_npub")
                val label = actor.text("display_name") ?: actor.text("label") ?: actor.text("name")
                if (key != null && label != null) labels[key] = label
            }
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            notes += "Participant names unavailable."
        }
        agents.forEach { labels[it.id] = it.label }
        val channels =
            try {
                var scopes: List<JsonObject>
                var records: List<JsonObject>
                try {
                    val sync = request(origin, "$base/sync?limit=1", w.app)
                    check(sync["full_snapshot"] == JsonPrimitive(true))
                    scopes = sync.rows("scopes")
                    records = sync.rows("channels")
                    check(
                        scopes.size < 10000 &&
                            records
                                .groupingBy { it.text("scope_id") }
                                .eachCount()
                                .values
                                .all { it < 10000 }
                    ) {
                        "Discovery limit reached"
                    }
                } catch (e: Exception) {
                    if (e is CancellationException || e.message == "Discovery limit reached")
                        throw e
                    notes += "Complete snapshot unavailable; fallback discovery requires review."
                    scopes = list(origin, "$base/scopes", "scopes", w.app)
                    records = scopes.flatMap { s ->
                        val id = s.text("id")!!
                        UUID.fromString(id)
                        list(origin, "$base/scopes/$id/channels", "channels", w.app).map {
                            JsonObject(it + ("scope_id" to JsonPrimitive(id)))
                        }
                    }
                    val me = request(origin, "$base/me", w.app)["visible"]!!.jsonObject
                    val direct = me.rows("channels")
                    val directScopes = me.rows("scopes")
                    check(direct.size < 200 && directScopes.size < 200) {
                        "Direct discovery capped"
                    }
                    records = records + direct
                    scopes = scopes + directScopes
                }
                records
                    .distinctBy { it.text("id") }
                    .map { c ->
                        val id = c.text("id")!!
                        UUID.fromString(id)
                        val s = scopes.firstOrNull { it.text("id") == c.text("scope_id") }
                        var title =
                            c.text("title")
                                ?: c.text("name")
                                ?: c.text("label")
                                ?: "Channel ${id.take(8)}"
                        if (c.text("kind") == "dm") {
                            if (
                                title.equals("dm", true) ||
                                    Bech32.validPublic(title.removePrefix("DM:").trim()) ||
                                    title.startsWith("Channel ")
                            )
                                title =
                                    (c["participant_npubs"] as? JsonArray)
                                        .orEmpty()
                                        .map { it.jsonPrimitive.content }
                                        .filter { it != identity.npub() }
                                        .joinToString(", ") { labels[it] ?: it.take(12) + "…" }
                                        .ifBlank { "Direct message" }
                            title += " · DM"
                        }
                        Choice(id, (s?.text("title") ?: s?.text("name") ?: "Scope") + " / " + title)
                    }
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                notes += "Channel discovery failed: ${e.message}"
                emptyList()
            }
        if (!unavailable)
            notes +=
                if (agents.isEmpty()) "Directory loaded: no visible receiving agents."
                else "Canonical agent directory loaded."
        return Discovery(channels, agents, notes.joinToString("\n"), unavailable)
    }

    fun message(job: Transfer): JsonObject {
        val d = job.destination
        val body = job.body
        val hash = sha(body.toByteArray())
        val event =
            identity.sign(
                33358,
                listOf(
                    listOf("protocol", "flightdeck_pg_message_instruction"),
                    listOf("body_sha256", hash),
                    listOf("workspace_id", d.workspace),
                    listOf("channel_id", d.channel),
                ),
                body,
            )
        return buildJsonObject {
            put("body", body)
            put("create_thread", true)
            put("thread_title", job.title.take(120))
            put("client_request_id", job.id)
            put(
                "message_signature",
                buildJsonObject {
                    put("version", 1)
                    put("protocol", "flightdeck_pg_message_instruction")
                    put("kind", 33358)
                    put("signer_npub", d.signer)
                    put("body_sha256", hash)
                    put("nostr_event", event)
                },
            )
            put(
                "metadata",
                buildJsonObject {
                    put(
                        "attachments",
                        JsonArray(
                            job.files.map { f ->
                                buildJsonObject {
                                    put("kind", "file")
                                    put("storage_object_id", f.objectId!!)
                                    put("filename", f.name)
                                    put("mime_type", f.mime)
                                    put("size_bytes", f.size)
                                }
                            }
                        ),
                    )
                    put(
                        "recorder",
                        buildJsonObject {
                            put("recording_id", job.recordingId)
                            put("snapshot_id", job.id)
                            put("version", 1)
                        },
                    )
                },
            )
            if (d.recipient != null)
                put(
                    "mentions",
                    buildJsonArray {
                        add(
                            buildJsonObject {
                                put("type", "agent")
                                put("npub", d.recipient)
                                put("label", d.recipientLabel!!)
                            }
                        )
                    },
                )
        }
    }
}

class Transfers(val root: File) {
    var readable = true
        private set

    var ledger = Ledger()
        private set

    val jobs
        get() = ledger.jobs

    val destination
        get() = ledger.destination

    init {
        root.mkdirs()
        try {
            val file = File(root, "ledger.json")
            if (file.exists()) ledger = codec.decodeFromString(file.readText())
            ledger.destination?.validate()
            jobs.forEach { job ->
                UUID.fromString(job.id)
                UUID.fromString(job.recordingId)
                job.destination.validate()
                require(job.files.map { it.name }.toSet() == setOf("audio.m4a", "transcript.json"))
                require(job.files.size == 2)
                job.files.forEach { file ->
                    require(file.size >= 0 && Regex("[0-9a-f]{64}").matches(file.checksum))
                    file.objectId?.let { UUID.fromString(it) }
                }
            }
            jobs
                .filter { it.state in setOf("uploading", "posting") }
                .forEach { it.state = "queued" }
        } catch (_: Exception) {
            readable = false
        }
    }

    fun persist() {
        check(readable) { "Unreadable upload ledger; retained and cannot be overwritten." }
        atomic(File(root, "ledger.json"), codec.encodeToString(ledger))
    }

    fun save(d: Destination) {
        d.validate()
        val old = ledger
        ledger = Ledger(d, jobs)
        try {
            persist()
        } catch (e: Exception) {
            ledger = old
            throw e
        }
    }

    fun protects(id: String) =
        !readable || jobs.any { it.recordingId == id && it.state !in setOf("sent", "cancelled") }

    fun directory(id: String) = File(root, id.also { UUID.fromString(it) })

    private fun commitSnapshot(job: Transfer): Transfer {
        check(readable)
        val existing = jobs.lastOrNull {
            it.recordingId == job.recordingId && it.state != "cancelled"
        }
        if (existing != null) {
            directory(job.id).deleteRecursively()
            return existing
        }
        jobs += job
        try {
            persist()
        } catch (e: Exception) {
            jobs.remove(job)
            directory(job.id).deleteRecursively()
            throw e
        }
        return job
    }

    fun snapshot(r: Recording, d: Destination, audio: (File) -> Unit, rules: List<Rule>): Transfer {
        check(readable)
        jobs
            .lastOrNull { it.recordingId == r.id && it.state != "cancelled" }
            ?.let {
                return it
            }
        return commitSnapshot(prepareSnapshot(r, d, audio, rules, uuid()))
    }

    suspend fun snapshotAsync(
        r: Recording,
        d: Destination,
        rules: List<Rule>,
        audio: (File, () -> Unit) -> Unit,
    ): Transfer {
        check(readable)
        jobs
            .lastOrNull { it.recordingId == r.id && it.state != "cancelled" }
            ?.let {
                return it
            }
        val id = uuid()
        try {
            val job =
                withContext(Dispatchers.IO) {
                    val context = currentCoroutineContext()
                    prepareSnapshot(
                        r,
                        d,
                        { file -> audio(file) { context.ensureActive() } },
                        rules,
                        id,
                    )
                }
            currentCoroutineContext().ensureActive()
            return commitSnapshot(job)
        } catch (e: Exception) {
            withContext(NonCancellable + Dispatchers.IO) { directory(id).deleteRecursively() }
            throw e
        }
    }

    private fun prepareSnapshot(
        r: Recording,
        d: Destination,
        audio: (File) -> Unit,
        rules: List<Rule>,
        id: String,
    ): Transfer {
        check(readable)
        d.validate()
        check(r.state == "saved" && r.speech == "complete") {
            "Complete capture and transcription required; files retained."
        }
        val dir = directory(id)
        dir.mkdirs()
        val reviewed = Corrections.apply(r.review, rules)
        try {
            val a = File(dir, "audio.m4a")
            audio(a)
            atomic(
                File(dir, "transcript.json"),
                buildJsonObject {
                    put("version", 1)
                    put("recording_id", r.id)
                    put("snapshot_id", id)
                    put("title", r.title)
                    put("created_at", java.time.Instant.ofEpochMilli(r.created).toString())
                    put("duration_seconds", r.durationMs / 1000.0)
                    put("raw_transcript", r.raw.orEmpty())
                    put("corrected_transcript", reviewed)
                    put("events", JsonArray(r.events.map(::JsonPrimitive)))
                    put("prompt", d.prompt)
                    put("audio_sha256", digest(a))
                    put("audio_size_bytes", a.length())
                    put("destination_workspace", d.workspace)
                    put("destination_channel", d.channel)
                    put("signer_npub", d.signer)
                }
                    .toString(),
            )
            val files =
                listOf("audio.m4a" to "audio/mp4", "transcript.json" to "application/json").map {
                    (name, mime) ->
                    val f = File(dir, name)
                    TransferFile(name, mime, f.length(), digest(f))
                }
            val mention =
                if (d.recipient != null) "@[${d.recipientLabel}](mention:agent:${d.recipient})\n\n"
                else ""
            val body =
                (mention +
                        d.prompt.trim() +
                        "\n\nRecording: ${r.title}\n\n" +
                        reviewed.take(4000) +
                        "\n\nFull original and corrected transcript and complete audio are attached.")
                    .trim()
            val job = Transfer(id, r.id, d, r.title, body, files)
            return job
        } catch (e: Exception) {
            dir.deleteRecursively()
            throw e
        }
    }

    fun retry(job: Transfer) {
        check(job.state !in setOf("sent", "cancelled"))
        job.state = "queued"
        job.notice = null
        persist()
    }

    fun cancel(job: Transfer) {
        job.state = "cancelled"
        job.notice = "Local cancellation cannot retract remote messages or storage."
        persist()
    }

    fun deleteFinished(id: String) {
        check(!protects(id))
        val finished = jobs.filter { it.recordingId == id }
        finished.forEach { check(directory(it.id).deleteRecursively()) }
        jobs.removeAll(finished.toSet())
        try {
            persist()
        } catch (e: Exception) {
            jobs.addAll(finished)
            throw e
        }
    }

    suspend fun send(job: Transfer, api: NStackAPI, gate: () -> Unit) {
        val d = job.destination
        gate()
        job.state = "uploading"
        persist()
        for (f in job.files) {
            currentCoroutineContext().ensureActive()
            gate()
            val path = File(directory(job.id), f.name)
            val intact =
                withContext(Dispatchers.IO) {
                    path.length() == f.size && digest(path) == f.checksum
                }
            gate()
            check(intact) {
                "Local snapshot checksum/size changed; refused."
            }
            if (f.objectId == null) {
                check(!f.preparing) {
                    "Storage prepare uncertain. Cannot safely allocate twice; review remote storage before cancelling."
                }
                f.preparing = true
                persist()
                val p =
                    api.request(
                        d.origin,
                        "/api/v4/flightdeck-pg/workspaces/${d.workspace}/storage/prepare",
                        d.appNpub,
                        "POST",
                        buildJsonObject {
                            put("file_name", f.name)
                            put("content_type", f.mime)
                            put("size_bytes", f.size)
                            put("sha256_hex", f.checksum)
                            put("is_public", false)
                            put(
                                "metadata",
                                buildJsonObject {
                                    put("purpose", "recorder-upload")
                                    put("snapshot_id", job.id)
                                },
                            )
                        },
                    )
                val id = p.text("object_id")!!
                UUID.fromString(id)
                f.objectId = id
                f.uploadUrl = p.text("upload_url")!!
                f.preparing = false
                persist()
            }
            val objectPath = "/api/v4/storage/${f.objectId}"
            var meta = api.request(d.origin, objectPath)
            if (meta["completed_at"] == null || meta["completed_at"] == JsonNull) {
                api.put(path, f.uploadUrl!!, d, f)
                api.request(
                    d.origin,
                    "$objectPath/complete",
                    method = "POST",
                    body =
                        buildJsonObject {
                            put("size_bytes", f.size)
                            put("sha256_hex", f.checksum)
                        },
                )
                meta = api.request(d.origin, objectPath)
            }
            NStackAPI.validateMetadata(meta, f)
            f.complete = true
            persist()
        }
        gate()
        currentCoroutineContext().ensureActive()
        job.state = "posting"
        persist()
        val result =
            api.request(
                d.origin,
                "/api/v4/flightdeck-pg/workspaces/${d.workspace}/channels/${d.channel}/messages",
                d.appNpub,
                "POST",
                api.message(job),
            )
        job.messageId =
            result["message"]!!.jsonObject.text("id")
                ?: error("Message result uncertain; retry same request ID.")
        job.state = "sent"
        job.notice = null
        persist()
    }
}

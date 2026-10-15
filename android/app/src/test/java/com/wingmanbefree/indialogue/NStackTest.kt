package com.wingmanbefree.indialogue

import fr.acinq.secp256k1.Secp256k1
import java.io.File
import java.nio.file.Files
import java.util.Base64
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.*
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.Assert.*
import org.junit.Test

class NStackTest {
    private fun root() = Files.createTempDirectory("nstack-test").toFile()

    private fun identity(root: File) =
        Identity(File(root, "vault.json"), MemoryInstallation()).apply {
            create(Bech32.encode("nsec", ByteArray(32).also { it[31] = 1 }), "123456")
        }

    private fun destination(i: Identity, origin: String = "https://example.com") =
        Destination(
            origin,
            i.npub(),
            uuid(),
            "Workspace",
            i.npub(),
            uuid(),
            "Channel",
            "Please review",
            true,
            i.npub(),
            "Test Agent",
        )

    private fun response(body: String) =
        MockResponse().setHeader("Content-Type", "application/json").setBody(body)

    private fun server(): Pair<MockWebServer, OkHttpClient> {
        val cert = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val s = MockWebServer()
        s.useHttps(
            HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory(),
            false,
        )
        s.start()
        val trust = HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
        return s to
            OkHttpClient.Builder()
                .sslSocketFactory(trust.sslSocketFactory(), trust.trustManager)
                .followRedirects(false)
                .followSslRedirects(false)
                .build()
    }

    @Test
    fun immutableSnapshotSurvivesRestartAndKeepsOriginalDestination() {
        val root = root()
        try {
            val i = identity(root)
            val transfers = Transfers(File(root, "transfers"))
            val d = destination(i)
            transfers.save(d)
            val r =
                Recording(
                    state = "saved",
                    raw = "nosta 42 " + "long ".repeat(2000),
                    edited = "reviewed 42",
                    speech = "complete",
                    draft = "DO NOT UPLOAD",
                )
            val j = transfers.snapshot(r, d, { it.writeBytes(byteArrayOf(1, 2, 3)) }, emptyList())
            val snapshot = File(transfers.directory(j.id), "transcript.json").readText()
            assertTrue(snapshot.contains(r.raw!!))
            assertFalse(snapshot.contains("DO NOT UPLOAD"))
            val original = File(transfers.directory(j.id), "audio.m4a").readBytes()
            transfers.save(d.copy(channel = uuid(), channelLabel = "Other", prompt = "Changed"))
            r.edited = "Changed edit"
            j.state = "failed"
            transfers.persist()
            val reopened = Transfers(transfers.root)
            val recovered = reopened.jobs.single()
            reopened.retry(recovered)
            assertEquals(j.id, recovered.id)
            assertEquals(d, recovered.destination)
            assertTrue(recovered.body.contains("reviewed 42"))
            assertFalse(recovered.body.contains("Changed edit"))
            assertArrayEquals(original, File(reopened.directory(j.id), "audio.m4a").readBytes())
            assertEquals(
                j.id,
                reopened
                    .snapshot(
                        r,
                        reopened.destination!!,
                        { error("must not re-export") },
                        emptyList(),
                    )
                    .id,
            )
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun unreadableLedgerIsNotOverwrittenAndProtectsRetention() {
        val root = root()
        try {
            File(root, "ledger.json").writeText("bad")
            val t = Transfers(root)
            assertFalse(t.readable)
            assertTrue(t.protects(uuid()))
            assertThrows(Exception::class.java) { t.persist() }
            assertEquals("bad", File(root, "ledger.json").readText())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun exactSignedBodyPrivatePrepareCompletionRetryAndStableMessageId() = runBlocking {
        val root = root()
        val (server, client) = server()
        try {
            val i = identity(root)
            val d = destination(i, server.url("/").toString().trimEnd('/'))
            val t = Transfers(File(root, "transfers"))
            val r =
                Recording(state = "saved", raw = "raw", edited = "reviewed", speech = "complete")
            val j = t.snapshot(r, d, { it.writeText("synthetic audio fixture") }, emptyList())
            val objects = mutableListOf<String>()
            val puts = mutableListOf<String>()
            var messageAttempts = 0
            val requestIds = mutableListOf<String>()
            var bodyVerified = false
            server.dispatcher =
                object : Dispatcher() {
                    override fun dispatch(request: RecordedRequest): MockResponse {
                        val bytes = request.body.clone().readByteArray()
                        val auth = request.getHeader("Authorization")!!
                        val event =
                            codec
                                .parseToJsonElement(
                                    Base64.getDecoder()
                                        .decode(auth.removePrefix("Nostr "))
                                        .toString(Charsets.UTF_8)
                                )
                                .jsonObject
                        val tags = event["tags"]!!.jsonArray
                        assertTrue(
                            tags.contains(
                                buildJsonArray {
                                    add("u")
                                    add(server.url(request.path!!).toString())
                                }
                            )
                        )
                        assertTrue(
                            tags.contains(
                                buildJsonArray {
                                    add("method")
                                    add(request.method!!)
                                }
                            )
                        )
                        if (bytes.isNotEmpty())
                            assertTrue(
                                tags.contains(
                                    buildJsonArray {
                                        add("payload")
                                        add(sha(bytes))
                                    }
                                )
                            )
                        assertTrue(
                            Secp256k1.verifySchnorr(
                                event.text("sig")!!.unhex(),
                                event.text("id")!!.unhex(),
                                event.text("pubkey")!!.unhex(),
                            )
                        )
                        val path = request.requestUrl!!.encodedPath
                        if (path.endsWith("/prepare")) {
                            val body =
                                codec.parseToJsonElement(bytes.toString(Charsets.UTF_8)).jsonObject
                            assertEquals(JsonPrimitive(false), body["is_public"])
                            val id = uuid()
                            objects += id
                            return response(
                                """{"object_id":"$id","upload_url":"${server.url("/api/v4/storage/$id")}"}"""
                            )
                        }
                        val id = path.split('/').last()
                        val f = j.files.firstOrNull { it.objectId == id }
                        if (request.method == "PUT") {
                            puts += id
                            return response("{}")
                        }
                        if (path.endsWith("/complete")) return response("{}")
                        if (request.method == "GET" && path.startsWith("/api/v4/storage/")) {
                            checkNotNull(f)
                            return if (id in puts)
                                response(
                                    """{"completed_at":"2026-10-15","size_bytes":"${f.size}","sha256_hex":"${f.checksum}"}"""
                                )
                            else response("""{"completed_at":null}""")
                        }
                        if (path.endsWith("/messages")) {
                            val body =
                                codec.parseToJsonElement(bytes.toString(Charsets.UTF_8)).jsonObject
                            requestIds += body.text("client_request_id")!!
                            val sig = body["message_signature"]!!.jsonObject
                            assertEquals(sha(j.body.toByteArray()), sig.text("body_sha256"))
                            assertEquals(j.body, sig["nostr_event"]!!.jsonObject.text("content"))
                            assertEquals(
                                d.recipient,
                                body["mentions"]!!.jsonArray.single().jsonObject.text("npub"),
                            )
                            assertTrue(j.body.startsWith("@[Test Agent](mention:agent:"))
                            bodyVerified = true
                            messageAttempts++
                            return if (messageAttempts == 1) MockResponse().setResponseCode(503)
                            else response("""{"message":{"id":"${uuid()}"}}""")
                        }
                        return MockResponse().setResponseCode(404)
                    }
                }
            val api = NStackAPI(i, client = client)
            try {
                t.send(j, api, {})
            } catch (_: Exception) {
                j.state = "failed"
                t.persist()
            }
            assertEquals(2, puts.size)
            val recovered = Transfers(t.root)
            val retry = recovered.jobs.single()
            recovered.retry(retry)
            recovered.send(retry, api, {})
            assertEquals("sent", retry.state)
            assertEquals(2, objects.size)
            assertEquals(2, puts.size)
            assertEquals(listOf(j.id, j.id), requestIds)
            assertTrue(bodyVerified)
        } finally {
            server.shutdown()
            root.deleteRecursively()
        }
    }

    @Test
    fun uncertainPrepareAndSnapshotTamperNeverAllocateAgain() = runBlocking {
        val root = root()
        val (s, client) = server()
        try {
            val i = identity(root)
            val d = destination(i, s.url("/").toString().trimEnd('/'))
            val t = Transfers(File(root, "transfers"))
            val j =
                t.snapshot(
                    Recording(state = "saved", raw = "text", speech = "complete"),
                    d,
                    { it.writeText("fixture") },
                    emptyList(),
                )
            s.enqueue(MockResponse().setResponseCode(503))
            try {
                t.send(j, NStackAPI(i, client = client), {})
                fail()
            } catch (_: Exception) {}
            assertTrue(j.files.first().preparing)
            assertEquals(1, s.requestCount)
            try {
                t.send(j, NStackAPI(i, client = client), {})
                fail()
            } catch (_: Exception) {}
            assertEquals(1, s.requestCount)
            j.files.first().preparing = false
            File(t.directory(j.id), "audio.m4a").appendText("tampered")
            try {
                t.send(j, NStackAPI(i, client = client), {})
                fail()
            } catch (_: Exception) {}
            assertEquals(1, s.requestCount)
        } finally {
            s.shutdown()
            root.deleteRecursively()
        }
    }

    @Test
    fun authenticatedRedirectIsRefused() = runBlocking {
        val root = root()
        val (s, client) = server()
        try {
            val i = identity(root)
            s.enqueue(
                MockResponse().setResponseCode(302).setHeader("Location", s.url("/elsewhere"))
            )
            try {
                NStackAPI(i, client = client).request(s.url("/").toString(), "/api/v4/test")
                fail()
            } catch (_: Exception) {}
            assertEquals(1, s.requestCount)
        } finally {
            s.shutdown()
            root.deleteRecursively()
        }
    }

    @Test
    fun discoveryUsesCompleteMetadataAndCanonicalAgentsAcrossMoreThan200Channels() = runBlocking {
        val root = root()
        val (server, client) = server()
        try {
            val identity = identity(root)
            val w = Choice(uuid(), "Workspace", identity.npub())
            val scope = uuid()
            val other =
                Bech32.encode(
                    "npub",
                    Secp256k1.pubkeyCreate(ByteArray(32).also { it[31] = 2 }).copyOfRange(1, 33),
                )
            server.dispatcher =
                object : Dispatcher() {
                    override fun dispatch(request: RecordedRequest): MockResponse =
                        when {
                            request.path!!.contains("workspace-agents") ->
                                response(
                                    buildJsonObject {
                                        put(
                                            "workspace_agents",
                                            buildJsonArray {
                                                add(
                                                    buildJsonObject {
                                                        put("agent_npub", other)
                                                        put("display_name", "Canonical Agent")
                                                        put(
                                                            "actor",
                                                            buildJsonObject {
                                                                put("npub", identity.npub())
                                                            },
                                                        )
                                                    }
                                                )
                                                add(
                                                    buildJsonObject {
                                                        put("agent_npub", identity.npub())
                                                        put("is_visible", false)
                                                    }
                                                )
                                            },
                                        )
                                    }
                                        .toString()
                                )
                            request.path!!.contains("/members") ->
                                MockResponse().setResponseCode(403)
                            request.path!!.contains("/sync") ->
                                response(
                                    buildJsonObject {
                                        put("full_snapshot", true)
                                        put("has_more", true)
                                        put("next_cursor", "message-history-cursor")
                                        put(
                                            "scopes",
                                            buildJsonArray {
                                                add(
                                                    buildJsonObject {
                                                        put("id", scope)
                                                        put("title", "Team")
                                                    }
                                                )
                                            },
                                        )
                                        put(
                                            "channels",
                                            JsonArray(
                                                List(251) { index ->
                                                    buildJsonObject {
                                                        put("id", uuid())
                                                        put("scope_id", scope)
                                                        put(
                                                            "title",
                                                            if (index == 0) "DM"
                                                            else "Channel $index",
                                                        )
                                                        if (index == 0) {
                                                            put("kind", "dm")
                                                            put(
                                                                "participant_npubs",
                                                                buildJsonArray {
                                                                    add(identity.npub())
                                                                    add(other)
                                                                },
                                                            )
                                                        }
                                                    }
                                                }
                                            ),
                                        )
                                    }
                                        .toString()
                                )
                            else -> MockResponse().setResponseCode(404)
                        }
                }
            val result =
                NStackAPI(identity, client = client).discover(server.url("/").toString(), w)
            assertEquals(251, result.channels.size)
            assertEquals(other, result.agents.single().id)
            assertTrue(result.channels.first().label.contains("Canonical Agent"))
            assertFalse(result.directoryUnavailable)
            assertEquals(3, server.requestCount)
        } finally {
            server.shutdown()
            root.deleteRecursively()
        }
    }

    @Test
    fun discoveryRejectsUnpageableCapAndCursorLoops() = runBlocking {
        val root = root()
        val (server, client) = server()
        try {
            val api = NStackAPI(identity(root), client = client)
            val origin = server.url("/").toString()
            server.enqueue(
                response(
                    buildJsonObject {
                        put(
                            "channels",
                            JsonArray(List(200) { buildJsonObject { put("id", uuid()) } }),
                        )
                    }
                        .toString()
                )
            )
            try {
                api.list(origin, "/api/v4/channels", "channels")
                fail("A full capped page is incomplete")
            } catch (_: IllegalStateException) {}
            repeat(2) { server.enqueue(response("""{"channels":[],"next_cursor":"repeat /?x"}""")) }
            try {
                api.list(origin, "/api/v4/channels", "channels")
                fail("Cursor loop must fail")
            } catch (_: IllegalStateException) {}
            server.takeRequest()
            server.takeRequest()
            assertTrue(server.takeRequest().path!!.contains("cursor=repeat+%2F%3Fx"))
        } finally {
            server.shutdown()
            root.deleteRecursively()
        }
    }
}

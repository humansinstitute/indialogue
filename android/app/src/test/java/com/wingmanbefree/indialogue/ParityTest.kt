package com.wingmanbefree.indialogue

import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.*
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ParityTest {
    private val npub = Bech32.encode("npub", ByteArray(32).also { it[31] = 1 })
    private fun destination() = Destination("https://example.com", npub, uuid(), "Workspace", npub, uuid(), "Channel", "Review", recipient = npub, recipientLabel = "Agent")

    @Test fun selectedMicrophoneRequiresVerifiedActualRoute() {
        assertTrue(inputRouteAllowed(false, null, 9, 2000))
        assertTrue(inputRouteAllowed(true, 7, null, 500))
        assertTrue(inputRouteAllowed(true, 7, 7, 2000))
        assertFalse(inputRouteAllowed(true, null, 9, 0))
        assertFalse(inputRouteAllowed(true, 7, 9, 1000))
        assertFalse(inputRouteAllowed(true, 7, null, 1000))
    }

    @Test fun localStopRespectsAutomaticOptInInEveryMode() {
        DialogueMode.entries.forEach { mode ->
            val route = DialogueRoute(destination().copy(automatic = false), mode)
            assertNull(automaticDelivery(route, false))
            assertEquals(route.destination, automaticDelivery(route, true))
            assertEquals(route.destination.copy(automatic = true), automaticDelivery(route.copy(destination = route.destination.copy(automatic = true)), false))
        }
        assertNull(automaticDelivery(null, true))
    }

    @Test fun cancelledResponseDoesNotBlockAnotherAndOnlyAcceptedResponseSucceeds() {
        val d = destination()
        val route = DialogueRoute(d, respondingToReplyId = "reply")
        val r = Recording(state = "saved", dialogueRoute = route)
        val job = Transfer(recordingId = r.id, destination = d, title = "Response", body = "", files = emptyList(), route = route)
        assertEquals(r, pendingResponse(listOf(r), emptyList(), "reply"))
        assertEquals(job, responseTransfer(listOf(job), "reply"))
        assertNotEquals("sent", responseTransfer(listOf(job), "reply")!!.state)
        job.state = "failed"
        assertTrue(canSendConversation(job))
        job.state = "cancelled"
        assertNull(responseTransfer(listOf(job), "reply"))
        assertNull(pendingResponse(listOf(r), listOf(job), "reply"))
        val another = r.copy(id = uuid())
        assertEquals(another, pendingResponse(listOf(r, another), listOf(job), "reply"))
        job.state = "sent"
        assertEquals("sent", responseTransfer(listOf(job), "reply")!!.state)
        listOf("queued", "failed", "paused_locked", "paused_capture").forEach { assertTrue(canSendConversation(job.copy(state = it))) }
        listOf("sent", "uploading", "posting", "cancelled").forEach { assertFalse(canSendConversation(job.copy(state = it))) }
    }

    @Test fun pendingFollowupAndNewerUnsentConversationDoNotHideAcceptedThread() {
        val d = destination()
        val route = DialogueRoute(d)
        val accepted = Transfer(recordingId = uuid(), destination = d, title = "Sent", body = "", files = emptyList(), state = "sent", threadId = uuid(), route = route)
        val followup = accepted.copy(id = uuid(), state = "failed", route = route.copy(threadId = accepted.threadId, respondingToReplyId = "reply"))
        val newer = accepted.copy(id = uuid(), state = "queued", threadId = null, route = DialogueRoute(d))
        val jobs = listOf(accepted, followup, newer)
        assertEquals(accepted, acceptedConversation(jobs, followup))
        assertEquals(accepted, replyPollingTarget(jobs))
        assertNull(acceptedConversation(jobs, newer))
        val fiveNewer = (1..5).map { newer.copy(id = uuid(), route = DialogueRoute(d)) }
        assertNull(replyPollingTarget(listOf(accepted) + fiveNewer, fiveNewer.map(::conversationKey).toSet()))
        assertEquals(accepted, replyPollingTarget(jobs, setOf(conversationKey(followup))))
    }

    @Test fun cancelledTtsWaiterDoesNotPoisonSharedInitialization() = runBlocking {
        val init = VoiceInitialization()
        val first = launch { init.await() }
        yield(); first.cancelAndJoin()
        init.complete(true)
        assertTrue(init.await())
        assertTrue(init.await())
    }

    @Test fun diagnosticsAreBoundedClosedSchemaAndRetryKeepsOriginalPrivateSnapshot() {
        val root = Files.createTempDirectory("parity-diagnostics").toFile()
        try {
            var now = 4_000_000L
            val log = Diagnostics(File(root, "events.json")) { now }
            repeat(510) { log.record(DiagnosticEvent.CaptureStarted) }
            assertEquals(500, log.recent().size)
            now += 3_600_001
            log.record(DiagnosticEvent.IdentityLocked)
            assertEquals(listOf(DiagnosticEvent.IdentityLocked), log.recent().map { it.event })
            val json = log.report("1.1.0")
            assertFalse(json.contains("audio"))
            assertFalse(json.contains("transcript"))
            assertFalse(json.contains("npub"))
            val transfers = Transfers(File(root, "transfers"))
            val original = destination()
            val job = transfers.snapshotDiagnostics(original, json.dropLast(1) + ",\"unexpected\":\"DO NOT SEND\"}")
            assertTrue(job.diagnostics)
            assertFalse(File(transfers.directory(job.id), "diagnostics.json").readText().contains("DO NOT SEND"))
            transfers.save(original.copy(channel = uuid()))
            job.state = "failed"; transfers.persist()
            val reopened = Transfers(transfers.root)
            assertTrue(reopened.readable)
            reopened.retry(reopened.jobs.single())
            assertEquals(original, reopened.jobs.single().destination)
            assertEquals(job.files, reopened.jobs.single().files)
            assertTrue(reopened.protects(job.recordingId))
            reopened.cancel(reopened.jobs.single())
            reopened.deleteFinished(job.recordingId)
            assertTrue(reopened.jobs.isEmpty())
            File(root, "events.json").writeText("broken")
            val unreadable = Diagnostics(File(root, "events.json")) { now }
            assertFalse(unreadable.readable)
            unreadable.record(DiagnosticEvent.Foreground)
            assertEquals("broken", File(root, "events.json").readText())
            assertThrows(Exception::class.java) { unreadable.report("1.1.0") }
        } finally { root.deleteRecursively() }
    }

    @Test fun oldManifestsAndLedgersDecodeWithoutMigration() {
        val recording = codec.decodeFromString<Recording>("""{"id":"${uuid()}","state":"saved","segments":["old.m4a"],"raw":"Original"}""")
        assertNull(recording.dialogueRoute)
        assertFalse(recording.audioOnly)
        assertEquals("Original", recording.review)
        val old = codec.decodeFromString<Ledger>("""{"jobs":[]}""")
        assertEquals(DialogueMode.Normal, old.routing.mode)
        assertNull(old.routing.channel)
    }

    @Test fun modesRetainIndependentRoutesAndRollbackInvalidAgent() {
        val root = Files.createTempDirectory("parity-routes").toFile()
        try {
            val transfers = Transfers(root)
            val normal = destination()
            transfers.save(normal)
            val channel = normal.copy(channel = uuid(), channelLabel = "Other")
            transfers.saveRoute(channel, DialogueMode.Channel)
            assertNull(transfers.ledger.routing.channel!!.recipient)
            transfers.saveRoute(normal.copy(prompt = "Agent instruction"), DialogueMode.Agent)
            assertThrows(IllegalArgumentException::class.java) { transfers.saveRoute(channel.copy(recipient = null), DialogueMode.Agent) }
            val reopened = Transfers(root)
            assertTrue(reopened.readable)
            assertEquals(normal, reopened.destination)
            assertEquals(channel.channel, reopened.ledger.routing.channel!!.channel)
            assertEquals("Agent instruction", reopened.ledger.routing.agent!!.prompt)
            assertEquals(DialogueMode.Agent, reopened.ledger.routing.mode)
            assertEquals(normal.signer, reopened.setupSeed(DialogueMode.Channel, normal.signer)!!.signer)
            assertNull(reopened.setupSeed(DialogueMode.Agent, "other signer"))
        } finally { root.deleteRecursively() }
    }

    @Test fun audioOnlySnapshotRetainsRouteAndNeverClaimsTranscript() {
        val root = Files.createTempDirectory("parity-audio").toFile()
        try {
            val transfers = Transfers(root)
            val original = destination()
            val route = DialogueRoute(original, DialogueMode.Agent, threadId = uuid(), respondingToReplyId = "reply")
            val recording = Recording(state = "saved", raw = "DO NOT SEND", edited = "DO NOT SEND EDIT", dialogueRoute = route, audioOnly = true)
            val job = transfers.snapshot(recording, route.destination, { it.writeBytes(byteArrayOf(1,2,3)) }, emptyList())
            val artifact = File(transfers.directory(job.id), "transcript.json").readText()
            assertFalse(artifact.contains("DO NOT SEND"))
            assertTrue(artifact.contains("\"transcript_attached\":false"))
            assertTrue(job.body.contains("No transcript is attached"))
            transfers.save(original.copy(channel = uuid(), prompt = "Changed"))
            job.state = "failed"; transfers.persist()
            val reopened = Transfers(root)
            assertTrue(reopened.readable)
            val recovered = reopened.jobs.single()
            reopened.retry(recovered)
            assertEquals(route, recovered.route)
            assertEquals(original, recovered.destination)
            assertEquals(job.id, recovered.id)
            assertEquals(job.files, recovered.files)
        } finally { root.deleteRecursively() }
    }

    @Test fun replyParserPrefersAudioAndIgnoresDeletedAndRecorderEcho() {
        val objectId = uuid()
        val message = buildJsonObject {
            put("id", "reply"); put("body", "Text fallback")
            put("metadata", buildJsonObject { put("attachments", buildJsonArray { add(buildJsonObject { put("mime_type", "audio/mp4"); put("storage_object_id", objectId) }) }) })
        }
        assertEquals(objectId, parseReply(message)!!.audioObjectId)
        assertEquals("Text fallback", parseReply(message)!!.body)
        assertNull(parseReply(JsonObject(message + ("record_state" to JsonPrimitive("deleted")))))
        assertNull(parseReply(JsonObject(message + ("deleted_at" to JsonPrimitive("2026-01-01")))))
        assertNull(parseReply(JsonObject(message + ("metadata" to buildJsonObject { put("recorder", buildJsonObject { put("version", 1) }) }))))
        assertThrows(Exception::class.java) { parseReply(buildJsonObject { put("id", "missing body") }) }
    }
}

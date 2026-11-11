package com.wingmanbefree.indialogue

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ReplyLifecycleTest {
    @Test fun audioPreferredStopCleanupColdAutoplayIdentityAndFailedFollowupRefresh() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val app = instrumentation.targetContext.applicationContext as DialogueApp
        assertTrue(android.os.Build.MODEL.contains("sdk"))
        assertFalse("Only isolated test data", app.identity.exists)
        var job: Transfer? = null
        val controllers = mutableListOf<ReplyController>()
        val ownedFiles = mutableListOf<File>()
        try {
            withContext(Dispatchers.Main) {
                app.identity.create(Bech32.encode("nsec", ByteArray(32).also { it[31] = 5 }), "123456")
                app.foreground.value = true
                val d = Destination("https://example.invalid", app.identity.npub(), uuid(), "Synthetic", app.identity.npub(), uuid(), "Synthetic", "Review")
                val route = DialogueRoute(d, DialogueMode.Agent)
                job = Transfer(recordingId = uuid(), destination = d, title = "Synthetic", body = "", files = emptyList(), state = "sent", messageId = uuid(), threadId = uuid(), route = route)
                app.transfers.jobs.add(job!!)
                val controller = ReplyController(app).also { controllers.add(it) }
                val objectId = uuid()
                val replyId = uuid()
                controller.loadMessages = { listOf(buildJsonObject {
                    put("id", replyId); put("body", "Synthetic text which must not invoke TTS when audio exists")
                    put("attachments", buildJsonArray { add(buildJsonObject { put("mime_type", "audio/mp4"); put("storage_object_id", objectId) }) })
                }) }
                var downloads = 0
                controller.loadAudio = { _, id, file ->
                    assertEquals(objectId, id)
                    downloads++; ownedFiles.add(file)
                    instrumentation.context.assets.open("synthetic-speech.m4a").use { input -> file.outputStream().use { input.copyTo(it) } }
                }
                controller.refresh(job!!, autoPlay = true)
                yield(); delay(500)
                assertEquals(1, downloads)
                assertEquals(replyId, controller.playing)
                assertTrue(ownedFiles.single().exists())
                controller.stop()
                assertNull(controller.playing)
                assertFalse(ownedFiles.single().exists())
                // A fresh controller loads persisted autoplay history; manual Listen still works.
                val reopened = ReplyController(app).also { controllers.add(it) }
                reopened.loadMessages = controller.loadMessages
                reopened.loadAudio = controller.loadAudio
                reopened.refresh(job!!, autoPlay = true)
                yield(); assertEquals(1, downloads)
                val reply = reopened.replies[reopened.key(job!!)]!!
                reopened.listen(job!!, reply); yield(); delay(250)
                assertEquals(2, downloads)
                assertNotEquals(ownedFiles[0].name, ownedFiles[1].name)
                app.foreground.value = false; reopened.stop()
                assertFalse(ownedFiles.last().exists())
                reopened.listen(job!!, reply); yield()
                assertNull(reopened.playing)
                assertEquals(2, downloads)
                app.foreground.value = true
                val followup = job!!.copy(id = uuid(), state = "failed", route = route.copy(threadId = job!!.threadId, respondingToReplyId = reply.id))
                app.transfers.jobs.add(followup)
                reopened.refresh(followup)
                assertNotNull(reopened.replies[reopened.key(job!!)])
                app.transfers.jobs.remove(followup)
                app.lock()
                assertTrue(reopened.latest().isEmpty())
                assertThrows(Exception::class.java) { reopened.gate(job!!) }
                app.identity.unlock("123456")
                assertFalse(reopened.latest().isEmpty())
                // Cancel a slow attachment fetch, then immediately start another: ownership is unique.
                val entered = CompletableDeferred<Unit>()
                reopened.loadAudio = { _, _, file ->
                    ownedFiles.add(file); file.writeText("partial")
                    entered.complete(Unit); awaitCancellation()
                }
                reopened.listen(job!!, reply); entered.await()
                val partial = ownedFiles.last()
                reopened.stop(); yield()
                assertFalse(partial.exists())
                assertNull(reopened.playing)
                app.capturePending.value = true
                assertThrows(Exception::class.java) { reopened.gate(job!!) }
                app.capturePending.value = false
            }
        } finally {
            withContext(Dispatchers.Main) {
                controllers.forEach { it.stop() }
                app.capturePending.value = false
                job?.let { app.transfers.jobs.remove(it) }
                app.identity.remove()
                app.refresh()
                ownedFiles.forEach { it.delete() }
            }
        }
    }
}

package com.wingmanbefree.indialogue

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Real coroutine/controller lifecycles with injected slow engines; native engine tests are
 * separate.
 */
@RunWith(AndroidJUnit4::class)
class LifecycleTest {
    private val app
        get() =
            InstrumentationRegistry.getInstrumentation().targetContext.applicationContext
                as DialogueApp

    private suspend fun main(block: () -> Unit) = withContext(Dispatchers.Main) { block() }

    private suspend fun until(test: () -> Boolean) {
        withTimeout(10000) { while (!test()) delay(20) }
    }

    @Test
    fun cancellingQueuedSpeechDoesNotInterruptOwnerAndCancelledOwnerStaysCancelled() = runBlocking {
        val a =
            Recording(
                title = "Synthetic lifecycle A",
                created = System.currentTimeMillis() + 1000,
                state = "saved",
                speech = "queued",
            )
        val b =
            Recording(
                title = "Synthetic lifecycle B",
                created = 0,
                state = "saved",
                speech = "queued",
            )
        val original = app.speechEngine
        var calls = 0
        var cancelled = 0
        try {
            main {
                app.library.save(a)
                app.library.save(b)
                app.refresh()
                app.speechEngine = {
                    calls++
                    if (calls == 1)
                        try {
                            awaitCancellation()
                        } finally {
                            cancelled++
                        }
                    else "real queue fixture result"
                }
                app.foreground.value = true
                app.resume()
            }
            until { calls == 1 }
            main { app.cancelSpeech(b.id) }
            delay(150)
            assertEquals(0, cancelled)
            assertEquals("running", app.library.get(a.id).speech)
            assertEquals("cancelled", app.library.get(b.id).speech)
            main { app.cancelSpeech(a.id) }
            until { cancelled == 1 }
            delay(200)
            assertEquals(1, calls)
            assertEquals("cancelled", app.library.get(a.id).speech)
            main {
                app.onBackground()
                app.onForeground()
            }
            delay(150)
            assertEquals(1, calls)
            main { app.retrySpeech(a.id) }
            until { app.library.get(a.id).speech == "complete" }
            assertEquals(2, calls)
            assertEquals("real queue fixture result", app.library.get(a.id).raw)
            assertEquals("cancelled", app.library.get(b.id).speech)
        } finally {
            main {
                app.onBackground()
                app.speechEngine = original
                app.library.directory(a.id).deleteRecursively()
                app.library.directory(b.id).deleteRecursively()
                app.refresh()
            }
        }
    }

    @Test
    fun cancellingQueuedUploadDoesNotInterruptOwnerAndRetryRetainsSnapshot() = runBlocking {
        assertFalse("Test requires an empty isolated emulator identity", app.identity.exists)
        val original = app.transferEngine
        var calls = 0
        var cancelled = 0
        var a: Transfer? = null
        var b: Transfer? = null
        try {
            main {
                app.identity.create(
                    Bech32.encode("nsec", ByteArray(32).also { it[31] = 3 }),
                    "123456",
                )
                val npub = app.identity.npub()
                val d =
                    Destination(
                        "https://example.com",
                        npub,
                        uuid(),
                        "Fixture",
                        npub,
                        uuid(),
                        "Channel",
                        "Review",
                    )
                fun snapshot(title: String) =
                    app.transfers.snapshot(
                        Recording(
                            title = title,
                            state = "saved",
                            raw = "full raw",
                            edited = "reviewed",
                            speech = "complete",
                        ),
                        d,
                        { it.writeText("public synthetic audio fixture") },
                        emptyList(),
                    )
                a = snapshot("Synthetic transfer A")
                b = snapshot("Synthetic transfer B")
                app.transferEngine = { job, _, _ ->
                    calls++
                    if (calls == 1)
                        try {
                            awaitCancellation()
                        } finally {
                            cancelled++
                        }
                    else {
                        job.state = "sent"
                        app.transfers.persist()
                    }
                }
                app.foreground.value = true
                app.resume()
            }
            until { calls == 1 }
            main { app.cancelUpload(b!!) }
            delay(150)
            assertEquals(0, cancelled)
            assertEquals("cancelled", b!!.state)
            main { app.cancelUpload(a!!) }
            until { cancelled == 1 }
            delay(150)
            assertEquals(1, calls)
            assertEquals("cancelled", a!!.state)
            // Failed immutable snapshots remain eligible for explicit retry from BOTH controller
            // actions.
            val id = a!!.id
            val destination = a!!.destination
            val body = a!!.body
            main {
                a!!.state = "failed"
                app.transfers.persist()
                app.upload(a!!.recordingId)
            }
            // upload needs an existing library entry, exactly as a Recording view has.
            if (calls == 1) {
                main {
                    app.library.save(
                        Recording(
                            id = a!!.recordingId,
                            title = "Retry fixture",
                            state = "saved",
                            raw = "changed local text",
                            speech = "complete",
                        )
                    )
                    app.upload(a!!.recordingId)
                }
            }
            until { calls == 2 }
            assertEquals("sent", a!!.state)
            assertEquals(id, a!!.id)
            assertEquals(destination, a!!.destination)
            assertEquals(body, a!!.body)
            main {
                a!!.state = "failed"
                app.transfers.persist()
                app.retryUpload(a!!)
            }
            until { calls == 3 }
            assertEquals(id, a!!.id)
            assertEquals(body, a!!.body)
        } finally {
            main {
                app.onBackground()
                app.transferEngine = original
                listOfNotNull(a, b).forEach { job ->
                    app.transfers.jobs.remove(job)
                    app.transfers.directory(job.id).deleteRecursively()
                    app.library.directory(job.recordingId).deleteRecursively()
                }
                app.transfers.persist()
                app.identity.remove()
                app.refresh()
            }
        }
    }

    @Test
    fun pendingPlaybackCannotStartAfterCaptureWinsAndActiveMetadataIsProtected() = runBlocking {
        val original = app.playbackExport
        val release = CompletableDeferred<File>()
        val begun = CompletableDeferred<Unit>()
        val a = Recording(title = "Active fixture")
        val b = Recording(title = "Playback fixture", state = "saved")
        try {
            main {
                app.library.save(a)
                app.library.save(b)
                app.playbackExport = {
                    begun.complete(Unit)
                    release.await()
                }
                app.foreground.value = true
                app.play(b.id)
            }
            begun.await()
            main {
                app.capturePending.value = true
                app.prioritizeCapture()
                app.active.value = a.id
                app.play(b.id)
            }
            assertNull(app.playingId)
            release.complete(File(app.cacheDir, "nonexistent-public-fixture.m4a"))
            delay(150)
            assertNull(app.playingId)
            var refused = false
            main {
                try {
                    app.update(a.id) { it.title = "Must not persist" }
                } catch (_: IllegalStateException) {
                    refused = true
                }
            }
            assertTrue(refused)
            assertEquals("Active fixture", app.library.get(a.id).title)
        } finally {
            main {
                app.capturePending.value = false
                app.active.value = null
                app.stopPlayback()
                app.playbackExport = original
                app.library.directory(a.id).deleteRecursively()
                app.library.directory(b.id).deleteRecursively()
                app.onBackground()
                app.refresh()
            }
        }
    }

    @Test
    fun failedStatusWritePausesQueueUntilExplicitRetry(): Unit = runBlocking {
        val record =
            Recording(title = "Read-only synthetic fixture", state = "saved", speech = "queued")
        val engine = app.speechEngine
        var calls = 0
        val directory = app.library.directory(record.id)
        try {
            main {
                app.library.save(record)
                app.refresh()
                check(directory.setWritable(false, false))
                app.speechEngine = {
                    calls++
                    "recovered text"
                }
                app.foreground.value = true
                app.resume()
            }
            until { app.notice.value.contains("queue paused") }
            delay(150)
            assertEquals(0, calls)
            main {
                check(directory.setWritable(true, false))
                app.retrySpeech(record.id)
            }
            until { app.library.get(record.id).speech == "complete" }
            assertEquals(1, calls)
        } finally {
            main {
                directory.setWritable(true, false)
                app.onBackground()
                app.speechEngine = engine
                directory.deleteRecursively()
                app.notice.value = ""
                app.refresh()
            }
        }
    }

    @Test
    fun manualUploadHonorsPendingAutomaticDestinationAndConsumesIntent(): Unit = runBlocking {
        val pub = Bech32.encode("npub", ByteArray(32).also { it[31] = 1 })
        val original =
            Destination(
                "https://example.com",
                pub,
                uuid(),
                "Original workspace",
                pub,
                uuid(),
                "Original channel",
                "Original prompt",
                true,
            )
        val record =
            Recording(
                title = "Automatic intent fixture",
                state = "saved",
                raw = "raw",
                speech = "complete",
                autoDestination = original,
            )
        record.segments += "segment-0.m4a"
        var job: Transfer? = null
        try {
            main { app.library.save(record) }
            InstrumentationRegistry.getInstrumentation()
                .context
                .assets
                .open("synthetic-speech.m4a")
                .use { input ->
                    File(app.library.directory(record.id), record.segments.single())
                        .outputStream()
                        .use { input.copyTo(it) }
                }
            main {
                app.foreground.value = true
                app.upload(record.id)
            }
            until { app.transfers.jobs.any { it.recordingId == record.id } }
            job = app.transfers.jobs.first { it.recordingId == record.id }
            assertEquals(original, job!!.destination)
            assertNull(app.library.get(record.id).autoDestination)
        } finally {
            main {
                app.onBackground()
                job?.let {
                    app.transfers.jobs.remove(it)
                    app.transfers.directory(it.id).deleteRecursively()
                }
                app.transfers.persist()
                app.library.directory(record.id).deleteRecursively()
                app.notice.value = ""
                app.refresh()
            }
        }
    }
}

package com.wingmanbefree.indialogue

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RetentionTest {
    @Test
    fun safeRetentionDeletesOnlyExpiredUnprotectedLocalFixtures(): Unit = runBlocking {
        val app =
            InstrumentationRegistry.getInstrumentation().targetContext.applicationContext
                as DialogueApp
        assertTrue(android.os.Build.MODEL.contains("sdk"))
        val original = app.retention
        val jobs = mutableListOf<Transfer>()
        val records = mutableListOf<Recording>()
        withContext(Dispatchers.Main) {
            try {
                val old = System.currentTimeMillis() - 10 * 86400000L
                val expired =
                    Recording(
                        created = old,
                        title = "Expired synthetic fixture",
                        state = "saved",
                        raw = "private local fixture",
                        edited = "edited fixture",
                        draft = "draft fixture",
                        speech = "complete",
                    )
                val protected =
                    Recording(
                        created = old,
                        title = "Pending synthetic fixture",
                        state = "saved",
                        raw = "raw",
                        speech = "complete",
                    )
                val queued =
                    Recording(
                        created = old,
                        title = "Queued synthetic fixture",
                        state = "saved",
                        speech = "queued",
                    )
                records.addAll(listOf(expired, protected, queued))
                records.forEach {
                    app.library.save(it)
                    File(app.library.directory(it.id), "audio-fixture").writeText("synthetic bytes")
                }
                val pub = Bech32.encode("npub", ByteArray(32).also { it[31] = 1 })
                val dest =
                    Destination(
                        "https://example.com",
                        pub,
                        uuid(),
                        "Fixture",
                        pub,
                        uuid(),
                        "Channel",
                        "Review",
                    )
                jobs +=
                    app.transfers
                        .snapshot(expired, dest, { it.writeText("synthetic audio") }, emptyList())
                        .apply { state = "sent" }
                jobs +=
                    app.transfers
                        .snapshot(protected, dest, { it.writeText("synthetic audio") }, emptyList())
                        .apply { state = "failed" }
                app.transfers.persist()
                app.refresh()
                app.foreground.value = true
                app.saveRetention(Retention(true, 1))
                assertFalse(app.library.directory(expired.id).exists())
                assertFalse(app.transfers.directory(jobs[0].id).exists())
                assertFalse(app.transfers.jobs.any { it.id == jobs[0].id })
                assertTrue(app.library.directory(protected.id).exists())
                assertTrue(app.transfers.directory(jobs[1].id).exists())
                assertTrue(app.library.directory(queued.id).exists())
                assertEquals("failed", app.transfers.jobs.first { it.id == jobs[1].id }.state)
            } finally {
                app.foreground.value = false
                app.saveRetention(original)
                records.forEach { app.library.directory(it.id).deleteRecursively() }
                jobs.forEach {
                    app.transfers.jobs.remove(it)
                    app.transfers.directory(it.id).deleteRecursively()
                }
                app.transfers.persist()
                app.notice.value = ""
                app.refresh()
            }
        }
    }
}

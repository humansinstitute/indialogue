package com.wingmanbefree.indialogue

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ModelDownloadTest {
    @Test
    fun explicitRealDownloadInstallRemoveAndCancellation(): Unit = runBlocking {
        assumeTrue(
            "Explicit network download consent required",
            InstrumentationRegistry.getArguments().getString("downloadSmoke") == "true",
        )
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val dir = File(context.noBackupFilesDir, "download-test-${uuid()}").apply { mkdirs() }
        val firstCleanupBytes = CompletableDeferred<Unit>()
        val models =
            Models(dir) { s ->
                println("DOWNLOAD_EVIDENCE $s")
                if (s.startsWith("Downloading cleanup:")) firstCleanupBytes.complete(Unit)
            }
        try {
            withTimeout(300000) { models.download("speech") }
            assertTrue(models.speechReady)
            models.remove("speech")
            assertFalse(models.speechReady)
            val downloading = launch { models.download("cleanup") }
            withTimeout(90000) { firstCleanupBytes.await() }
            downloading.cancelAndJoin()
            assertFalse(models.cleanupReady)
            assertFalse(File(dir, "cleanup.part").exists())
            assertFalse(models.cleanup.exists())
            println(
                "DOWNLOAD_EVIDENCE speech install/remove and cleanup network cancellation passed; no incomplete model installed"
            )
        } finally {
            dir.deleteRecursively()
        }
    }
}

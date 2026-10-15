package com.wingmanbefree.indialogue

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeTest {
    private val instrumentation
        get() = InstrumentationRegistry.getInstrumentation()

    private val context
        get() = instrumentation.targetContext

    @Test
    fun fullAacExportAndDecodeBothSegments() {
        val dir = File(context.noBackupFilesDir, "test-${uuid()}").apply { mkdirs() }
        try {
            val input = File(dir, "segment-0.m4a")
            instrumentation.context.assets.open("synthetic-speech.m4a").use { source ->
                input.outputStream().use { source.copyTo(it) }
            }
            var sourceSamples = 0
            decodePcm(input) { samples, _ -> sourceSamples += samples.size }
            assertTrue(sourceSamples > 44100)
            val output = File(dir, "combined.m4a")
            assertTrue(AudioExport.combine(listOf(input, input), output).isEmpty())
            var combinedSamples = 0
            decodePcm(output) { samples, _ -> combinedSamples += samples.size }
            assertTrue(combinedSamples > sourceSamples * 1.95)
            val broken = File(dir, "broken.m4a").apply { writeText("not audio") }
            try {
                AudioExport.combine(listOf(input, broken), File(dir, "complete.m4a"))
                fail("Complete upload export must fail")
            } catch (_: Exception) {}
            val warnings =
                AudioExport.combine(listOf(input, broken), File(dir, "partial.m4a"), true)
            assertEquals(1, warnings.size)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun realAndroidKeystoreVaultColdLaunchAndWrongPin() {
        val dir = File(context.noBackupFilesDir, "test-${uuid()}").apply { mkdirs() }
        try {
            val secret = KeystoreSecret(File(dir, "installation"))
            val file = File(dir, "vault")
            val scalar = ByteArray(32).also { it[31] = 3 }
            val vault = Identity(file, secret)
            vault.create(Bech32.encode("nsec", scalar), "123456")
            val npub = vault.npub()
            vault.lock()
            val cold = Identity(file, KeystoreSecret(File(dir, "installation")))
            assertFalse(cold.unlocked)
            try {
                cold.unlock("999999")
                fail()
            } catch (_: Exception) {}
            assertTrue(file.exists())
            cold.unlock("123456")
            assertEquals(npub, cold.npub())
            assertEquals(
                128,
                cold.sign(1, emptyList(), "isolated synthetic Android test").text("sig")!!.length,
            )
            cold.lock()
            assertFalse(cold.unlocked)
            file.delete() /* Keep installation key: other tests may be using this test-app alias. */
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun actualOfflineSpeechAndCleanup() = runBlocking {
        assumeTrue(
            "Explicit -e modelSmoke true and /data/local/tmp fixtures required",
            InstrumentationRegistry.getArguments().getString("modelSmoke") == "true",
        )
        val dir = File(context.noBackupFilesDir, "model-test-${uuid()}").apply { mkdirs() }
        try {
            val models = Models(dir) { s -> println("MODEL_EVIDENCE $s") }
            // These are public models placed explicitly on the isolated emulator by the validation
            // operator.
            val voskZip = File(context.noBackupFilesDir, "validation-fixtures/dialogue-vosk.zip")
            val gguf = File(context.noBackupFilesDir, "validation-fixtures/dialogue-qwen.gguf")
            assertEquals(Models.SPEECH_HASH, digest(voskZip))
            assertEquals(Models.CLEANUP_HASH, digest(gguf))
            val stage = File(dir, "speech").apply { mkdirs() }
            java.util.zip.ZipInputStream(voskZip.inputStream()).use { zip ->
                while (true) {
                    val entry = zip.nextEntry ?: break
                    val file = File(stage, entry.name)
                    require(file.canonicalPath.startsWith(stage.canonicalPath + "/"))
                    if (entry.isDirectory) file.mkdirs()
                    else {
                        file.parentFile!!.mkdirs()
                        file.outputStream().use { zip.copyTo(it) }
                    }
                }
            }
            File(stage, "verified").writeText(Models.SPEECH_HASH)
            gguf.copyTo(models.cleanup)
            File(dir, "cleanup-verified").writeText(Models.CLEANUP_HASH)
            val input = File(dir, "speech.m4a")
            instrumentation.context.assets.open("synthetic-speech.m4a").use { source ->
                input.outputStream().use { source.copyTo(it) }
            }
            val transcript = models.transcribe(listOf(input, input))
            println("MODEL_EVIDENCE real_vosk_two_segments=$transcript")
            assertTrue(transcript.contains("one two three"))
            assertTrue(transcript.split("one two three").size >= 3)
            val draft =
                models.clean(
                    "the meeting is on monday at three pm please bring the report",
                    emptyList(),
                )
            println("MODEL_EVIDENCE real_qwen_draft=$draft")
            assertTrue(draft.isNotBlank())
            assertTrue(draft.contains("meeting", true))
            assertTrue(draft.contains("report", true))
            val raw = "raw transcript"
            val record =
                Recording(
                    state = "saved",
                    raw = raw,
                    edited = "user edit",
                    draft = draft,
                    speech = "complete",
                )
            record.draft = null
            assertEquals("user edit", record.review)
            record.draft = draft
            record.edited = record.draft
            record.draft = null
            assertEquals(raw, record.raw)
            assertEquals(draft, record.review)
        } finally {
            dir.deleteRecursively()
        }
    }
}

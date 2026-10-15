package com.wingmanbefree.indialogue

import java.io.File
import java.nio.file.Files
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class DomainTest {
    private fun temp() = Files.createTempDirectory("dialogue-test").toFile()

    @Test
    fun vocabularyPreservesBoundariesCasePunctuationAndNeverCascades() {
        val rules =
            listOf(
                Rule("a", "nosta", "nostr"),
                Rule("b", "nostr", "wrong"),
                Rule("c", "new york", "NYC"),
            )
        assertEquals(
            "NOSTR, Nostr! nosta42 _nosta énosta nostré; NYC. wrong",
            Corrections.apply("NOSTA, Nosta! nosta42 _nosta énosta nostré; NEW YORK. nostr", rules),
        )
        assertEquals(
            "long phrase short",
            Corrections.apply(
                "one two one",
                listOf(Rule("1", "one", "short"), Rule("2", "one two", "long phrase")),
            ),
        )
    }

    @Test
    fun occurrenceOnlyChangesChosenWordAndPreservesPunctuation() {
        val text = "nosta, nosta! 😀"
        val second = Corrections.words(text)[1]
        assertEquals("nosta, nostr! 😀", Corrections.occurrence(text, second.range, "nostr"))
        assertThrows(IllegalArgumentException::class.java) {
            Corrections.occurrence(text, 0..5, "bad")
        }
    }

    @Test
    fun chunksPreserveLongUnicodeTextExactly() {
        val text = "🦜 names 42 and café. ".repeat(1000)
        val chunks = Models.chunks(text)
        assertEquals(text, chunks.joinToString(""))
        assertTrue(chunks.all { it.length <= 900 && !it.last().isHighSurrogate() })
    }

    @Test
    fun recoverRetainsAudioReferencesEditsDraftAndIsolatesCorruption() {
        val root = temp()
        try {
            val store = Library(root)
            val r = Recording()
            r.segments += "segment-0.m4a"
            r.segments += "segment-1.m4a"
            r.speech = "running"
            r.raw = "raw"
            r.edited = "edit"
            r.draft = "draft"
            store.save(r)
            val bytes = byteArrayOf(1, 2, 3)
            val audio = File(store.directory(r.id), r.segments[0])
            audio.writeBytes(bytes)
            val broken = File(root, uuid()).apply { mkdirs() }
            File(broken, "manifest.json").writeText("bad")
            val loaded = store.all(true).single()
            assertEquals("interrupted", loaded.state)
            assertEquals("queued", loaded.speech)
            assertEquals(r.id, loaded.id)
            assertEquals(r.segments, loaded.segments)
            assertEquals("edit", loaded.review)
            assertEquals("draft", loaded.draft)
            assertArrayEquals(bytes, audio.readBytes())
            assertEquals(1, store.warnings.size)
            assertTrue(File(broken, "manifest.json").exists())
            assertEquals("interrupted", store.get(r.id).state)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun retentionFailsClosedAndUsesCreationTime() {
        val now = 30 * 86_400_000L
        val r = Recording(created = 0, state = "saved", speech = "complete")
        assertFalse(Retention().eligible(r, now, emptySet(), true))
        val policy = Retention(true, 30)
        assertFalse(policy.eligible(r, now - 1, emptySet(), true))
        assertTrue(policy.eligible(r, now, emptySet(), true))
        assertFalse(policy.eligible(r, now, setOf(r.id), true))
        assertFalse(policy.eligible(r, now, emptySet(), false))
        for (state in listOf("queued", "running")) {
            r.speech = state
            assertFalse(policy.eligible(r, now, emptySet(), true))
        }
        assertThrows(IllegalArgumentException::class.java) { Retention(true, 0) }
        assertThrows(IllegalArgumentException::class.java) { Retention(true, 3651) }
    }

    @Test
    fun byteMetadataRejectsBooleansFractionsSignsOverflowAndMalformed() {
        for (value in
            listOf(
                JsonPrimitive(true),
                JsonPrimitive(2.0),
                JsonPrimitive("-1"),
                JsonPrimitive("1.0"),
                JsonPrimitive("9223372036854775808"),
                JsonNull,
            )) {
            assertThrows(Exception::class.java) { NStackAPI.byteCount(value) }
        }
        assertEquals(42L, NStackAPI.byteCount(JsonPrimitive("42")))
        assertEquals(42L, NStackAPI.byteCount(JsonPrimitive(42)))
        val file = TransferFile("a", "x", 42, "a".repeat(64))
        assertThrows(Exception::class.java) {
            NStackAPI.validateMetadata(
                buildJsonObject {
                    put("size_bytes", 42)
                    put("sha256_hex", file.checksum)
                },
                file,
            )
        }
        NStackAPI.validateMetadata(
            buildJsonObject {
                put("completed_at", "2026-01-01")
                put("size_bytes", "42")
                put("sha256_hex", file.checksum)
            },
            file,
        )
    }

    @Test
    fun unsafeOriginsRefused() {
        for (s in
            listOf(
                "http://example.com",
                "https://user:pass@example.com",
                "https://example.com/path",
                "https://example.com?x=y",
                "https://example.com/#foo",
            )) assertThrows(Exception::class.java) { NStackAPI.origin(s) }
        assertEquals("https://example.com", NStackAPI.origin("https://example.com/"))
    }

    @Test
    fun teachingExistingWordUpdatesReusableCorrectionInsteadOfCompetingWithIt() {
        val original = Rule("stable-id", "nosta", "nostr")
        val updated = Corrections.teach(listOf(original), "Nosta", "Nostr protocol")
        assertEquals(1, updated.size)
        assertEquals("stable-id", updated.single().id)
        assertEquals("Nostr protocol", Corrections.apply("nosta", updated))
    }
}

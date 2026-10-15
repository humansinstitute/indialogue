package com.wingmanbefree.indialogue

import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class SetupTest {
    private val npub = Bech32.encode("npub", ByteArray(32).also { it[31] = 1 })

    @Test
    fun delayedWorkspaceSuccessAndErrorCannotReviveChangedOriginOrIdentity(): Unit = runBlocking {
        var auth = AuthContext(npub, 1)
        val result = CompletableDeferred<List<Choice>>()
        val setup =
            NStackSetup(
                this,
                { auth },
                { _, _ -> withContext(NonCancellable) { result.await() } },
                { _, _, _ -> error("unused") },
            )
        setup.setOrigin("https://a.example")
        setup.discover()
        yield()
        setup.setOrigin("https://b.example")
        result.complete(listOf(Choice(uuid(), "Old A", npub)))
        yield()
        delay(5)
        assertTrue(setup.state.value.workspaces.isEmpty())
        assertFalse(setup.state.value.busy)
        assertEquals("https://b.example", setup.state.value.origin)
        val delayed = CompletableDeferred<List<Choice>>()
        val second =
            NStackSetup(
                this,
                { auth },
                { _, _ -> withContext(NonCancellable) { delayed.await() } },
                { _, _, _ -> error("unused") },
            )
        second.setOrigin("https://a.example")
        second.discover()
        yield()
        auth =
            AuthContext(
                npub,
                2,
            ) // Lock/unlock even the SAME identity invalidates its old authority.
        delayed.completeExceptionally(IllegalStateException("stale error"))
        yield()
        delay(5)
        second.refreshIdentity()
        assertTrue(second.state.value.workspaces.isEmpty())
        assertFalse(second.state.value.notice.contains("stale error"))
        assertThrows(Exception::class.java) { second.destination("Review", false) }
    }

    @Test
    fun delayedChannelsAgentsAndManualAuthorityCannotCrossWorkspace(): Unit = runBlocking {
        val auth = AuthContext(npub, 1)
        val w1 = Choice(uuid(), "One", npub)
        val w2 = Choice(uuid(), "Two", npub)
        val old = CompletableDeferred<NStackAPI.Discovery>()
        val current = CompletableDeferred<NStackAPI.Discovery>()
        val setup =
            NStackSetup(
                this,
                { auth },
                { _, _ -> listOf(w1, w2) },
                { _, w, _ ->
                    withContext(NonCancellable) { if (w == w1) old.await() else current.await() }
                },
            )
        setup.setOrigin("https://example.com")
        setup.discover()
        yield()
        setup.selectWorkspace(w1)
        yield()
        setup.selectWorkspace(w2)
        yield()
        val chosen = Choice(uuid(), "Current channel")
        current.complete(NStackAPI.Discovery(listOf(chosen), emptyList(), "Current", false))
        yield()
        delay(5)
        old.complete(
            NStackAPI.Discovery(
                listOf(Choice(uuid(), "Old channel")),
                listOf(Choice(npub, "Old agent")),
                "Old",
                true,
            )
        )
        yield()
        delay(5)
        assertEquals(w2, setup.state.value.workspace)
        assertEquals(listOf(chosen), setup.state.value.channels)
        assertTrue(setup.state.value.agents.isEmpty())
        assertFalse(setup.state.value.manualRecipient)
        setup.selectChannel(chosen)
        val destination = setup.destination("Review", true)
        assertEquals(w2.id, destination.workspace)
        assertEquals(chosen.id, destination.channel)
        setup.setOrigin("https://other.example")
        assertThrows(Exception::class.java) { setup.destination("Review", true) }
        assertEquals("", setup.state.value.recipient)
    }

    @Test
    fun editedAndWordCorrectedDraftsAreInvalidatedDurably() {
        val root = java.nio.file.Files.createTempDirectory("draft-test").toFile()
        try {
            val library = Library(root)
            val record = Recording(state = "saved", raw = "Monday raw", edited = "Monday")
            record.draft = "Monday draft"
            record.draftSource = sha(record.review.toByteArray())
            record.editReview("Tuesday")
            library.save(record)
            val reopened = library.get(record.id)
            assertNull(reopened.draft)
            assertThrows(Exception::class.java) { reopened.acceptDraft() }
            assertEquals("Monday raw", reopened.raw)
            reopened.draft = "Tuesday draft"
            reopened.draftSource = sha(reopened.review.toByteArray())
            reopened.editReview(
                Corrections.occurrence(
                    reopened.review,
                    Corrections.words(reopened.review).single().range,
                    "Wednesday",
                )
            )
            library.save(reopened)
            val again = library.get(record.id)
            assertNull(again.draft)
            assertEquals("Wednesday", again.review)
            assertEquals("Monday raw", again.raw)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun identityReplacementDiscardsDelayedReceivingAgentAuthority(): Unit = runBlocking {
        var auth = AuthContext(npub, 1)
        val old = CompletableDeferred<NStackAPI.Discovery>()
        val w = Choice(uuid(), "Old workspace", npub)
        val setup =
            NStackSetup(
                this,
                { auth },
                { _, _ -> listOf(w) },
                { _, _, _ -> withContext(NonCancellable) { old.await() } },
            )
        setup.setOrigin("https://example.com")
        setup.discover()
        yield()
        setup.selectWorkspace(w)
        yield()
        auth = AuthContext(Bech32.encode("npub", ByteArray(32).also { it[31] = 2 }), 2)
        old.complete(
            NStackAPI.Discovery(
                listOf(Choice(uuid(), "Old DM")),
                listOf(Choice(npub, "Old agent")),
                "Old authority",
                true,
            )
        )
        yield()
        delay(5)
        setup.refreshIdentity()
        assertTrue(setup.state.value.agents.isEmpty())
        assertTrue(setup.state.value.channels.isEmpty())
        assertFalse(setup.state.value.manualRecipient)
        assertThrows(Exception::class.java) { setup.destination("Review", false) }
    }
}

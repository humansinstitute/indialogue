package com.wingmanbefree.indialogue

import java.nio.file.Files
import java.io.File
import kotlinx.serialization.encodeToString
import org.junit.Assert.*
import org.junit.Test

class InputPreferenceTest {
    @Test fun clearPersistsAcrossReloadAndPreservesRecordings() {
        val root = Files.createTempDirectory("input-reset").toFile()
        try {
            val preference = File(root, "input.json")
            preference.writeText(codec.encodeToString(InputPreference(7, "Old headset", "old-address")))
            val audio = File(root, "recording.m4a").apply { writeText("retained-audio") }
            clearInputPreference(preference)
            assertFalse(File(root, "input.json").exists())
            assertEquals("retained-audio", audio.readText())
            clearInputPreference(preference)
            assertTrue(inputRouteAllowed(false, null, 9, 2000))
            assertFalse(inputRouteAllowed(true, 7, 9, 1000))
        } finally { root.deleteRecursively() }
    }

    @Test fun failedDeleteDoesNotPretendPreferenceWasCleared() {
        val root = Files.createTempDirectory("input-reset-failure").toFile()
        try {
            val blocked = File(root, "input.json").apply { mkdir(); File(this, "retained").writeText("keep") }
            assertThrows(IllegalStateException::class.java) { clearInputPreference(blocked) }
            assertTrue(blocked.exists())
        } finally { root.deleteRecursively() }
    }
}

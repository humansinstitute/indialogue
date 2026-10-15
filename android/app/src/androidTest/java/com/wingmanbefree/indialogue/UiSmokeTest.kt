package com.wingmanbefree.indialogue

import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import java.io.File
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Runs only on an explicitly selected isolated emulator. Never run on a user's device. */
@RunWith(AndroidJUnit4::class)
class UiSmokeTest {
    private val instrumentation
        get() = InstrumentationRegistry.getInstrumentation()

    private val device
        get() = UiDevice.getInstance(instrumentation)

    private fun click(text: String) {
        val item = device.wait(Until.findObject(By.text(text)), 10000)
        assertNotNull("Missing UI: $text", item)
        item.click()
        device.waitForIdle()
    }

    private fun start() {
        val context = instrumentation.targetContext
        context.startActivity(
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        device.waitForIdle()
    }

    @Test
    fun menusPermissionBackgroundSegmentsLibraryAndReopen() = runBlocking {
        assertTrue(
            "Use an isolated emulator",
            android.os.Build.FINGERPRINT.contains("generic") ||
                android.os.Build.MODEL.contains("sdk"),
        )
        start()
        click("Menu")
        click("Settings")
        assertNotNull(
            device.wait(Until.findObject(By.text("Saved: automatic deletion is off.")), 5000)
        )
        device.pressBack()
        click("Identity")
        assertNotNull(device.wait(Until.findObject(By.text("Paste nsec")), 5000))
        device.pressBack()
        click("NStack")
        assertNotNull(device.wait(Until.findObject(By.text("Discover workspaces")), 5000))
        device.pressBack()
        click("NStack uploads")
        assertNotNull(
            device.wait(
                Until.findObject(
                    By.text("No uploads yet. Configure NStack or use Upload on a saved recording.")
                ),
                5000,
            )
        )
        device.pressBack()
        device.pressBack()
        click("Start recording")
        val deny =
            device.wait(
                Until.findObject(
                    By.res("com.android.permissioncontroller", "permission_deny_button")
                ),
                5000,
            )
        if (deny != null) {
            deny.click()
            assertNotNull(
                device.wait(Until.findObject(By.textContains("Microphone permission denied")), 5000)
            )
            click("Dismiss notice")
            click("Start recording")
        }
        val allow =
            device.wait(
                Until.findObject(
                    By.res(
                        "com.android.permissioncontroller",
                        "permission_allow_foreground_only_button",
                    )
                ),
                5000,
            )
        allow?.click()
        assertNotNull(device.wait(Until.findObject(By.text("Stop and save")), 10000))
        assertNotNull(device.findObject(By.textContains("Actual input:")))
        val captureApp = instrumentation.targetContext.applicationContext as DialogueApp
        val captureId = checkNotNull(captureApp.active.value)
        val captureTitle = captureApp.library.get(captureId).title
        var refusedEdit = false
        instrumentation.runOnMainSync {
            try {
                captureApp.update(captureId) {
                    it.title = "Stale active edit"
                    it.editReview("Must not be overwritten")
                }
            } catch (_: IllegalStateException) {
                refusedEdit = true
            }
        }
        assertTrue("Active metadata edits must be refused", refusedEdit)
        delay(16000)
        device.pressHome()
        delay(3000)
        start()
        click("Stop and save")
        delay(2000)
        val app = instrumentation.targetContext.applicationContext as DialogueApp
        val saved = app.library.all().first()
        assertEquals("saved", saved.state)
        assertEquals(captureTitle, saved.title)
        assertNull(saved.edited)
        assertTrue("15s segmented AAC", saved.segments.size >= 2)
        assertTrue(saved.durationMs >= 17000)
        assertTrue(saved.segments.all { File(app.library.directory(saved.id), it).length() > 0 })
        assertEquals("failed", app.library.get(saved.id).speech)
        assertTrue(app.library.get(saved.id).notice!!.contains("not installed"))
        if (device.hasObject(By.text("Dismiss notice"))) click("Dismiss notice")
        click("Menu")
        click("Recordings")
        click(saved.title)
        assertNotNull(device.wait(Until.findObject(By.text("Play full audio")), 5000))
        click("Play full audio")
        delay(500)
        assertNotNull(device.wait(Until.findObject(By.text("Stop playback")), 5000))
        click("Stop playback")
        device.pressHome()
        start()
        assertNotNull(device.wait(Until.findObject(By.text("Play full audio")), 5000))
        println(
            "UI_EVIDENCE saved=${saved.id} segments=${saved.segments.size} duration_ms=${saved.durationMs} actual_routes=${saved.events}"
        )
    }
}

package com.wingmanbefree.indialogue

import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import android.view.WindowManager
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

    private fun clearAccessibilityCache() {
        if (android.os.Build.VERSION.SDK_INT >= 33) instrumentation.uiAutomation.clearCache()
    }

    private fun click(text: String) {
        instrumentation.waitForIdleSync()
        clearAccessibilityCache()
        val item = device.wait(Until.findObject(if (text == "Menu") By.desc("Menu") else By.text(text)), 10000)
        assertNotNull("Missing UI: $text", item)
        item.click()
        instrumentation.waitForIdleSync()
        Thread.sleep(400)
        device.waitForIdle()
        clearAccessibilityCache()
    }

    private fun screenshot(app: DialogueApp, name: String) {
        var activities = emptyList<android.app.Activity>()
        instrumentation.runOnMainSync {
            activities = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).toList()
            assertTrue("Screenshot requires an actual resumed isolated activity", activities.isNotEmpty())
            activities.forEach {
                it.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                it.window.decorView.postInvalidateOnAnimation()
            }
        }
        try {
            // Secure surface changes take effect on the next compositor frame, after main idle.
            instrumentation.waitForIdleSync()
            Thread.sleep(500)
            device.waitForIdle()
            assertTrue(device.takeScreenshot(File(app.getExternalFilesDir(null), "$name.png")))
        } finally {
            instrumentation.runOnMainSync { activities.forEach { it.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE) } }
        }
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
        click("New recording")
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
            click("New recording")
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
        assertNotNull(device.wait(Until.findObject(By.text("Stop and transcribe locally")), 10000))
        assertTrue((instrumentation.targetContext.applicationContext as DialogueApp).route.value.isNotBlank())
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
        click("Stop and transcribe locally")
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
        // The library is an iPhone-style section below preferences and diagnostics.
        repeat(5) {
            if (!device.hasObject(By.text(saved.title))) {
                device.swipe(device.displayWidth / 2, device.displayHeight * 4 / 5, device.displayWidth / 2, device.displayHeight / 3, 30)
                device.waitForIdle()
                clearAccessibilityCache()
            }
        }
        if (!device.hasObject(By.text(saved.title))) device.dumpWindowHierarchy(File(app.getExternalFilesDir(null), "library-menu-failure.xml"))
        screenshot(app, "android-library")
        click(saved.title)
        if (device.wait(Until.findObject(By.text("Play full audio")), 5000) == null) {
            device.dumpWindowHierarchy(File(app.getExternalFilesDir(null), "library-failure.xml"))
        }
        assertNotNull(device.wait(Until.findObject(By.text("Play full audio")), 5000))
        screenshot(app, "android-recording-details")
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

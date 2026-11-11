package com.wingmanbefree.indialogue

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.*
import java.io.File
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Screenshots disable secure-window protection only in instrumentation on an isolated emulator. */
@RunWith(AndroidJUnit4::class)
class ParityUiTest {
    @Test fun referenceHierarchyModesMenusVoiceAndAudioOnlyCapture() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val app = instrumentation.targetContext.applicationContext as DialogueApp
        val device = UiDevice.getInstance(instrumentation)
        assertTrue(android.os.Build.MODEL.contains("sdk") || android.os.Build.FINGERPRINT.contains("generic"))
        var activity: Activity? = null
        val callbacks = object : Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(a: Activity) {
                activity = a
                a.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            }
            override fun onActivityCreated(a: Activity, b: Bundle?) {}
            override fun onActivityStarted(a: Activity) {}
            override fun onActivityPaused(a: Activity) {}
            override fun onActivityStopped(a: Activity) {}
            override fun onActivitySaveInstanceState(a: Activity, b: Bundle) {}
            override fun onActivityDestroyed(a: Activity) {}
        }
        instrumentation.runOnMainSync { app.registerActivityLifecycleCallbacks(callbacks) }
        fun click(label: String) {
            repeat(3) { attempt ->
                try {
                    val item = device.wait(Until.findObject(By.text(label)), 10000)
                    assertNotNull("Missing $label", item)
                    item.click(); instrumentation.waitForIdleSync(); Thread.sleep(500); device.waitForIdle()
                    return
                } catch (e: StaleObjectException) { if (attempt == 2) throw e; Thread.sleep(300) }
            }
        }
        fun menu() {
            val item = device.wait(Until.findObject(By.desc("Menu")), 10000)
            assertNotNull(item); item.click(); instrumentation.waitForIdleSync(); Thread.sleep(400); device.waitForIdle()
        }
        fun shot(name: String) {
            device.waitForIdle()
            assertTrue(device.takeScreenshot(File(app.getExternalFilesDir(null), "$name.png")))
        }
        try {
            app.startActivity(Intent(app, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
            assertNotNull(device.wait(Until.findObject(By.text("New recording")), 10000))
            shot("android-capture")
            click("Channel")
            assertEquals(DialogueMode.Channel, app.transfers.ledger.routing.mode)
            click("New recording")
            device.wait(Until.findObject(By.res("com.android.permissioncontroller", "permission_allow_foreground_only_button")), 3000)?.click()
            assertNotNull(device.wait(Until.findObject(By.textContains("Configure the Channel route")), 10000))
            click("Dismiss notice"); click("Normal")
            menu(); shot("android-menu")
            click("Settings"); shot("android-settings")
            assertNotNull(device.wait(Until.findObject(By.text("Saved: automatic deletion is off.")), 5000))
            device.pressBack(); Thread.sleep(500); click("NStack"); shot("android-setup")
            device.pressBack(); Thread.sleep(500); click("Reply voice")
            assertNotNull(device.wait(Until.findObject(By.text("Automatically listen to new replies")), 5000))
            shot("android-voice")
            device.pressBack(); Thread.sleep(500); device.pressBack(); Thread.sleep(500)
            click("New recording")
            assertNotNull(device.wait(Until.findObject(By.text("Stop, upload & publish audio")), 10000))
            Thread.sleep(2000); shot("android-recording")
            click("Stop, upload & publish audio")
            assertNotNull(device.wait(Until.findObject(By.text("New recording")), 10000))
            val recording = app.library.all().first()
            assertTrue(recording.audioOnly)
            assertEquals("none", recording.speech)
            assertTrue(recording.notice!!.contains("Audio saved"))
            assertTrue(recording.segments.isNotEmpty())
            assertTrue(File(app.library.directory(recording.id), recording.segments.first()).length() > 0)
            println("PARITY_EVIDENCE audio-only saved; no transcription requested; screenshot directory=${app.getExternalFilesDir(null)}")
        } finally {
            instrumentation.runOnMainSync {
                activity?.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                app.unregisterActivityLifecycleCallbacks(callbacks)
            }
        }
    }
}

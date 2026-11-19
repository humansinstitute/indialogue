package com.wingmanbefree.indialogue

import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.*
import java.io.File
import kotlinx.serialization.encodeToString
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MicrophoneResetTest {
    @Test fun staleSelectionClearsDurablyAndPickerRefreshesWithoutDeletingLibrary() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val app = instrumentation.targetContext.applicationContext as DialogueApp
        val device = UiDevice.getInstance(instrumentation)
        check(android.os.Build.MODEL.contains("sdk") || android.os.Build.FINGERPRINT.contains("generic"))
        device.executeShellCommand("pm grant ${app.packageName} android.permission.RECORD_AUDIO")
        val preference = File(app.root, "input.json")
        val saved = Recording(title = "Microphone reset retained recording", state = "saved")
        instrumentation.runOnMainSync {
            app.library.save(saved)
            preference.writeText(codec.encodeToString(InputPreference(7, "Old paired headset", "synthetic-old-address")))
            app.reloadInputPreference()
            app.refresh()
        }
        fun click(label: String) {
            val item = device.wait(Until.findObject(By.text(label)), 10000)
            assertNotNull("Missing $label", item)
            item.click(); instrumentation.waitForIdleSync(); device.waitForIdle()
        }
        try {
            app.startActivity(Intent(app, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
            assertNotNull(device.wait(Until.findObject(By.textContains("Old paired headset")), 10000))
            click("Old paired headset unavailable · System default")
            click("Refresh microphones")
            assertNotNull(device.wait(Until.findObject(By.text("Clear saved microphones")), 5000))
            click("Clear saved microphones")
            assertFalse(preference.exists())
            assertNull(app.preferredInput)
            assertEquals(0, app.input.value)
            assertEquals("System default", app.route.value)
            assertNull(device.findObject(By.textContains("Old paired headset")))
            assertEquals(saved.title, app.library.get(saved.id).title)
            instrumentation.runOnMainSync { app.reloadInputPreference() }
            assertNull(app.preferredInput)
            instrumentation.runOnMainSync {
                app.capturePending.value = true
                assertThrows(IllegalStateException::class.java) { app.clearSavedMicrophones() }
                app.capturePending.value = false
                app.active.value = "synthetic-active"
                assertThrows(IllegalStateException::class.java) { app.clearSavedMicrophones() }
                app.active.value = null
            }
        } finally {
            instrumentation.runOnMainSync {
                app.capturePending.value = false
                app.active.value = null
                app.clearSavedMicrophones()
            }
        }
    }
}

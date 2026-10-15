package com.wingmanbefree.indialogue

import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class IdentityUiTest {
    @Test
    fun secureUnlockWrongPinBackgroundMemoryAndManualLock(): Unit = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val app = context.applicationContext as DialogueApp
        val device = UiDevice.getInstance(instrumentation)
        assertTrue(android.os.Build.MODEL.contains("sdk"))
        assertFalse("Isolated emulator must have no user identity", app.identity.exists)
        fun click(text: String) {
            val item = device.wait(Until.findObject(By.text(text)), 8000)
            assertNotNull(text, item)
            item.click()
            device.waitForIdle()
        }
        fun launch() {
            context.startActivity(
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            device.waitForIdle()
        }
        try {
            withContext(Dispatchers.Main) {
                app.identity.create(
                    Bech32.encode("nsec", ByteArray(32).also { it[31] = 3 }),
                    "123456",
                )
                app.lock()
                app.notice.value = ""
            }
            launch()
            assertNotNull(device.wait(Until.findObject(By.text("Unlock your identity")), 8000))
            val pin = device.findObject(By.clazz("android.widget.EditText"))
            assertNotNull(pin)
            pin.text = "999999"
            click("Unlock")
            assertNotNull(
                device.wait(
                    Until.findObject(By.textContains("Incorrect PIN or damaged vault")),
                    5000,
                )
            )
            assertTrue(app.identity.exists)
            assertFalse(app.identity.unlocked)
            device.findObject(By.clazz("android.widget.EditText")).text = "123456"
            device.waitForIdle()
            click("Unlock")
            withTimeout(10000) {
                while (!withContext(Dispatchers.Main) { app.identity.unlocked }) delay(20)
            }
            assertTrue(app.identity.unlocked)
            click("Menu")
            click("Identity")
            assertNotNull(
                device.wait(Until.findObject(By.text("Imported identity · unlocked")), 5000)
            )
            device.pressHome()
            withTimeout(5000) { while (app.foreground.value) delay(20) }
            launch()
            assertTrue(app.identity.unlocked)
            assertFalse(device.hasObject(By.text("Unlock your identity")))
            click("Lock")
            assertNotNull(
                device.wait(Until.findObject(By.text("Imported identity · locked")), 5000)
            )
            device.pressHome()
            withTimeout(5000) { while (app.foreground.value) delay(20) }
            launch()
            assertNotNull(device.wait(Until.findObject(By.text("Unlock your identity")), 8000))
            click("Continue locked")
            assertFalse(app.identity.unlocked)
        } finally {
            withContext(Dispatchers.Main) {
                app.onBackground()
                app.identity.remove()
                app.refresh()
            }
            repeat(3) {
                device.pressBack()
                device.waitForIdle()
            }
        }
    }
}

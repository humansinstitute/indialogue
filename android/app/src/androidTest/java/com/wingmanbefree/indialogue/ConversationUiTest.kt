package com.wingmanbefree.indialogue

import android.content.Intent
import android.view.WindowManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.*
import java.io.File
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ConversationUiTest {
    @Test fun largeReplyControlsAndRespondedOnlyAfterAcceptedFollowup(): Unit = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val app = instrumentation.targetContext.applicationContext as DialogueApp
        val device = UiDevice.getInstance(instrumentation)
        assertTrue(android.os.Build.MODEL.contains("sdk"))
        assertFalse(app.identity.exists)
        val controller = app.replies
        val originalLoader = controller.loadMessages
        val added = mutableListOf<Transfer>()
        val monitor = instrumentation.addMonitor(MainActivity::class.java.name, null, false)
        var activity: android.app.Activity? = null
        // Direct ledger mutations do not come from UI input; flush UiAutomation's cached nodes
        // while waiting for Compose's frame and accessibility event delivery.
        fun control(description: String): UiObject2? {
            val deadline = System.currentTimeMillis() + 5000
            do {
                instrumentation.waitForIdleSync()
                if (android.os.Build.VERSION.SDK_INT >= 33) instrumentation.uiAutomation.clearCache()
                device.findObject(By.desc(description))?.let { return it }
                Thread.sleep(100)
            } while (System.currentTimeMillis() < deadline)
            return null
        }
        try {
            withContext(Dispatchers.Main) {
                app.identity.create(Bech32.encode("nsec", ByteArray(32).also { it[31] = 6 }), "123456")
                val d = Destination("https://example.invalid", app.identity.npub(), uuid(), "Synthetic", app.identity.npub(), uuid(), "No recipient headline", "Review")
                val route = DialogueRoute(d, DialogueMode.Channel)
                val job = Transfer(recordingId = uuid(), destination = d, title = "Synthetic", body = "", files = emptyList(), state = "sent", threadId = uuid(), route = route)
                added.add(job); app.transfers.jobs.add(job)
                controller.saveAutoListen(false)
                controller.loadMessages = { listOf(buildJsonObject { put("id", "synthetic-reply"); put("body", "This is a synthetic reply used to inspect the native conversation controls.") }) }
                app.refresh()
                app.startActivity(Intent(app, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
            }
            activity = monitor.waitForActivityWithTimeout(10000)
            assertNotNull(activity)
            instrumentation.runOnMainSync { activity!!.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE) }
            val expand = device.wait(Until.findObject(By.textStartsWith("Conversation")), 10000)
            assertNotNull(expand); expand.click()
            assertNotNull(device.wait(Until.findObject(By.desc("Listen")), 10000))
            assertNotNull(device.findObject(By.desc("Record response")))
            assertFalse(device.hasObject(By.text("No recipient headline")))
            device.takeScreenshot(File(app.getExternalFilesDir(null), "android-conversation.png"))
            val response = added.first().copy(id = uuid(), recordingId = uuid(), state = "failed", route = added.first().route!!.copy(threadId = added.first().threadId, respondingToReplyId = "synthetic-reply"))
            withContext(Dispatchers.Main) { added.add(response); app.transfers.jobs.add(response); app.refresh() }
            val failed = control("Response failed · Retry")
            if (failed == null) {
                device.dumpWindowHierarchy(File(app.getExternalFilesDir(null), "conversation-failure.xml"))
                device.takeScreenshot(File(app.getExternalFilesDir(null), "conversation-failure.png"))
                println("CONVERSATION_STATE revision=${app.revision.value} jobs=${app.transfers.jobs.map { it.id to it.state }} reply=${controller.replies} response=${responseTransfer(app.transfers.jobs, "synthetic-reply")}")
            }
            assertNotNull(failed)
            assertFalse(device.hasObject(By.desc("Responded")))
            withContext(Dispatchers.Main) { response.state = "cancelled"; app.refresh() }
            assertNotNull(control("Listen"))
            assertTrue(device.findObject(By.desc("Record response")).isEnabled)
            withContext(Dispatchers.Main) { response.state = "sent"; app.refresh() }
            assertNotNull(control("Responded"))
            device.takeScreenshot(File(app.getExternalFilesDir(null), "android-responded.png"))
        } finally {
            withContext(Dispatchers.Main) {
                activity?.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                controller.stop(); controller.loadMessages = originalLoader; controller.saveAutoListen(true)
                app.transfers.jobs.removeAll(added.toSet())
                app.identity.remove(); app.refresh()
            }
            instrumentation.removeMonitor(monitor)
        }
    }
}

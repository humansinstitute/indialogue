package com.wingmanbefree.indialogue

import android.media.AudioDeviceInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Simulates Android: a connected Bluetooth headset mic only becomes the actual input once SCO/communication routing is requested. */
private class FakePlatform(var sdk: Int, val communication: List<RouteDevice>) : CommunicationRoute {
    var scoActive = false
    val calls = mutableListOf<String>()
    override val sdkInt get() = sdk
    var mode = 0
    var failOn: String? = null
    private fun maybeFail(op: String) { if (failOn == op) throw SecurityException("denied $op") }
    override var audioMode: Int
        get() = mode
        set(v) { calls += "mode:$v"; mode = v }
    override fun communicationDevices() = communication
    override fun setCommunicationDevice(id: Int): Boolean { maybeFail("set"); calls += "set:$id"; scoActive = communication.any { it.id == id }; return scoActive }
    override fun clearCommunicationDevice() { maybeFail("clear"); calls += "clear"; scoActive = false }
    override fun startBluetoothSco() { maybeFail("startSco"); calls += "startSco"; scoActive = true }
    override fun stopBluetoothSco() { maybeFail("stopSco"); calls += "stopSco"; scoActive = false }
    /** What MediaRecorder.routedDevice would report. */
    fun routedInputId(preferred: Int, builtIn: Int) = if (scoActive) preferred else builtIn
}

class BluetoothInputRouteTest {
    private val scoIn = RouteDevice(10, AudioDeviceInfo.TYPE_BLUETOOTH_SCO, "AA:BB")
    private val scoOut = RouteDevice(11, AudioDeviceInfo.TYPE_BLUETOOTH_SCO, "AA:BB")

    @Test fun selectedBluetoothMicNeverBecomesActualInputWithoutNegotiation() {
        val p = FakePlatform(33, listOf(scoOut))
        // Old behaviour: nothing negotiated, strict check stops capture after the grace window.
        assertFalse(inputRouteAllowed(true, scoIn.id, p.routedInputId(scoIn.id, 3), 1500))
    }

    @Test fun engagingNegotiatesCommunicationDeviceSoStrictCheckPasses() {
        val p = FakePlatform(33, listOf(scoOut))
        val s = InputRouteSession(p)
        assertNull(s.engage(scoIn))
        assertEquals(listOf("mode:3", "set:11"), p.calls)
        assertTrue(inputRouteAllowed(true, scoIn.id, p.routedInputId(scoIn.id, 3), 1500))
        s.release()
        assertEquals(listOf("mode:3", "set:11", "clear", "mode:0"), p.calls)
        assertFalse(p.scoActive)
    }

    @Test fun legacyPlatformsUseBluetoothSco() {
        val p = FakePlatform(30, emptyList())
        val s = InputRouteSession(p)
        assertNull(s.engage(scoIn))
        s.release()
        assertEquals(listOf("mode:3", "startSco", "stopSco", "mode:0"), p.calls)
    }

    @Test fun builtInAndWiredInputsAreNeverTouched() {
        val p = FakePlatform(33, listOf(scoOut))
        val s = InputRouteSession(p)
        assertNull(s.engage(RouteDevice(3, AudioDeviceInfo.TYPE_BUILTIN_MIC, "")))
        assertNull(s.engage(null))
        s.release()
        assertTrue(p.calls.isEmpty())
    }

    @Test fun refusedNegotiationIsReportedAndNothingLeaks() {
        val p = FakePlatform(33, emptyList())
        val s = InputRouteSession(p)
        assertNotNull(s.engage(scoIn))
        assertEquals(listOf("mode:3", "mode:0"), p.calls) // mode restored, nothing left engaged
        assertEquals(0, p.mode)
        s.release()
    }

    @Test fun bluetoothNeedsLongerVerificationWindowThanWired() {
        assertTrue(inputRouteAllowed(true, 10, 3, 3000, graceMs = bluetoothVerificationGraceMs))
        assertFalse(inputRouteAllowed(true, 10, 3, 6000, graceMs = bluetoothVerificationGraceMs))
        assertFalse(inputRouteAllowed(true, 10, 3, 3000))
    }

    @Test fun deniedPermissionIsReportedAndRestoresModeWithoutThrowing() {
        for (op in listOf("set", "startSco")) {
            val p = FakePlatform(if (op == "set") 33 else 30, listOf(scoOut)).apply { failOn = op }
            val s = InputRouteSession(p)
            assertTrue(s.engage(scoIn)!!.contains("denied"))
            assertEquals(0, p.mode)
            s.release()
        }
    }

    @Test fun releaseFailureCannotBreakStopAndStillRestoresMode() {
        val p = FakePlatform(33, listOf(scoOut))
        val s = InputRouteSession(p)
        assertNull(s.engage(scoIn))
        p.failOn = "clear"
        s.release() // must not throw: stopCapture retains audio after this
        assertEquals(0, p.mode)
        s.release() // idempotent
        assertEquals(1, p.calls.count { it == "mode:0" })
    }

    @Test fun preferenceStillMatchesAfterCommunicationActivationChangesDeviceIds() {
        // Saved preference identity is type/name/address; Android may renumber ids when SCO activates.
        val saved = InputPreference(AudioDeviceInfo.TYPE_BLUETOOTH_SCO, "Buds", "AA:BB")
        val beforeIds = listOf(RouteDevice(10, saved.type, saved.address))
        val afterIds = listOf(RouteDevice(42, saved.type, saved.address))
        fun resolve(l: List<RouteDevice>) = l.firstOrNull { it.type == saved.type && it.address == saved.address }
        assertEquals(10, resolve(beforeIds)!!.id)
        val after = resolve(afterIds)!!
        assertTrue(inputRouteAllowed(true, after.id, 42, 4000, graceMs = bluetoothVerificationGraceMs))
        assertFalse(inputRouteAllowed(true, after.id, 3, 6000, graceMs = bluetoothVerificationGraceMs))
    }
}

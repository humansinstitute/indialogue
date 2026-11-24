package com.wingmanbefree.indialogue

import android.media.AudioDeviceInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Simulates Android: a connected Bluetooth headset mic only becomes the actual input once SCO/communication routing is requested. */
private class FakePlatform(var sdk: Int, val communication: List<RouteDevice>) : CommunicationRoute {
    var scoActive = false
    val calls = mutableListOf<String>()
    override val sdkInt get() = sdk
    override fun communicationDevices() = communication
    override fun setCommunicationDevice(id: Int): Boolean { calls += "set:$id"; scoActive = communication.any { it.id == id }; return scoActive }
    override fun clearCommunicationDevice() { calls += "clear"; scoActive = false }
    override fun startBluetoothSco() { calls += "startSco"; scoActive = true }
    override fun stopBluetoothSco() { calls += "stopSco"; scoActive = false }
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
        assertTrue(s.engage(scoIn))
        assertEquals(listOf("set:11"), p.calls)
        assertTrue(inputRouteAllowed(true, scoIn.id, p.routedInputId(scoIn.id, 3), 1500))
        s.release()
        assertEquals(listOf("set:11", "clear"), p.calls)
        assertFalse(p.scoActive)
    }

    @Test fun legacyPlatformsUseBluetoothSco() {
        val p = FakePlatform(30, emptyList())
        val s = InputRouteSession(p)
        assertTrue(s.engage(scoIn))
        s.release()
        assertEquals(listOf("startSco", "stopSco"), p.calls)
    }

    @Test fun builtInAndWiredInputsAreNeverTouched() {
        val p = FakePlatform(33, listOf(scoOut))
        val s = InputRouteSession(p)
        assertTrue(s.engage(RouteDevice(3, AudioDeviceInfo.TYPE_BUILTIN_MIC, "")))
        assertTrue(s.engage(null))
        s.release()
        assertTrue(p.calls.isEmpty())
    }

    @Test fun refusedNegotiationIsReportedAndNothingLeaks() {
        val p = FakePlatform(33, emptyList())
        val s = InputRouteSession(p)
        assertFalse(s.engage(scoIn))
        s.release()
        assertTrue(p.calls.isEmpty())
    }

    @Test fun bluetoothNeedsLongerVerificationWindowThanWired() {
        assertTrue(inputRouteAllowed(true, 10, 3, 3000, graceMs = bluetoothVerificationGraceMs))
        assertFalse(inputRouteAllowed(true, 10, 3, 6000, graceMs = bluetoothVerificationGraceMs))
        assertFalse(inputRouteAllowed(true, 10, 3, 3000))
    }
}

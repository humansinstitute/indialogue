package com.wingmanbefree.indialogue

import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build

internal data class RouteDevice(val id: Int, val type: Int, val address: String)

/** Platform seam for Bluetooth headset routing; a selected headset mic is only usable once this link is requested. */
internal interface CommunicationRoute {
    val sdkInt: Int
    fun communicationDevices(): List<RouteDevice>
    fun setCommunicationDevice(id: Int): Boolean
    fun clearCommunicationDevice()
    fun startBluetoothSco()
    fun stopBluetoothSco()
    var audioMode: Int
}

internal fun needsCommunicationRoute(type: Int) =
    type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO || (Build.VERSION.SDK_INT >= 31 && type == AudioDeviceInfo.TYPE_BLE_HEADSET)

internal const val MODE_NORMAL = 0
internal const val MODE_IN_COMMUNICATION = 3

/** Requests and later releases the Bluetooth communication route around one capture; never throws. */
internal class InputRouteSession(private val route: CommunicationRoute) {
    private var engaged = false
    private var legacy = false
    private var previousMode: Int? = null

    /** Null when no negotiation is needed or it was requested; otherwise why Android refused it. */
    fun engage(preferred: RouteDevice?): String? {
        if (preferred == null || !needsCommunicationRoute(preferred.type)) return null
        try {
            previousMode = route.audioMode
            route.audioMode = MODE_IN_COMMUNICATION
            if (route.sdkInt >= 31) {
                val sink = route.communicationDevices()
                    .firstOrNull { it.type == preferred.type && it.address == preferred.address }
                    ?: return refuse("Android lists no communication device for this headset.")
                engaged = route.setCommunicationDevice(sink.id)
                if (!engaged) return refuse("Android refused the Bluetooth communication route.")
            } else {
                route.startBluetoothSco()
                engaged = true
                legacy = true
            }
            return null
        } catch (e: Exception) {
            return refuse("Bluetooth route request failed: ${e.message}")
        }
    }

    private fun refuse(reason: String): String { release(); return reason }

    fun release() {
        val wasEngaged = engaged
        val wasLegacy = legacy
        val mode = previousMode
        engaged = false; legacy = false; previousMode = null
        if (wasEngaged) runCatching { if (wasLegacy) route.stopBluetoothSco() else route.clearCommunicationDevice() }
        if (mode != null) runCatching { route.audioMode = mode }
    }
}

internal class AndroidCommunicationRoute(private val audio: AudioManager) : CommunicationRoute {
    override val sdkInt get() = Build.VERSION.SDK_INT
    override var audioMode: Int
        get() = audio.mode
        set(value) { audio.mode = value }
    private fun AudioDeviceInfo.toRoute() = RouteDevice(id, type, address)
    private val sinks = mutableMapOf<Int, AudioDeviceInfo>()

    override fun communicationDevices(): List<RouteDevice> {
        if (Build.VERSION.SDK_INT < 31) return emptyList()
        sinks.clear()
        return audio.availableCommunicationDevices.map { sinks[it.id] = it; it.toRoute() }
    }

    override fun setCommunicationDevice(id: Int): Boolean =
        Build.VERSION.SDK_INT >= 31 && sinks[id]?.let { audio.setCommunicationDevice(it) } == true

    override fun clearCommunicationDevice() { if (Build.VERSION.SDK_INT >= 31) audio.clearCommunicationDevice() }
    @Suppress("DEPRECATION") override fun startBluetoothSco() = audio.startBluetoothSco()
    @Suppress("DEPRECATION") override fun stopBluetoothSco() = audio.stopBluetoothSco()
}

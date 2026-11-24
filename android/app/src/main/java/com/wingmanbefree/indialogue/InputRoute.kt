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
}

internal fun needsCommunicationRoute(type: Int) =
    type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO || (Build.VERSION.SDK_INT >= 31 && type == AudioDeviceInfo.TYPE_BLE_HEADSET)

/** Requests and later releases the Bluetooth communication route around one capture. */
internal class InputRouteSession(private val route: CommunicationRoute) {
    private var engaged = false
    private var legacy = false

    /** True when no negotiation is needed or it was requested; false when Android refused it. */
    fun engage(preferred: RouteDevice?): Boolean {
        if (preferred == null || !needsCommunicationRoute(preferred.type)) return true
        if (route.sdkInt >= 31) {
            val sink = route.communicationDevices()
                .firstOrNull { it.type == preferred.type && it.address == preferred.address } ?: return false
            engaged = route.setCommunicationDevice(sink.id)
            return engaged
        }
        route.startBluetoothSco()
        engaged = true
        legacy = true
        return true
    }

    fun release() {
        if (!engaged) return
        if (legacy) route.stopBluetoothSco() else route.clearCommunicationDevice()
        engaged = false
        legacy = false
    }
}

internal class AndroidCommunicationRoute(private val audio: AudioManager) : CommunicationRoute {
    override val sdkInt get() = Build.VERSION.SDK_INT
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

@file:Suppress("DEPRECATION")
package io.github.gbettineschi.keepressomobile

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.os.SystemClock
import io.github.gbettineschi.keepressomobile.core.NearbyGattV2
import io.github.gbettineschi.keepressomobile.core.PeripheralLink
import java.util.UUID

/** Android advertises, but remains the v1 authentication client. Never requests an OS bond. */
@SuppressLint("MissingPermission")
class BlePeripheral(
    private val context: Context,
    private val state: (String) -> Unit,
    private val subscribed: () -> Unit,
    private val record: (String) -> Unit,
    private val disconnected: () -> Unit,
    private val availabilityChanged: (Boolean) -> Unit = {}
) {
    private val handler = Handler(Looper.getMainLooper())
    private val link = PeripheralLink()
    private var server: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var advertisingCallback: AdvertiseCallback? = null
    private var advertisingReady = false
    private var output: BluetoothGattCharacteristic? = null
    private var central: BluetoothDevice? = null
    private var notificationToken = 0
    private var handshakeTimer: Runnable? = null
    private var frameTimer: Runnable? = null
    val isRunning: Boolean get() = server != null

    // Each server gets a fresh callback capturing its epoch. A late callback from
    // close/restart cannot select a central, complete a notification or deliver bytes.
    private fun callback(epoch: Int) = object : BluetoothGattServerCallback() {
        private fun current() = epoch == link.generation && server != null
        override fun onServiceAdded(status: Int, service: BluetoothGattService) { handler.post {
            if (!current() || service.uuid != SERVICE) return@post
            if (status != BluetoothGatt.GATT_SUCCESS) close("Nearby Bluetooth service unavailable")
            else advertise(epoch)
        } }
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) { handler.post {
            if (!current()) return@post
            if (status != BluetoothGatt.GATT_SUCCESS || newState == BluetoothProfile.STATE_DISCONNECTED) {
                if (link.disconnect(epoch, device.address)) close("Unreachable")
                return@post
            }
            // CONNECTED is shared physical-link noise, including existing clients
            // reported before addService/advertising. Select only at our CCCD write;
            // never cancel a connection belonging to another app.
        } }
        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) { handler.post {
            if (current()) link.mtu(epoch, device.address, mtu)
        } }
        override fun onDescriptorReadRequest(device: BluetoothDevice, requestId: Int, offset: Int, descriptor: BluetoothGattDescriptor) { handler.post {
            if (!current()) return@post
            val valid = output != null && descriptor.uuid == CCCD && descriptor.characteristic === output && link.canSubscribe(epoch, device.address)
            val status = if (!valid) BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED else if (offset != 0) BluetoothGatt.GATT_INVALID_OFFSET else BluetoothGatt.GATT_SUCCESS
            val value = if (valid && link.accepts(epoch, device.address)) BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE else BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
            respond(device, requestId, status, value)
        } }
        override fun onDescriptorWriteRequest(device: BluetoothDevice, requestId: Int, descriptor: BluetoothGattDescriptor, preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray) {
            val immutable = value.copyOf()
            handler.post {
                if (!current()) return@post
                val valid = output != null && descriptor.uuid == CCCD && descriptor.characteristic === output && !preparedWrite && offset == 0 && responseNeeded
                val enable = immutable.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                val disable = immutable.contentEquals(BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE)
                val accepted = valid && ((enable && link.canSubscribe(epoch, device.address)) || (disable && link.owns(epoch, device.address)))
                if (responseNeeded && !respond(device, requestId, if (accepted) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED)) return@post
                if (!accepted) return@post
                if (disable) { if (link.accepts(epoch, device.address)) close("Nearby notifications disabled"); return@post }
                if (link.subscribe(epoch, device.address)) {
                    central = device
                    state("Authenticating…")
                    handshakeTimer = Runnable { if (current()) close("Authorization timed out") }.also { handler.postDelayed(it, 300000) }
                    scheduleFrameExpiry(epoch, device)
                    subscribed()
                }
            }
        }
        override fun onCharacteristicWriteRequest(device: BluetoothDevice, requestId: Int, characteristic: BluetoothGattCharacteristic, preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray) {
            val immutable = value.copyOf()
            handler.post {
                if (!current()) return@post
                val valid = link.accepts(epoch, device.address) && characteristic.uuid == INPUT && !preparedWrite && responseNeeded && offset == 0 && immutable.size in 1..512
                if (responseNeeded && !respond(device, requestId, if (valid) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED)) return@post
                if (!valid) {
                    if (link.owns(epoch, device.address)) close("Invalid Bluetooth write; connection closed")
                    return@post
                }
                try {
                    val records = link.receive(epoch, device.address, immutable, SystemClock.elapsedRealtime())
                    for (text in records) { if (!current() || !link.accepts(epoch, device.address)) break; record(text) }
                } catch (_: Exception) { close("Invalid secure record; connection closed") }
            }
        }
        override fun onCharacteristicReadRequest(device: BluetoothDevice, requestId: Int, offset: Int, characteristic: BluetoothGattCharacteristic) { handler.post {
            if (current()) respond(device, requestId, BluetoothGatt.GATT_READ_NOT_PERMITTED)
        } }
        override fun onExecuteWrite(device: BluetoothDevice, requestId: Int, execute: Boolean) { handler.post {
            if (current()) respond(device, requestId, BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED)
        } }
        override fun onNotificationSent(device: BluetoothDevice, status: Int) { handler.post {
            if (!current() || !link.accepts(epoch, device.address)) return@post
            if (status != BluetoothGatt.GATT_SUCCESS) { close("Notification delivery uncertain"); return@post }
            if (link.complete(epoch, device.address)) { notificationToken++; drain() }
        } }
    }

    private fun respond(device: BluetoothDevice, requestId: Int, status: Int, value: ByteArray? = null): Boolean {
        val accepted = runCatching { server?.sendResponse(device, requestId, status, 0, value) == true }.getOrDefault(false)
        if (!accepted && central?.address == device.address) close("Bluetooth response delivery uncertain")
        return accepted
    }
    private fun scheduleFrameExpiry(epoch: Int, device: BluetoothDevice) {
        frameTimer = object : Runnable { override fun run() {
            if (!link.accepts(epoch, device.address)) return
            try { link.receive(epoch, device.address, byteArrayOf(), SystemClock.elapsedRealtime()) }
            catch (_: Exception) { close("Partial Bluetooth record expired"); return }
            handler.postDelayed(this, 1000)
        } }.also { handler.postDelayed(it, 1000) }
    }
    @Suppress("UNUSED_PARAMETER")
    fun start(resetCandidates: Boolean = false) {
        close(null)
        try {
            if (!NearbyPermissions.allowed(context)) return close("Nearby Devices permission is required")
            val manager = context.getSystemService(BluetoothManager::class.java)
            val adapter = manager?.adapter ?: return close("Bluetooth LE is unavailable on this phone")
            if (!adapter.isEnabled) return close("Turn on Bluetooth to connect nearby")
            advertiser = adapter.bluetoothLeAdvertiser ?: return close("Bluetooth advertising unavailable")
            val epoch = link.generation
            state("Starting nearby Bluetooth…")
            server = manager.openGattServer(context, callback(epoch)) ?: return close("Nearby Bluetooth server unavailable")
            val service = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
            output = BluetoothGattCharacteristic(OUTPUT, BluetoothGattCharacteristic.PROPERTY_NOTIFY, 0).also {
                it.addDescriptor(BluetoothGattDescriptor(CCCD, BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE))
                service.addCharacteristic(it)
            }
            service.addCharacteristic(BluetoothGattCharacteristic(INPUT, BluetoothGattCharacteristic.PROPERTY_WRITE, BluetoothGattCharacteristic.PERMISSION_WRITE))
            if (server?.addService(service) != true) return close("Nearby Bluetooth service unavailable")
            handler.postDelayed({ if (epoch == link.generation && !advertisingReady) close("Nearby Bluetooth startup timed out") }, 10000)
        } catch (_: SecurityException) { close("Nearby Devices permission is required") }
        catch (_: Exception) { close("Nearby Bluetooth unavailable") }
    }
    private fun advertise(epoch: Int) {
        if (epoch != link.generation || advertisingCallback != null) return
        val callback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings) { handler.post {
                if (epoch == link.generation && server != null) {
                    advertisingReady = true
                    if (central == null) state("Waiting for your Mac nearby…")
                    availabilityChanged(true)
                }
            } }
            override fun onStartFailure(errorCode: Int) { handler.post {
                if (epoch == link.generation) close("Bluetooth advertising unavailable ($errorCode)")
            } }
        }
        advertisingCallback = callback
        try {
            advertiser?.startAdvertising(
                AdvertiseSettings.Builder().setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_POWER).setConnectable(true).setTimeout(0).build(),
                AdvertiseData.Builder().addServiceUuid(ParcelUuid(SERVICE)).setIncludeDeviceName(false).setIncludeTxPowerLevel(false).build(), callback
            ) ?: close("Bluetooth advertising unavailable")
        } catch (_: SecurityException) { close("Nearby Devices permission is required") }
        catch (_: Exception) { close("Bluetooth advertising unavailable") }
    }
    fun send(text: String) {
        try { link.enqueue(text); drain() }
        catch (e: Exception) { close("Nearby notification queue unavailable"); throw e }
    }
    private fun drain() {
        val next = link.next() ?: return
        val g = server ?: return close("Unreachable")
        val device = central ?: return close("Unreachable")
        val characteristic = output ?: return close("Unreachable")
        val accepted = runCatching {
            if (Build.VERSION.SDK_INT >= 33) g.notifyCharacteristicChanged(device, characteristic, false, next) == BluetoothStatusCodes.SUCCESS
            else { characteristic.value = next; g.notifyCharacteristicChanged(device, characteristic, false) }
        }.getOrDefault(false)
        if (!accepted) { close("Notification delivery uncertain"); return }
        val epoch = link.generation; val token = ++notificationToken
        handler.postDelayed({ if (epoch == link.generation && token == notificationToken) close("Notification acknowledgement timed out") }, 10000)
    }
    fun authenticated() { handshakeTimer?.let(handler::removeCallbacks); handshakeTimer = null }
    fun close(reason: String?) {
        val old = server; val device = central; val hadPeer = link.reset()
        notificationToken++; server = null; central = null; output = null; advertisingReady = false
        handshakeTimer?.let(handler::removeCallbacks); handshakeTimer = null
        frameTimer?.let(handler::removeCallbacks); frameTimer = null
        val callback = advertisingCallback; advertisingCallback = null
        runCatching { if (callback != null) advertiser?.stopAdvertising(callback) }; advertiser = null
        runCatching { if (device != null) old?.cancelConnection(device) }
        runCatching { old?.close() }
        if (hadPeer) disconnected()
        if (reason != null) state(reason)
        // Startup failure is not a peer disconnect. The service owns a separate,
        // gated retry path, including cases where no server could be opened.
        if (reason != null) availabilityChanged(false)
    }
    companion object {
        val SERVICE: UUID = UUID.fromString(NearbyGattV2.SERVICE)
        val OUTPUT: UUID = UUID.fromString(NearbyGattV2.PHONE_TO_MAC)
        val INPUT: UUID = UUID.fromString(NearbyGattV2.MAC_TO_PHONE)
        val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}

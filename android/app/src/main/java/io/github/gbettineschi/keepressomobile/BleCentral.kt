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
import io.github.gbettineschi.keepressomobile.core.*
import java.util.UUID

/** All connection operations and callbacks are confined to the main looper. Never bonds. */
@SuppressLint("MissingPermission")
class BleCentral(private val context: Context, private val state: (String) -> Unit, private val subscribed: () -> Unit, private val record: (String) -> Unit, private val disconnected: () -> Unit) {
    private val handler = Handler(Looper.getMainLooper())
    private val adapter get() = context.getSystemService(BluetoothManager::class.java)?.adapter
    private var gatt: BluetoothGatt? = null
    private var input: BluetoothGattCharacteristic? = null
    private var output: BluetoothGattCharacteristic? = null
    private var queue = WriteQueue()
    private var framer = Framer()
    private var chunkSize = 20
    private var scanning = false
    private var subscriptionReady = false
    private val frameExpiry = object : Runnable { override fun run() {
        if (gatt == null) return
        try { framer.feed(byteArrayOf(), android.os.SystemClock.elapsedRealtime()) } catch (_: Exception) { close("Partial Bluetooth record expired"); return }
        handler.postDelayed(this, 1000)
    } }
    private var generation = 0
    private var writeToken = 0
    private var handshakeTimer: Runnable? = null
    private val scan = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) { handler.post {
            if (!scanning || gatt != null) return@post
            stopScan(); state("Connecting nearby…")
            gatt = result.device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
            val epoch = generation; handler.postDelayed({ if (epoch == generation && !subscriptionReady) close("Bluetooth connection timed out") }, 15000)
        } }
        override fun onScanFailed(errorCode: Int) { handler.post { close("Bluetooth scan unavailable ($errorCode)") } }
    }
    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) { handler.post {
            if (g !== gatt) return@post
            if (status != BluetoothGatt.GATT_SUCCESS || newState == BluetoothProfile.STATE_DISCONNECTED) { close("Unreachable"); return@post }
            if (newState == BluetoothProfile.STATE_CONNECTED) { handler.post(frameExpiry); if (!g.discoverServices()) close("Service discovery failed") }
        } }
        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) { handler.post {
            if (g !== gatt) return@post
            val service = g.getService(SERVICE); input = service?.getCharacteristic(INPUT); output = service?.getCharacteristic(OUTPUT)
            if (status != BluetoothGatt.GATT_SUCCESS || input == null || output == null) { close("Companion service unavailable"); return@post }
            if (!g.requestMtu(517)) subscribe(g)
        } }
        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) { handler.post {
            if (g !== gatt) return@post
            chunkSize = if (status == BluetoothGatt.GATT_SUCCESS) (mtu - 3).coerceIn(20, 512) else 20
            subscribe(g)
        } }
        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) { handler.post {
            if (g !== gatt) return@post
            if (status != BluetoothGatt.GATT_SUCCESS) close("Notification subscription failed") else {
                subscriptionReady = true; state("Authenticating…"); subscribed()
                val epoch = generation; handshakeTimer = Runnable { if (generation == epoch) close("Authorization timed out") }.also { handler.postDelayed(it, 300000) }
            }
        } }
        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) { handler.post {
            if (g !== gatt) return@post
            writeToken++
            if (status != BluetoothGatt.GATT_SUCCESS) close("Write delivery uncertain") else { queue.complete(); drain() }
        } }
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) { receive(g, c, value.copyOf()) }
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) { receive(g, c, c.value?.copyOf() ?: return) }
    }
    private fun receive(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) { handler.post {
        if (g !== gatt || c.uuid != OUTPUT) return@post
        try { framer.feed(value, android.os.SystemClock.elapsedRealtime()).forEach(record) } catch (_: Exception) { close("Invalid secure record; connection closed") }
    } }
    private fun subscribe(g: BluetoothGatt) {
        val c = output ?: return close("Missing output characteristic")
        val d = c.getDescriptor(CCCD) ?: return close("Missing notification descriptor")
        if (!g.setCharacteristicNotification(c, true)) return close("Notifications unavailable")
        val accepted = if (Build.VERSION.SDK_INT >= 33) g.writeDescriptor(d, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == BluetoothStatusCodes.SUCCESS else { d.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE; g.writeDescriptor(d) }
        if (!accepted) close("Notification subscription rejected")
    }
    fun start() {
        close(null)
        try {
            val a = adapter ?: return state("Bluetooth LE is unavailable on this phone")
            if (!a.isEnabled) return state("Turn on Bluetooth to connect nearby")
            val scanner = a.bluetoothLeScanner ?: return state("Bluetooth scanning unavailable")
            state("Looking for your Mac nearby…"); scanning = true
            scanner.startScan(listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE)).build()), ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_POWER).build(), scan)
            val epoch = generation; handler.postDelayed({ if (epoch == generation && scanning) close("No nearby Mac found") }, 12000)
        } catch (_: SecurityException) { close("Nearby Devices permission is required") }
    }
    private fun stopScan() { if (scanning) { scanning = false; try { adapter?.bluetoothLeScanner?.stopScan(scan) } catch (_: SecurityException) { } } }
    fun send(text: String) { require(gatt != null && input != null); queue.enqueue(Framer.encode(text), chunkSize); drain() }
    private fun drain() {
        val next = queue.next() ?: return; val g = gatt ?: return close("Unreachable"); val c = input ?: return close("Unreachable")
        val accepted = if (Build.VERSION.SDK_INT >= 33) g.writeCharacteristic(c, next, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) == BluetoothStatusCodes.SUCCESS else { c.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT; c.value = next; g.writeCharacteristic(c) }
        if (!accepted) { close("Write delivery uncertain"); return }
        val token = ++writeToken; val epoch = generation
        handler.postDelayed({ if (epoch == generation && token == writeToken) close("Write acknowledgement timed out") }, 10000)
    }
    fun authenticated() { handshakeTimer?.let(handler::removeCallbacks); handshakeTimer = null }
    fun close(reason: String?) {
        generation++; writeToken++; subscriptionReady = false; handler.removeCallbacks(frameExpiry); stopScan(); handshakeTimer?.let(handler::removeCallbacks); handshakeTimer = null
        val old = gatt; gatt = null; input = null; output = null; queue.clear(); framer = Framer(); chunkSize = 20
        try { old?.disconnect(); old?.close() } catch (_: SecurityException) { }
        disconnected(); if (reason != null) state(reason)
    }
    companion object {
        val SERVICE: UUID = UUID.fromString("73f8d1c0-823f-4c2f-9e0a-4454129f3001")
        val INPUT: UUID = UUID.fromString("73f8d1c0-823f-4c2f-9e0a-4454129f3002")
        val OUTPUT: UUID = UUID.fromString("73f8d1c0-823f-4c2f-9e0a-4454129f3003")
        val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}

package io.github.gbettineschi.keepressomobile

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
import android.content.Intent
import android.os.SystemClock
import androidx.core.content.ContextCompat
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import org.junit.*
import org.junit.rules.RuleChain
import java.time.Instant

/** Harness retains synthetic pairing, turns this emulator's adapter off, then runs this without an Activity. */
@SuppressLint("MissingPermission")
class PeripheralStartupRecoveryTest {
    @get:Rule val rules = RuleChain.outerRule(EmulatorOnlyRule()).around(GrantPermissionRule.grant(
        Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.POST_NOTIFICATIONS))

    private fun await(timeout: Long, condition: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + timeout
        while (!condition() && SystemClock.elapsedRealtime() < deadline) Thread.sleep(100)
        Assert.assertTrue("Timed out: ${Companion.state.value.connection}", condition())
    }

    @Test fun savedPairedPhoneRecoversWhenRadioReturnsWithoutForegrounding() {
        Assume.assumeTrue(InstrumentationRegistry.getArguments().getString("virtualPeer") == "true")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val saved = requireNotNull(CredentialStore(context).load())
        Assert.assertEquals("Emulated Mac", saved.name)
        val adapter = context.getSystemService(BluetoothManager::class.java).adapter
        Assert.assertFalse("Harness must start this paired emulator with Bluetooth off", adapter.isEnabled)
        try {
            ContextCompat.startForegroundService(context, Intent(context, NearbyService::class.java).putExtra("foreground", false))
            await(5000) { Companion.service != null && Companion.state.value.connection.contains("Turn on Bluetooth") }
            android.util.Log.i("KeepressoRecoveryTest", "STARTUP_RADIO_OFF")
            val deadline = SystemClock.elapsedRealtime() + 18000
            while (SystemClock.elapsedRealtime() < deadline) {
                Assert.assertFalse(adapter.isEnabled)
                instrumentation.runOnMainSync {
                    val service = requireNotNull(Companion.service)
                    val ble = NearbyService::class.java.getDeclaredField("ble").apply { isAccessible = true }.get(service) as BlePeripheral
                    Assert.assertFalse("Radio-off must never create a GATT server", ble.isRunning)
                    Assert.assertEquals("Peer-free failures must not fake disconnects", 0,
                        NearbyService::class.java.getDeclaredField("reconnectGeneration").apply { isAccessible = true }.getInt(service))
                }
                Thread.sleep(200)
            }
            await(60000) { adapter.isEnabled && Companion.state.value.reachable(Instant.now()) }
            Assert.assertEquals("Nearby Bluetooth", Companion.state.value.transport)
            val retained = requireNotNull(CredentialStore(context).load())
            Assert.assertEquals(saved.deviceId, retained.deviceId)
            Assert.assertTrue(saved.key.contentEquals(retained.key))
            instrumentation.runOnMainSync {
                Assert.assertFalse(NearbyService::class.java.getDeclaredField("foregroundActivity").apply { isAccessible = true }.getBoolean(requireNotNull(Companion.service)))
            }
        } finally { context.stopService(Intent(context, NearbyService::class.java)) }
    }
}

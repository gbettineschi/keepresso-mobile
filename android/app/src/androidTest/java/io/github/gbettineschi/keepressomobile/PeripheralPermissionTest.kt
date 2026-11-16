package io.github.gbettineschi.keepressomobile

import android.Manifest
import android.content.Intent
import android.os.Build
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.core.app.ActivityScenario
import androidx.test.uiautomator.UiDevice
import io.github.gbettineschi.keepressomobile.core.encode64
import org.junit.*

/** Synthetic emulator authorization only; the rule prevents permission changes on phones. */
class PeripheralPermissionTest {
    @get:Rule val emulator = EmulatorOnlyRule()
    @Test fun deniedAdvertisingPreservesSavedAuthorizationAndInternetConfiguration() {
        Assume.assumeTrue(Build.VERSION.SDK_INT >= 31)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val device = UiDevice.getInstance(instrumentation)
        val store = CredentialStore(context)
        context.stopService(Intent(context, NearbyService::class.java)); instrumentation.waitForIdleSync()
        val fixture = Credential("11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222", "TestMac", ByteArray(32) { 7 }, "https://relay.example", encode64(ByteArray(32) { 8 }))
        store.clear(); store.save(fixture)
        try {
            device.executeShellCommand("pm grant ${context.packageName} ${Manifest.permission.BLUETOOTH_CONNECT}")
            device.executeShellCommand("pm revoke ${context.packageName} ${Manifest.permission.BLUETOOTH_ADVERTISE}")
            Assert.assertFalse(NearbyPermissions.allowed(context))
            var losses = 0
            instrumentation.runOnMainSync {
                val transport = BlePeripheral(context, {}, { error("Cannot subscribe without permission") }, { error("Cannot receive without permission") }, { losses++ })
                transport.start(); transport.start(); transport.close(null)
                Companion.mutable.value = UiState()
            }
            Assert.assertEquals("Server-only cleanup must not schedule disconnect/restart loops", 0, losses)
            ActivityScenario.launch(MainActivity::class.java).use { activity ->
                activity.onActivity { it.startService(Intent(it, NearbyService::class.java).putExtra("foreground", true)) }
                val deadline = android.os.SystemClock.elapsedRealtime() + 5000
                while ((!Companion.state.value.internetConfigured || Companion.state.value.macId != fixture.macId) && android.os.SystemClock.elapsedRealtime() < deadline) Thread.sleep(25)
                Assert.assertNotNull(Companion.service)
                Assert.assertEquals(fixture.macId, Companion.state.value.macId)
                Assert.assertTrue(Companion.state.value.internetConfigured)
                Assert.assertFalse(Companion.state.value.authenticated)
                Assert.assertEquals(fixture.deviceId, store.load()?.deviceId)
                Assert.assertArrayEquals(fixture.key, store.load()?.key)
                Assert.assertEquals(fixture.relayAuthTicket, store.load()?.relayAuthTicket)
            }
        } finally {
            context.stopService(Intent(context, NearbyService::class.java))
            instrumentation.waitForIdleSync(); store.clear()
        }
    }
}

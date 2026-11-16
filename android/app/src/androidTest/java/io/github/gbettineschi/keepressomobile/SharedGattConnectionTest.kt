@file:Suppress("MissingPermission")
package io.github.gbettineschi.keepressomobile

import android.Manifest
import android.bluetooth.*
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import io.github.gbettineschi.keepressomobile.core.PeripheralLink
import org.junit.*
import org.junit.rules.RuleChain

/** Replays public GATT callbacks seen on the physical phone, on an emulator only. */
class SharedGattConnectionTest {
    @get:Rule val rules=RuleChain.outerRule(EmulatorOnlyRule()).around(GrantPermissionRule.grant(
        Manifest.permission.BLUETOOTH_ADVERTISE,Manifest.permission.BLUETOOTH_CONNECT))

    private fun exercise(disconnect:Boolean) {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val context=instrumentation.targetContext
        val adapter=context.getSystemService(BluetoothManager::class.java).adapter
        val bystander=adapter.getRemoteDevice("02:00:00:00:00:42")
        var losses=0
        lateinit var transport:BlePeripheral
        instrumentation.runOnMainSync {
            transport=BlePeripheral(context,{}, {error("No client subscribed")},{error("No client wrote a record")},{losses++})
            transport.start()
            Assert.assertTrue(transport.isRunning)
            val link=BlePeripheral::class.java.getDeclaredField("link").apply{isAccessible=true}.get(transport) as PeripheralLink
            val callback=BlePeripheral::class.java.getDeclaredMethod("callback",Int::class.javaPrimitiveType).apply{isAccessible=true}.invoke(transport,link.generation) as BluetoothGattServerCallback
            // Shared physical links can be reported before service publication.
            callback.onConnectionStateChange(bystander,BluetoothGatt.GATT_SUCCESS,BluetoothProfile.STATE_CONNECTED)
            if(disconnect)callback.onConnectionStateChange(bystander,BluetoothGatt.GATT_SUCCESS,BluetoothProfile.STATE_DISCONNECTED)
        }
        instrumentation.waitForIdleSync()
        // Inject before publication, then let the platform finish registration
        // before cleanup so a late service-added callback cannot contaminate
        // the next real GATT flow in the same emulator Bluetooth stack.
        val deadline=SystemClock.elapsedRealtime()+5000
        var publicationFinished=false
        while(!publicationFinished && SystemClock.elapsedRealtime()<deadline){
            instrumentation.runOnMainSync {
                publicationFinished=!transport.isRunning || BlePeripheral::class.java.getDeclaredField("advertisingReady").apply{isAccessible=true}.getBoolean(transport)
            }
            if(!publicationFinished)Thread.sleep(25)
        }
        try {
            instrumentation.runOnMainSync {
                Assert.assertTrue("Service publication must settle before cleanup",publicationFinished)
                Assert.assertTrue("Unrelated physical GATT events must leave our server running",transport.isRunning)
                transport.close(null)
                Assert.assertEquals("A generic connection is not our subscribed peer",0,losses)
            }
        } finally { instrumentation.runOnMainSync {transport.close(null)} }
    }
    @Test fun existingPhysicalConnectionDoesNotBecomeOurPeer()=exercise(false)
    @Test fun unrelatedPhysicalDisconnectCannotStopOurServer()=exercise(true)
}

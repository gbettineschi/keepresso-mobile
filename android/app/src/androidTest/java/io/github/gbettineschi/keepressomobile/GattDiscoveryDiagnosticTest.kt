package io.github.gbettineschi.keepressomobile

import android.bluetooth.*
import android.bluetooth.le.*
import android.os.ParcelUuid
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Test
import org.junit.Assert.*
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Explicit hardware diagnostic: reads public service metadata, sends no pairing or controls. */
class GattDiscoveryDiagnosticTest {
    @Test fun advertisedCompanionHasBothTransportCharacteristics() {
        org.junit.Assume.assumeTrue(InstrumentationRegistry.getArguments().getString("hardware")=="true")
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val manager=context.getSystemService(BluetoothManager::class.java)
        val done=CountDownLatch(1);var failure="No companion advertisement found";var gatt:BluetoothGatt?=null
        val callback=object:BluetoothGattCallback(){
            override fun onConnectionStateChange(g:BluetoothGatt,status:Int,newState:Int){
                if(newState==BluetoothProfile.STATE_CONNECTED){
                    if(InstrumentationRegistry.getArguments().getString("refreshCache")=="true"){
                        val accepted=runCatching{g.javaClass.getMethod("refresh").invoke(g) as Boolean}.getOrDefault(false)
                        Log.i("KeepressoGattTest","Diagnostic cache refresh accepted=$accepted")
                        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({g.discoverServices()},1200)
                    }else g.discoverServices()
                }
            }
            override fun onServicesDiscovered(g:BluetoothGatt,status:Int){
                val summary=g.services.joinToString(";"){s->"${s.uuid}:[${s.characteristics.joinToString{it.uuid.toString()}}]"}
                Log.i("KeepressoGattTest","status=$status services=$summary")
                val service=g.getService(BleCentral.SERVICE)
                failure=when{status!=BluetoothGatt.GATT_SUCCESS->"Discovery status $status";service==null->"Advertised service missing: $summary";service.getCharacteristic(BleCentral.INPUT)==null->"Input missing: $summary";service.getCharacteristic(BleCentral.OUTPUT)==null->"Output missing: $summary";else->""}
                done.countDown()
            }
        }
        val scan=object:ScanCallback(){
            override fun onScanResult(type:Int,result:ScanResult){
                manager.adapter.bluetoothLeScanner.stopScan(this)
                if(gatt==null)gatt=result.device.connectGatt(context,false,callback,BluetoothDevice.TRANSPORT_LE)
            }
        }
        try{
            manager.adapter.bluetoothLeScanner.startScan(listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(BleCentral.SERVICE)).build()),ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(),scan)
            assertTrue("Bluetooth discovery timed out: $failure",done.await(25,TimeUnit.SECONDS))
            assertEquals(failure,"",failure)
        }finally{manager.adapter.bluetoothLeScanner.stopScan(scan);gatt?.disconnect();gatt?.close()}
    }
}

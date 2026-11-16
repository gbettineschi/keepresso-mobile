@file:Suppress("MissingPermission", "DEPRECATION")
package io.github.gbettineschi.keepressomobile

import android.Manifest
import android.bluetooth.*
import android.bluetooth.le.*
import android.os.*
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import io.github.gbettineschi.keepressomobile.core.*
import kotlinx.serialization.json.*
import org.junit.*
import java.time.Instant
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Separate-emulator GATT fixture. This class is in the test APK only, never production. */
class VirtualMacPeerTest {
    private val main=Handler(Looper.getMainLooper())
    private val mac="11111111-1111-4111-8111-111111111111"
    private val token=ByteArray(32)
    private var currentGatt:BluetoothGatt?=null
    private var scanner:BluetoothLeScanner?=null
    private var scanning=false
    private var stopping=false
    private val serviceId=UUID.fromString(NearbyGattV2.SERVICE)
    private val phoneToMac=UUID.fromString(NearbyGattV2.PHONE_TO_MAC)
    private val macToPhone=UUID.fromString(NearbyGattV2.MAC_TO_PHONE)
    private val cccd=UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    private class Peer(val gatt:BluetoothGatt){
        val device get()=gatt.device
        val framer=Framer();val queue=ArrayDeque<ByteArray>();var sending=false;var mtu=23
        var writeReady=false;var input:BluetoothGattCharacteristic?=null
        var deviceId="";var transcript="";var channel:SecureChannel?=null
    }
    private val peers=mutableMapOf<String,Peer>();private val keys=mutableMapOf<String,ByteArray>()
    private var active=false;private var paused=true;private var end:Instant?=null;private var checked:Instant?=null;private var startCount=0;private var sleepCount=0
    private var interval=3600;private var delay=300;private var routine=true;private var snoozed:Instant?=null
    private var warningSent=false
    private var linkLossRequested=false
    private var checkCount=0
    private val historyMode get()=InstrumentationRegistry.getArguments().getString("mode")=="trigger-history"
    private fun snapshot(manualAnswer:Boolean=false)=buildJsonObject{
        put("capturedAt",Instant.now().toString());put("macName","Emulated Mac")
        put("fixtureStartCount",startCount)
        put("fixtureSleepRequests",sleepCount)
        put("fixtureCheckCount",checkCount)
        put("mac",buildJsonObject{put("lock","locked");put("display","off");put("lid","closed");put("batteryPercent",83);put("powerSource","ac");put("temperatureC",JsonNull);put("temperatureSensor",JsonNull);put("thermal","normal")})
        put("keepresso",buildJsonObject{put("appRunning",true);put("version","1.27.0");put("isActive",active);put("endsAt",end?.let{JsonPrimitive(it.toString())}?:JsonNull);put("triggersEnabled",true);put("triggersPaused",paused);put("sessionKind",if(end!=null)"manual" else if(active)"automatic" else "unknown");put("safetyPause","none")})
        put("capabilities",buildJsonObject{for(name in listOf("startManual","stopManual","pauseTriggers","resumeTriggers","refreshTriggers"))put(name,true);put("sleepNow",InstrumentationRegistry.getArguments().getString("mode")=="sleep")})
        put("triggers",buildJsonObject{
            put("state",if(checked==null)"not_checked" else "ready")
            put("checkedAt",checked?.let{JsonPrimitive((if(historyMode && !manualAnswer)it.plusSeconds(1) else it).toString())}?:JsonNull)
            put("combined",historyMode && manualAnswer && checkCount==2)
            put("rules",if(historyMode && manualAnswer && checkCount in 2..3) buildJsonArray{
                add(buildJsonObject{put("id","agent");put("label","Fixture agent trigger");put("satisfied",true);put("inGrace",false);put("graceRemaining",JsonNull);put("details",JsonArray(emptyList()))})
                add(buildJsonObject{put("id","mic");put("label","Fixture microphone trigger");put("satisfied",false);put("inGrace",false);put("graceRemaining",JsonNull);put("details",JsonArray(emptyList()))})
            } else JsonArray(emptyList()))
            put("message",JsonNull)
            if(historyMode){put("checking",false);put("outdated",!manualAnswer);put("checkError",if(manualAnswer && checkCount in listOf(1,3))JsonPrimitive("Couldn't check triggers") else JsonNull)}
        })
        put("reminders",buildJsonObject{put("enabled",routine);put("intervalSeconds",interval);put("endedAwakeDelaySeconds",delay);put("snoozedUntil",snoozed?.let{JsonPrimitive(it.toString())}?:JsonNull)})
    }
    private fun send(peer:Peer,value:JsonObject,encrypted:Boolean=false){
        val text=if(encrypted)requireNotNull(peer.channel).seal(value.toString()) else value.toString()
        Framer.encode(text).toList().chunked((peer.mtu-3).coerceIn(20,512)).forEach{peer.queue.addLast(it.toByteArray())};flush(peer)
    }
    private fun flush(peer:Peer){
        if(!peer.writeReady || peer.sending || peer.queue.isEmpty())return
        peer.sending=true
        check(peer.gatt.writeCharacteristic(requireNotNull(peer.input),peer.queue.first(),BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)==BluetoothStatusCodes.SUCCESS)
    }
    private fun receive(peer:Peer,text:String){
        var message=obj(text)
        if(peer.channel!=null){
            message=obj(peer.channel!!.open(text));Requests.validate(message.toString(),Instant.now())
            val action=message.string("action")
            when(action){
                "start_manual"->{startCount++;active=true;paused=true;end=Instant.now().plusSeconds(message.getValue("durationMinutes").jsonPrimitive.int*60L)}
                "stop_manual"->{active=false;end=null}
                "resume_triggers"->{paused=false;active=false;end=null}
                "pause_triggers"->{paused=true;active=false;end=null}
                "sleep_now"->{sleepCount++;paused=true;active=false;end=null}
                "refresh_triggers"->{checkCount++;if(!historyMode || checkCount !in listOf(1,3))checked=Instant.now()}
                "snooze_reminders"->snoozed=Instant.now().plusSeconds(21600)
                "resume_reminders"->snoozed=null
                "set_reminder_settings"->{val settings=message.getValue("reminderSettings").jsonObject;routine=settings.getValue("enabled").jsonPrimitive.boolean;interval=settings.getValue("intervalSeconds").jsonPrimitive.int;delay=settings.getValue("endedAwakeDelaySeconds").jsonPrimitive.int}
            }
            val response=buildJsonObject{put("type","response");put("id",message.string("id"));put("status",if(historyMode && action=="refresh_triggers" && checkCount in listOf(1,3))"error" else "ok");put("snapshot",snapshot(manualAnswer=action=="refresh_triggers"));if(historyMode && action=="refresh_triggers" && checkCount in listOf(1,3))put("message","Couldn't check triggers")}
            if(historyMode && action=="refresh_triggers" && checkCount==2){
                main.postDelayed({if(peers[peer.device.address]===peer)send(peer,response,true)},8000)
                return
            }
            if(action=="status" && InstrumentationRegistry.getArguments().getString("mode")=="slow")main.postDelayed({if(peers[peer.device.address]===peer)send(peer,response,true)},1500)
            else send(peer,response,true)
            if(action=="status" && !warningSent && InstrumentationRegistry.getArguments().getString("mode")=="warning"){
                warningSent=true
                val event=buildJsonObject{put("type","event");put("event",buildJsonObject{put("id","44444444-4444-4444-8444-444444444444");put("kind","lid_awake");put("createdAt",Instant.now().toString());put("title","Mac awake with lid closed");put("body","Synthetic warning")})}
                send(peer,event,true);send(peer,event,true)
            }
            if(action=="start_manual"){
                val event=buildJsonObject{put("type","event");put("event",buildJsonObject{put("id",java.util.UUID.randomUUID().toString());put("kind","hourly");put("createdAt",Instant.now().toString());put("title","Keepresso test reminder");put("body","Synthetic virtual Mac reminder")})}
                send(peer,event,true);send(peer,event,true)
            }
            // The approval flow requests its outage after configuring snooze.
            // Earlier automatic checks must leave the connection alone.
            if (action == "refresh_triggers" && snoozed != null && !linkLossRequested &&
                InstrumentationRegistry.getArguments().getString("mode") == "approve") {
                linkLossRequested = true
                main.postDelayed({ Log.i("KeepressoVirtualPeer", "LINK_LOSS") }, 1500)
            }
            return
        }
        when(message.string("type")){
            "pair"->{
                val id=canonicalId(message.string("deviceId"));require(message.string("macId")==mac)
                require(Crypto.verify(token,Crypto.pairTranscript(mac,id,message.string("clientNonce"),message.string("deviceName")),message.string("proof")))
                send(peer,buildJsonObject{put("type","pair_pending")})
                main.postDelayed({if(peers[peer.device.address]===peer){
                    if(InstrumentationRegistry.getArguments().getString("mode")=="deny")send(peer,buildJsonObject{put("type","pair_denied")})
                    else{val key=Crypto.deviceKey(token,mac,id);keys[id]=key;send(peer,buildJsonObject{put("type","paired");put("macId",mac);put("deviceId",id);put("proof",Crypto.proof(key,"paired\n$mac\n$id"))})}
                }},3000)
            }
            "hello"->{
                require(message.string("macId")==mac);peer.deviceId=message.string("deviceId");val key=requireNotNull(keys[peer.deviceId]);val nonce=randomNonce()
                peer.transcript=Crypto.transcript(mac,peer.deviceId,message.string("clientNonce"),nonce)
                send(peer,buildJsonObject{put("type","challenge");put("serverNonce",nonce);put("proof",Crypto.proof(key,"server\n${peer.transcript}"))})
            }
            "authenticate"->{
                val key=requireNotNull(keys[peer.deviceId]);require(Crypto.verify(key,"client\n${peer.transcript}",message.string("proof")))
                peer.channel=SecureChannel(Crypto.directionKey(key,peer.transcript,"s2c"),Crypto.directionKey(key,peer.transcript,"c2s"))
                send(peer,buildJsonObject{put("type","ready");put("macId",mac);put("deviceId",peer.deviceId);put("serverTime",Instant.now().toString())},true)
            }
        }
    }
    private fun peer(gatt:BluetoothGatt)=peers[gatt.device.address]?.takeIf{it.gatt===gatt && currentGatt===gatt}
    private fun retry(gatt:BluetoothGatt?=currentGatt){
        if(gatt!==currentGatt)return
        gatt?.let{peers.remove(it.device.address);runCatching{it.disconnect()};it.close()}
        currentGatt=null
        if(!stopping)main.postDelayed({startScan()},1000)
    }
    private val scan=object:ScanCallback(){
        override fun onScanResult(callbackType:Int,result:ScanResult){main.post{
            if(stopping || !scanning || currentGatt!=null)return@post
            Log.i("KeepressoVirtualPeer","PHONE_FOUND")
            scanner?.stopScan(this);scanning=false
            currentGatt=result.device.connectGatt(InstrumentationRegistry.getInstrumentation().targetContext,false,callback,BluetoothDevice.TRANSPORT_LE)
        }}
        override fun onScanFailed(errorCode:Int){Log.e("KeepressoVirtualPeer","Scan failed: $errorCode")}
    }
    private fun startScan(){
        if(stopping || currentGatt!=null || scanning)return
        scanner!!.startScan(listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(serviceId)).build()),ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(),scan)
        scanning=true
    }
    private val callback=object:BluetoothGattCallback(){
        override fun onConnectionStateChange(gatt:BluetoothGatt,status:Int,newState:Int){main.post{
            if(currentGatt!==gatt)return@post
            if(status!=BluetoothGatt.GATT_SUCCESS || newState==BluetoothProfile.STATE_DISCONNECTED){retry(gatt);return@post}
            if(newState==BluetoothProfile.STATE_CONNECTED){
                peers[gatt.device.address]=Peer(gatt)
                if(!gatt.requestMtu(517))check(gatt.discoverServices())
            }
        }}
        override fun onMtuChanged(gatt:BluetoothGatt,mtu:Int,status:Int){main.post{
            val p=peer(gatt)?:return@post
            if(status==BluetoothGatt.GATT_SUCCESS)p.mtu=mtu
            check(gatt.discoverServices())
        }}
        override fun onServicesDiscovered(gatt:BluetoothGatt,status:Int){main.post{
            val p=peer(gatt)?:return@post
            check(status==BluetoothGatt.GATT_SUCCESS)
            val service=requireNotNull(gatt.getService(serviceId)){"V2 phone service missing"}
            val output=requireNotNull(service.getCharacteristic(phoneToMac))
            p.input=requireNotNull(service.getCharacteristic(macToPhone))
            check(output.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY!=0)
            check(p.input!!.properties and BluetoothGattCharacteristic.PROPERTY_WRITE!=0)
            check(gatt.setCharacteristicNotification(output,true))
            check(gatt.writeDescriptor(requireNotNull(output.getDescriptor(cccd)),BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)==BluetoothStatusCodes.SUCCESS)
        }}
        override fun onDescriptorWrite(gatt:BluetoothGatt,descriptor:BluetoothGattDescriptor,status:Int){main.post{
            val p=peer(gatt)?:return@post
            Log.i("KeepressoVirtualPeer","SUBSCRIBE_ACK status=$status")
            if(status!=BluetoothGatt.GATT_SUCCESS){retry(gatt);return@post}
            check(descriptor.uuid==cccd)
            p.writeReady=true;flush(p)
        }}
        override fun onCharacteristicChanged(gatt:BluetoothGatt,characteristic:BluetoothGattCharacteristic,value:ByteArray){main.post{
            val p=peer(gatt)?:return@post
            check(characteristic.uuid==phoneToMac)
            runCatching{p.framer.feed(value,SystemClock.elapsedRealtime()).forEach{receive(p,it)}}
                .onFailure{Log.e("KeepressoVirtualPeer","Fixture protocol failure",it);retry(gatt)}
        }}
        override fun onCharacteristicWrite(gatt:BluetoothGatt,characteristic:BluetoothGattCharacteristic,status:Int){main.post{
            val p=peer(gatt)?:return@post
            if(!p.sending || status!=BluetoothGatt.GATT_SUCCESS){retry(gatt);return@post}
            p.queue.removeFirst();p.sending=false;flush(p)
        }}
    }
    @Test fun serveIsolatedVirtualMac(){
        Assume.assumeTrue(InstrumentationRegistry.getArguments().getString("virtualPeer")=="true")
        check(Build.HARDWARE=="ranchu")
        val instrumentation=InstrumentationRegistry.getInstrumentation();val context=instrumentation.targetContext
        instrumentation.uiAutomation.adoptShellPermissionIdentity(Manifest.permission.BLUETOOTH_CONNECT,Manifest.permission.BLUETOOTH_SCAN,Manifest.permission.ACCESS_FINE_LOCATION)
        val manager=context.getSystemService(BluetoothManager::class.java);val started=CountDownLatch(1)
        scanner=manager.adapter.bluetoothLeScanner
        try{
            main.post{startScan();Log.i("KeepressoVirtualPeer","READY");started.countDown()}
            Assert.assertTrue("Virtual Mac central did not start",started.await(15,TimeUnit.SECONDS))
            CountDownLatch(1).await(600,TimeUnit.SECONDS)
        }finally{
            val stopped=CountDownLatch(1)
            main.post{stopping=true;if(scanning)scanner?.stopScan(scan);scanning=false;retry();stopped.countDown()}
            stopped.await(5,TimeUnit.SECONDS)
            instrumentation.uiAutomation.dropShellPermissionIdentity()
        }
    }
}

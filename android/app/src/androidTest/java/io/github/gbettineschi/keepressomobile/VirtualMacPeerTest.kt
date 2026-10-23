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
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Separate-emulator GATT fixture. This class is in the test APK only, never production. */
class VirtualMacPeerTest {
    private val main=Handler(Looper.getMainLooper())
    private val mac="11111111-1111-4111-8111-111111111111"
    private val token=ByteArray(32)
    private lateinit var server:BluetoothGattServer
    private lateinit var output:BluetoothGattCharacteristic
    private class Peer(val device:BluetoothDevice){
        val framer=Framer();val queue=ArrayDeque<ByteArray>();var sending=false;var mtu=23
        var deviceId="";var transcript="";var channel:SecureChannel?=null
    }
    private val peers=mutableMapOf<String,Peer>();private val keys=mutableMapOf<String,ByteArray>()
    private var active=false;private var paused=true;private var end:Instant?=null;private var checked:Instant?=null
    private var interval=3600;private var delay=300;private var routine=true;private var snoozed:Instant?=null
    private fun snapshot()=buildJsonObject{
        put("capturedAt",Instant.now().toString());put("macName","Emulated Mac")
        put("mac",buildJsonObject{put("lock","locked");put("display","off");put("lid","closed");put("batteryPercent",83);put("powerSource","ac");put("temperatureC",JsonNull);put("temperatureSensor",JsonNull);put("thermal","normal")})
        put("keepresso",buildJsonObject{put("appRunning",true);put("version","1.27.0");put("isActive",active);put("endsAt",end?.let{JsonPrimitive(it.toString())}?:JsonNull);put("triggersEnabled",true);put("triggersPaused",paused);put("sessionKind",if(end!=null)"manual" else if(active)"automatic" else "unknown");put("safetyPause","none")})
        put("capabilities",buildJsonObject{for(name in listOf("startManual","stopManual","pauseTriggers","resumeTriggers","refreshTriggers"))put(name,true);put("sleepNow",false)})
        put("triggers",buildJsonObject{put("state",if(checked==null)"not_checked" else "ready");put("checkedAt",checked?.let{JsonPrimitive(it.toString())}?:JsonNull);put("combined",false);put("rules",JsonArray(emptyList()));put("message",JsonNull)})
        put("reminders",buildJsonObject{put("enabled",routine);put("intervalSeconds",interval);put("endedAwakeDelaySeconds",delay);put("snoozedUntil",snoozed?.let{JsonPrimitive(it.toString())}?:JsonNull)})
    }
    private fun send(peer:Peer,value:JsonObject,encrypted:Boolean=false){
        val text=if(encrypted)requireNotNull(peer.channel).seal(value.toString()) else value.toString()
        Framer.encode(text).toList().chunked((peer.mtu-3).coerceIn(20,512)).forEach{peer.queue.addLast(it.toByteArray())};flush(peer)
    }
    private fun flush(peer:Peer){
        if(peer.sending || peer.queue.isEmpty())return
        peer.sending=true;val bytes=peer.queue.removeFirst()
        check(server.notifyCharacteristicChanged(peer.device,output,false,bytes)==BluetoothStatusCodes.SUCCESS)
    }
    private fun receive(peer:Peer,text:String){
        var message=obj(text)
        if(peer.channel!=null){
            message=obj(peer.channel!!.open(text));Requests.validate(message.toString(),Instant.now())
            val action=message.string("action")
            when(action){
                "start_manual"->{active=true;paused=true;end=Instant.now().plusSeconds(message.getValue("durationMinutes").jsonPrimitive.int*60L)}
                "stop_manual"->{active=false;end=null}
                "resume_triggers"->{paused=false;active=false;end=null}
                "pause_triggers"->{paused=true;active=false;end=null}
                "refresh_triggers"->checked=Instant.now()
                "snooze_reminders"->snoozed=Instant.now().plusSeconds(21600)
                "resume_reminders"->snoozed=null
                "set_reminder_settings"->{val settings=message.getValue("reminderSettings").jsonObject;routine=settings.getValue("enabled").jsonPrimitive.boolean;interval=settings.getValue("intervalSeconds").jsonPrimitive.int;delay=settings.getValue("endedAwakeDelaySeconds").jsonPrimitive.int}
            }
            send(peer,buildJsonObject{put("type","response");put("id",message.string("id"));put("status","ok");put("snapshot",snapshot())},true)
            if(action=="start_manual"){
                val event=buildJsonObject{put("type","event");put("event",buildJsonObject{put("id",java.util.UUID.randomUUID().toString());put("kind","hourly");put("createdAt",Instant.now().toString());put("title","Keepresso test reminder");put("body","Synthetic virtual Mac reminder")})}
                send(peer,event,true);send(peer,event,true)
            }
            if(action=="refresh_triggers")main.postDelayed({Log.i("KeepressoVirtualPeer","LINK_LOSS")},1500)
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
    @Test fun serveIsolatedVirtualMac(){
        Assume.assumeTrue(InstrumentationRegistry.getArguments().getString("virtualPeer")=="true")
        check(Build.HARDWARE=="ranchu")
        val instrumentation=InstrumentationRegistry.getInstrumentation();val context=instrumentation.targetContext
        instrumentation.uiAutomation.adoptShellPermissionIdentity(Manifest.permission.BLUETOOTH_CONNECT,Manifest.permission.BLUETOOTH_SCAN,Manifest.permission.BLUETOOTH_ADVERTISE)
        val manager=context.getSystemService(BluetoothManager::class.java);val started=CountDownLatch(1)
        val advertiser=manager.adapter.bluetoothLeAdvertiser;val advertiseCallback=object:AdvertiseCallback(){override fun onStartSuccess(settings:AdvertiseSettings){Log.i("KeepressoVirtualPeer","READY");started.countDown()}}
        server=manager.openGattServer(context,object:BluetoothGattServerCallback(){
            override fun onConnectionStateChange(device:BluetoothDevice,status:Int,newState:Int){main.post{if(newState==BluetoothProfile.STATE_CONNECTED)peers[device.address]=Peer(device) else peers.remove(device.address)}}
            override fun onMtuChanged(device:BluetoothDevice,mtu:Int){main.post{peers[device.address]?.mtu=mtu}}
            override fun onServiceAdded(status:Int,service:BluetoothGattService){
                check(status==BluetoothGatt.GATT_SUCCESS)
                advertiser.startAdvertising(AdvertiseSettings.Builder().setConnectable(true).setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY).build(),AdvertiseData.Builder().addServiceUuid(ParcelUuid(BleCentral.SERVICE)).build(),advertiseCallback)
            }
            override fun onDescriptorWriteRequest(device:BluetoothDevice,id:Int,d:BluetoothGattDescriptor,prepared:Boolean,response:Boolean,offset:Int,value:ByteArray){if(response)server.sendResponse(device,id,BluetoothGatt.GATT_SUCCESS,0,null)}
            override fun onCharacteristicWriteRequest(device:BluetoothDevice,id:Int,c:BluetoothGattCharacteristic,prepared:Boolean,response:Boolean,offset:Int,value:ByteArray){
                if(response)server.sendResponse(device,id,BluetoothGatt.GATT_SUCCESS,0,null)
                main.post{val peer=peers[device.address]?:return@post;runCatching{peer.framer.feed(value,SystemClock.elapsedRealtime()).forEach{receive(peer,it)}}.onFailure{Log.e("KeepressoVirtualPeer","Fixture protocol failure",it);server.cancelConnection(device)}}
            }
            override fun onNotificationSent(device:BluetoothDevice,status:Int){main.post{peers[device.address]?.let{it.sending=false;flush(it)}}}
        })
        output=BluetoothGattCharacteristic(BleCentral.OUTPUT,BluetoothGattCharacteristic.PROPERTY_NOTIFY,0)
        output.addDescriptor(BluetoothGattDescriptor(BleCentral.CCCD,BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE))
        val service=BluetoothGattService(BleCentral.SERVICE,BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(BluetoothGattCharacteristic(BleCentral.INPUT,BluetoothGattCharacteristic.PROPERTY_WRITE,BluetoothGattCharacteristic.PERMISSION_WRITE));service.addCharacteristic(output)
        try{check(server.addService(service));Assert.assertTrue("Virtual advertiser did not start",started.await(15,TimeUnit.SECONDS));CountDownLatch(1).await(600,TimeUnit.SECONDS)}
        finally{advertiser.stopAdvertising(advertiseCallback);server.close();instrumentation.uiAutomation.dropShellPermissionIdentity()}
    }
}

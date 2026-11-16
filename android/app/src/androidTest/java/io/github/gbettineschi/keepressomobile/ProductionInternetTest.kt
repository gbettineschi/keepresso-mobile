package io.github.gbettineschi.keepressomobile

import android.Manifest
import android.content.Context
import android.content.ContextWrapper
import android.app.NotificationManager
import android.app.Notification
import android.os.Bundle
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import androidx.test.uiautomator.UiDevice
import computer.iroh.*
import com.google.firebase.messaging.RemoteMessage
import io.github.gbettineschi.keepressomobile.core.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.serialization.json.*
import org.junit.*
import org.junit.rules.RuleChain
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.Socket
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.time.Instant

/** Real production transport/crypto and public fixture identity; native actions are Mac fakes. */
class ProductionInternetTest {
    @get:Rule val rules=RuleChain.outerRule(EmulatorOnlyRule()).around(GrantPermissionRule.grant(Manifest.permission.POST_NOTIFICATIONS))
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private val args get()=InstrumentationRegistry.getArguments()
    private val credential=Credential("11111111-1111-4111-8111-111111111111","22222222-2222-4222-8222-222222222222","Public fixture",ByteArray(32){0x42},"https://legacy.invalid",encode64(ByteArray(32){2}))
    @Before fun prepare(){IrohAndroid.installAndroidContext(context.applicationContext)}
    private inner class Bootstrap:AutoCloseable {
        val socket=Socket().apply{connect(InetSocketAddress("10.0.2.2",requireNotNull(args.getString("bootstrapPort")).toInt()),5_000);soTimeout=15_000}
        val input=DataInputStream(socket.getInputStream());val output=DataOutputStream(socket.getOutputStream())
        val client=ClientSession(credential.macId,credential.deviceId,credential.key)
        val configuration:InternetConfiguration
        init {
            send(client.hello());send(client.challenge(read()))
            val ready=obj(client.receive(read(),Instant.now()))
            configuration=InternetConfiguration.decode(ready.getValue("internet").toString())
        }
        fun send(record:String){val b=record.toByteArray();output.writeInt(b.size);output.write(b);output.flush()}
        fun read():String{val n=input.readInt();require(n in 1..65536);return ByteArray(n).also{input.readFully(it)}.decodeToString(throwOnInvalidSequence=true)}
        fun request(raw:String):JsonObject{send(client.sealRequest(raw,Instant.now()));return obj(client.receive(read(),Instant.now()))}
        override fun close(){socket.close()}
    }
    private fun enroll():InternetConfiguration {
        val store=CredentialStore(context);store.save(credential)
        return Bootstrap().use{InternetCredentialStore(store,credential).acceptAuthenticated(it.configuration.encoded())}
    }
    private inner class Link {
        val messages=Channel<JsonObject>(32)
        lateinit var connection:IrohConnection
        suspend fun next():JsonObject=withTimeout(30_000){messages.receive()}
        suspend fun request(raw:String):JsonObject {
            withContext(Dispatchers.Main){connection.sendRecord(connection.prepare(raw))}
            val id=obj(raw).string("id")
            return withTimeout(30_000){var r=next();while(r.string("type")!="response" || r.string("id")!=id)r=next();r}
        }
        suspend fun status()=request(Requests.create("status",Instant.now()))
        suspend fun close(){withContext(Dispatchers.Main){connection.close()};messages.close()}
    }
    private suspend fun open(config:InternetConfiguration,key:ByteArray=credential.key):Link {
        val link=Link()
        withContext(Dispatchers.Main){
            link.connection=IrohConnection(context,credential.copy(key=key),config,{m,_->link.messages.trySend(m)}, {link.messages.close()})
        }
        try{Assert.assertEquals("ready",link.next().string("type"));return link}catch(e:Exception){link.close();throw e}
    }
    @Test fun identityEnrollmentAndRestartLookup()=runBlocking {
        val store=CredentialStore(context)
        val old=store.load()?.let{InternetCredentialStore(store,it).configuration}
        val config=if(args.getString("restart")=="true")requireNotNull(old) else enroll()
        val link=open(config)
        try {
            val samples=mutableListOf<Long>()
            repeat(10){val begin=System.nanoTime();Assert.assertEquals("ok",link.status().string("status"));samples+=(System.nanoTime()-begin)/1_000_000}
            val sorted=samples.sorted()
            InstrumentationRegistry.getInstrumentation().sendStatus(2,Bundle().apply{putString("stream","PRODUCTION mode=${args.getString("mode")} restart=${args.getString("restart")} medianMs=${sorted[sorted.size/2]} maxMs=${sorted.last()}")})
            Assert.assertArrayEquals(credential.key,store.load()!!.key)
            Assert.assertEquals(credential.relayAuthTicket,store.load()!!.relayAuthTicket)
        }finally{link.close()}
    }
    @Test fun simultaneousNearbyCarrierAndInternetMutationExecutesOnce()=runBlocking {
        val config=enroll();val bootstrap=Bootstrap();val link=open(config)
        try {
            bootstrap.request(Requests.create("status",Instant.now()));val baseline=link.status()["snapshot"]!!.jsonObject.getValue("fixtureMutationCount").jsonPrimitive.int
            val raw=Requests.create("start_manual",Instant.now(),15)
            val nearby=async(Dispatchers.IO){bootstrap.request(raw)}
            val internet=async{link.request(raw)}
            Assert.assertTrue(setOf("ok","uncertain").contains(nearby.await().string("status")))
            Assert.assertTrue(setOf("ok","uncertain").contains(internet.await().string("status")))
            Assert.assertEquals(baseline+1,link.status()["snapshot"]!!.jsonObject.getValue("fixtureMutationCount").jsonPrimitive.int)
        }finally{bootstrap.close();link.close()}
    }
    @Test fun simultaneousForegroundAndTokenSessionsStayUsable()=runBlocking {
        val config=enroll();val first=open(config);var second:Link?=null
        try {
            second=open(config)
            repeat(4){Assert.assertEquals("ok",first.status().string("status"));Assert.assertEquals("ok",second.status().string("status"))}
            first.close()
            Assert.assertEquals("ok",second.status().string("status"))
        }finally{first.close();second?.close()}
    }
    @Test fun twentyReconnectsSurviveStalledApplicationPeer()=runBlocking {
        val config=enroll();val warm=open(config);try{warm.status()}finally{warm.close()}
        val endpoint=Endpoint.bind(EndpointOptions(preset=presetN0(),relayMode=RelayMode.defaultMode()))
        var stalled:Connection?=null
        try {
            repeat(20){index ->
                if(index%5==0){
                    stalled?.close(0,byteArrayOf())
                    stalled=try{withTimeout(25_000){endpoint.connect(EndpointAddr(EndpointId.fromBytes(decode64(config.endpointId,32)),null,emptyList()),IrohConnection.ALPN)}}catch(e:Exception){throw AssertionError("Stalled peer dial at reconnect $index",e)}
                    stalled!!.openBi().send().writeAll(byteArrayOf(0))
                }
                val link=try{open(config)}catch(e:Exception){throw AssertionError("Production open at reconnect $index",e)}
                try{Assert.assertEquals("ok",link.status().string("status"))}finally{link.close()}
            }
        }finally{stalled?.close(0,byteArrayOf());endpoint.shutdown()}
    }
    @Test fun selectedPathAndOversizedFrameRejection()=runBlocking {
        val config=enroll();val warm=open(config);try{warm.status()}finally{warm.close()}
        val endpoint=Endpoint.bind(EndpointOptions(preset=presetN0(),relayMode=RelayMode.defaultMode()))
        try {
            val connection=withTimeout(25_000){endpoint.connect(EndpointAddr(EndpointId.fromBytes(decode64(config.endpointId,32)),null,emptyList()),IrohConnection.ALPN)}
            try {
                val paths=connection.paths().filter{it.isSelected}
                Assert.assertTrue("No selected path",paths.isNotEmpty())
                if(args.getString("mode")=="relay")Assert.assertTrue("Forced relay used a direct path",paths.all{it.isRelay})
                InstrumentationRegistry.getInstrumentation().sendStatus(2,Bundle().apply{putString("stream","PRODUCTION_PATH mode=${args.getString("mode")} path=${paths.map{if(it.isRelay) "relay" else if(it.isIp) "ip" else "other"}.distinct()}")})
                val bi=connection.openBi();bi.send().writeAll(ByteBuffer.allocate(4).putInt(65_537).array())
                val closed=runCatching{withTimeout(8_000){bi.recv().readExact(1u)}}
                Assert.assertTrue(closed.isFailure);Assert.assertFalse(closed.exceptionOrNull() is TimeoutCancellationException)
            }finally{connection.close(0,byteArrayOf())}
        }finally{endpoint.shutdown()}
    }
    @Test fun wrongKeyCannotAuthenticate()=runBlocking {
        val config=enroll();val valid=open(config)
        try {
            Assert.assertEquals("ok",valid.status().string("status"))
            Assert.assertTrue(runCatching{open(config,ByteArray(32){7})}.isFailure)
            Assert.assertEquals("ok",valid.status().string("status"))
        }finally{valid.close()}
    }
    @Test fun expiredAndOversizedAuthenticatedEventsCannotNotify() {
        CredentialStore(context).save(credential)
        val service=RelayMessagingService()
        ContextWrapper::class.java.getDeclaredMethod("attachBaseContext",Context::class.java).apply{isAccessible=true}.invoke(service,context)
        val codec=RelayCodec(credential.macId,credential.deviceId,credential.key)
        val now=Instant.now()
        for(expired in listOf(true,false)) {
            val id=java.util.UUID.randomUUID().toString()
            val at=if(expired)now.minusSeconds(400) else now
            val event=buildJsonObject{put("id",id);put("kind","hourly");put("createdAt",at.toString());put("title","Rejected fixture");put("body","Must not appear")}
            val payload=buildJsonObject{put("type","event");put("event",event);if(!expired)put("padding","x".repeat(3500))}.toString()
            val envelope=codec.seal(payload,id,id,"s2c","event",at,at.plusSeconds(300))
            service.onMessageReceived(RemoteMessage.Builder("fixture").setData(mapOf("relayEnvelope" to envelope)).build())
        }
        Assert.assertFalse(Companion.state.value.activity.any{it.text=="Rejected fixture"})
        Assert.assertFalse(context.getSystemService(NotificationManager::class.java).activeNotifications.any{it.notification.extras.getString(Notification.EXTRA_TITLE)=="Rejected fixture"})
    }
    @Test fun encryptedMacEventIsDeduplicatedWhileScreenOff()=runBlocking {
        val config=enroll();val link=open(config);val device=UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
        try {
            val envelope=link.status()["snapshot"]!!.jsonObject.getValue("fixtureEnvelope").toString()
            device.sleep()
            Companion.mutable.value=UiState()
            val service=RelayMessagingService()
            ContextWrapper::class.java.getDeclaredMethod("attachBaseContext",Context::class.java).apply{isAccessible=true}.invoke(service,context)
            repeat(2){service.onMessageReceived(RemoteMessage.Builder("fixture").setData(mapOf("relayEnvelope" to envelope)).build())}
            Assert.assertEquals(1,Companion.state.value.activity.count{it.text=="Production fixture reminder"})
            val manager=context.getSystemService(NotificationManager::class.java)
            Assert.assertEquals(1,manager.activeNotifications.count{it.notification.extras.getString(Notification.EXTRA_TITLE)=="Production fixture reminder"})
        }finally{device.wakeUp();link.close()}
    }
}

package io.github.gbettineschi.keepressomobile

import android.Manifest
import android.content.Context
import android.content.ContextWrapper
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.RemoteMessage
import io.github.gbettineschi.keepressomobile.core.*
import kotlinx.serialization.json.*
import java.time.Instant
import java.util.UUID
import org.junit.*
import org.junit.rules.RuleChain
import kotlinx.coroutines.runBlocking
import androidx.work.ListenableWorker

class DirectMessagingTest {
    @get:Rule val rules=RuleChain.outerRule(EmulatorOnlyRule()).around(GrantPermissionRule.grant(Manifest.permission.POST_NOTIFICATIONS))
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private val credential=Credential("11111111-1111-4111-8111-111111111111","22222222-2222-4222-8222-222222222222","Fixture",ByteArray(32){0x42})
    @Before fun prepare(){val store=CredentialStore(context);store.clearPrivateState();store.save(credential);Companion.mutable.value=UiState()}
    @Test fun pendingTokenRecoversAfterLongOutageWithoutForegroundOrRestart()=runBlocking {
        var saved:String?=null
        val state=DirectPushEnrollment({saved},{saved=it})
        state.tokenChanged("keepresso-test","fixture-token")
        val pending=requireNotNull(state.pending("keepresso-test"))
        repeat(8){
            Assert.assertEquals(ListenableWorker.Result.retry(),directRegistrationAttempt{throw java.io.IOException("Mac asleep")})
            Assert.assertEquals(pending,state.pending("keepresso-test"))
        }
        Assert.assertEquals(ListenableWorker.Result.success(),directRegistrationAttempt{
            state.acknowledge(PushRegistrationAck(pending.projectId,pending.revision,pending.tokenHash))
        })
        Assert.assertNull(state.pending("keepresso-test"))
    }
    @Test fun runtimeFirebaseOptionsAreIdempotentAndReplacementKeepsPairing() {
        val first=FirebaseClientConfiguration("keepresso-test","1:123456:android:abcdef","AIza"+"A".repeat(35),"123456")
        Assert.assertTrue(FirebaseClientSetup.configure(context,first))
        val app=FirebaseApp.getInstance()
        Assert.assertTrue(FirebaseClientSetup.configure(context,first))
        Assert.assertSame(app,FirebaseApp.getInstance())
        val second=FirebaseClientConfiguration("other-project","1:654321:android:abcdef","AIza"+"B".repeat(35),"654321")
        Assert.assertTrue(FirebaseClientSetup.configure(context,second))
        Assert.assertEquals(second,FirebaseClientSetup.current())
        Assert.assertArrayEquals(credential.key,CredentialStore(context).load()!!.key)
    }
    @Test fun directPushNeedsNoRelayAndSharesNearbyEventClaims() {
        val now=Instant.now();val id=UUID.randomUUID().toString()
        val event=buildJsonObject{put("id",id);put("kind","hourly");put("createdAt",now.toString());put("title","Direct fixture");put("body","Synthetic reminder")}
        val raw=buildJsonObject{put("type","event");put("event",event)}.toString()
        val codec=RelayCodec(credential.macId,credential.deviceId,credential.key)
        val envelope=codec.seal(raw,id,id,"s2c","event",now,now.plusSeconds(300))
        val service=RelayMessagingService()
        ContextWrapper::class.java.getDeclaredMethod("attachBaseContext",Context::class.java).apply{isAccessible=true}.invoke(service,context)
        service.onMessageReceived(RemoteMessage.Builder("fixture").setData(mapOf("relayEnvelope" to envelope)).build())
        service.onMessageReceived(RemoteMessage.Builder("fixture").setData(mapOf("relayEnvelope" to envelope)).build())
        ReminderDelivery.post(context,credential,event,now)
        Assert.assertEquals(1,Companion.state.value.activity.count{it.text=="Direct fixture"})
        Assert.assertNull(CredentialStore(context).load()!!.relayUrl)
    }
}

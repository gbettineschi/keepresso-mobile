package io.github.gbettineschi.keepressomobile

import android.Manifest
import android.content.Intent
import androidx.core.content.ContextCompat
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import io.github.gbettineschi.keepressomobile.core.*
import org.junit.*
import org.junit.rules.RuleChain
import java.time.Instant
import android.os.SystemClock
import kotlinx.serialization.json.*

/** Exercises the actual service callback with synthetic freshness proofs only. */
class TransportStateTest {
    private val ui=createAndroidComposeRule<MainActivity>()
    @get:Rule val rules=RuleChain.outerRule(EmulatorOnlyRule()).around(GrantPermissionRule.grant(Manifest.permission.BLUETOOTH_SCAN,Manifest.permission.BLUETOOTH_CONNECT,Manifest.permission.POST_NOTIFICATIONS)).around(ui)
    @After fun stop(){val c=InstrumentationRegistry.getInstrumentation().targetContext;c.stopService(Intent(c,NearbyService::class.java))}
    private fun scanFailure(age:Long){
        val c=InstrumentationRegistry.getInstrumentation().targetContext
        Assert.assertNull("Use a cleared disposable fixture",CredentialStore(c).load())
        ui.runOnIdle{ContextCompat.startForegroundService(c,Intent(c,NearbyService::class.java).putExtra("foreground",true))}
        ui.waitUntil(5000){Companion.service!=null}
        ui.runOnIdle{
            val service=requireNotNull(Companion.service)
            val freshness=NearbyService::class.java.getDeclaredField("relayFresh").apply{isAccessible=true}.get(service) as RelayFreshness
            val sampled=Instant.now().minusSeconds(age)
            val snapshot=obj("""{"capturedAt":"$sampled","capabilities":{"startManual":true}}""")
            val epoch="11111111-1111-4111-8111-111111111111";val id="22222222-2222-4222-8222-222222222222"
            freshness.state(epoch,1,sampled,snapshot,sampled);freshness.expectStatus(id,sampled);Assert.assertTrue(freshness.status(id,epoch,snapshot,sampled))
            Companion.mutable.value=UiState(authenticated=true,snapshot=snapshot,receivedAt=sampled,lastContact=sampled,pairedName="Fixture",transport="Internet")
            NearbyService::class.java.getDeclaredMethod("disconnected").apply{isAccessible=true}.invoke(service)
        }
    }
    @Test fun unsuccessfulNearbyScanDoesNotInterruptAnAuthenticatedInternetRoute(){
        scanFailure(0);Assert.assertTrue(Companion.state.value.reachable(Instant.now()));Assert.assertEquals("Internet",Companion.state.value.transport)
    }
    @Test fun staleInternetProofCannotKeepControlsEnabledAfterNearbyLoss(){
        scanFailure(30);Assert.assertFalse(Companion.state.value.authenticated);Assert.assertFalse(Companion.state.value.reachable(Instant.now()))
    }
    @Test fun aReadResponseCannotReviveAnUnsentCommandAfterStatusWentStale(){
        val c=InstrumentationRegistry.getInstrumentation().targetContext
        Assert.assertNull(CredentialStore(c).load())
        ui.runOnIdle{ContextCompat.startForegroundService(c,Intent(c,NearbyService::class.java).putExtra("foreground",true))}
        ui.waitUntil(5000){Companion.service!=null}
        ui.runOnIdle{
            val service=requireNotNull(Companion.service)
            fun field(name:String)=NearbyService::class.java.getDeclaredField(name).apply{isAccessible=true}
            // Stop the network executor: a regression may reserve a synthetic command,
            // but it cannot reach any endpoint or native adapter.
            (field("network").get(service) as java.util.concurrent.ExecutorService).shutdownNow()
            val mac="11111111-1111-4111-8111-111111111111";val device="22222222-2222-4222-8222-222222222222"
            val epoch="33333333-3333-4333-8333-333333333333";val id="44444444-4444-4444-8444-444444444444"
            val credential=Credential(mac,device,"Fixture",ByteArray(32),"https://example.invalid",encode64(ByteArray(32)))
            CredentialStore(c).save(credential);field("credential").set(service,credential)
            val now=Instant.now()
            fun snapshot(time:Instant)=obj("""{"capturedAt":"$time","macName":"Fixture","mac":{"lock":"unknown","display":"unknown","lid":"unknown","batteryPercent":null,"powerSource":"unknown","temperatureC":null,"temperatureSensor":null,"thermal":"unknown"},"keepresso":{"appRunning":true,"version":"1.27.0","isActive":false,"endsAt":null,"triggersEnabled":true,"triggersPaused":true,"sessionKind":"unknown","safetyPause":"none"},"capabilities":{"startManual":true,"stopManual":false,"pauseTriggers":false,"resumeTriggers":false,"sleepNow":true,"refreshTriggers":true},"triggers":{"state":"not_checked","checkedAt":null,"combined":null,"rules":[],"message":null},"reminders":{"enabled":true,"intervalSeconds":3600,"endedAwakeDelaySeconds":300,"snoozedUntil":null}}""")
            val freshness=field("relayFresh").get(service) as RelayFreshness
            freshness.state(epoch,1,now.minusSeconds(12),snapshot(now.minusSeconds(12)),now.minusSeconds(12));freshness.expectStatus(id,now.minusSeconds(4))
            val type=NearbyService::class.java.declaredClasses.single{it.simpleName=="Pending"}
            val constructor=type.declaredConstructors.single{it.parameterCount==8}.apply{isAccessible=true}
            field("pending").set(service,constructor.newInstance(id,"status",false,"relay",epoch,now.minusSeconds(4),null,false))
            val waiting=field("waitingCommand").get(service) as UserCommandWait
            Assert.assertTrue(waiting.offer(WaitingCommand("sleep_now"),SystemClock.elapsedRealtime()-2000,"relay:$epoch"))
            // The snapshot was fresh when tapped, but expired while the read was in flight.
            Companion.mutable.value=UiState(authenticated=true,receivedAt=now.minusSeconds(16),snapshot=snapshot(now.minusSeconds(16)),pairedName="Fixture",macId=mac,busy=true,transport="Internet")
            val response=buildJsonObject{put("type","response");put("id",id);put("status","ok");put("snapshot",snapshot(now))}
            NearbyService::class.java.getDeclaredMethod("response",JsonObject::class.java,String::class.java,String::class.java).apply{isAccessible=true}.invoke(service,response,"relay",epoch)
            val journal=field("journal").get(service) as MutationJournal
            Assert.assertTrue("An expired unsent intent must never be reserved or transmitted",journal.unresolved().isEmpty())
            Assert.assertFalse(waiting.hasCommand)
        }
        ReminderDelivery.reset(c)
    }
}

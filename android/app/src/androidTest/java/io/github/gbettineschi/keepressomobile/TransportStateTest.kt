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
}

package io.github.gbettineschi.keepressomobile

import android.Manifest
import android.content.Intent
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.core.content.ContextCompat
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import io.github.gbettineschi.keepressomobile.core.*
import org.junit.*
import org.junit.rules.RuleChain
import java.io.File
import java.time.Instant
import kotlinx.serialization.json.*

/** Opt-in actual HTTPS relay, disposable synthetic Mac only. No native power adapter. */
class LiveRelayTest {
    private val ui=createAndroidComposeRule<MainActivity>()
    @get:Rule val rules=RuleChain.outerRule(EmulatorOnlyRule()).around(GrantPermissionRule.grant(Manifest.permission.BLUETOOTH_SCAN,Manifest.permission.BLUETOOTH_CONNECT,Manifest.permission.POST_NOTIFICATIONS)).around(ui)
    @Test fun encryptedStatusControlsAndDuplicateMutationOverActualInternet(){
        Assume.assumeTrue(InstrumentationRegistry.getArguments().getString("liveRelay")=="true")
        val c=InstrumentationRegistry.getInstrumentation().targetContext
        Assert.assertNull("Use a cleared disposable fixture",CredentialStore(c).load())
        val config=obj(File(c.filesDir,"live-phone.json").readText())
        val credential=Credential(config.string("macId"),config.string("deviceId"),"Synthetic internet Mac",decode64(config.string("key"),32),config.string("url"),config.string("authTicket"))
        CredentialStore(c).save(credential)
        val start=System.nanoTime()
        ui.runOnIdle{ContextCompat.startForegroundService(c,Intent(c,NearbyService::class.java).putExtra("foreground",true))}
        ui.waitUntil(45000){Companion.state.value.reachable(Instant.now())}
        Assert.assertEquals("Internet",Companion.state.value.transport)
        val statusMs=(System.nanoTime()-start)/1_000_000
        val commandStart=System.nanoTime()
        ui.onNodeWithText("Start").performScrollTo().assertIsEnabled().performClick()
        ui.waitUntil(30000){Companion.state.value.snapshot?.get("fixtureStartCount")?.jsonPrimitive?.int==1 && !Companion.state.value.busy}
        val commandMs=(System.nanoTime()-commandStart)/1_000_000
        val store=CredentialStore(c)
        val intent=wireJson.parseToJsonElement(requireNotNull(store.readPrivate("mutationJournal"))).jsonArray.single().jsonObject
        val body=intent.string("body");val request=obj(body)
        // The exact same immutable command may arrive twice; only the durable journal may execute it.
        val epoch=NearbyService::class.java.getDeclaredField("relayFresh").apply{isAccessible=true}.get(Companion.service) as RelayFreshness
        val envelope=RelayCodec(credential.macId,credential.deviceId,credential.key).seal(body,request.string("id"),requireNotNull(epoch.epoch),"c2s","command",Instant.parse(request.string("issuedAt")),Instant.parse(request.string("expiresAt")))
        val remote=RelayHttp(RelayEndpoint(requireNotNull(credential.relayUrl)),credential.macId,credential.deviceId,RelayCodec(credential.macId,credential.deviceId,credential.key).bearer(),requireNotNull(credential.relayAuthTicket))
        remote.call("send",envelope)
        Thread.sleep(7000)
        Assert.assertEquals(1,Companion.state.value.snapshot?.get("fixtureStartCount")?.jsonPrimitive?.int)
        val observationSeconds=(InstrumentationRegistry.getArguments().getString("observeSeconds")?.toIntOrNull() ?: 0).also{require(it in 0..180)}
        var maxSnapshotAgeMs=0L
        val observeUntil=System.nanoTime()+observationSeconds*1_000_000_000L
        while(System.nanoTime()<observeUntil){
            Thread.sleep(500)
            val state=Companion.state.value;val now=Instant.now()
            Assert.assertTrue("Internet reachability lost during sustained observation: ${state.connection}",state.reachable(now))
            maxSnapshotAgeMs=maxOf(maxSnapshotAgeMs,java.time.Duration.between(requireNotNull(state.receivedAt),now).toMillis())
        }
        ui.onNodeWithText("Stop manual session").performScrollTo().assertIsEnabled().performClick()
        ui.waitUntil(30000){Companion.state.value.snapshot?.get("keepresso")?.jsonObject?.get("isActive")?.jsonPrimitive?.boolean==false && !Companion.state.value.busy}
        Assert.assertEquals(1,Companion.state.value.snapshot?.get("fixtureStartCount")?.jsonPrimitive?.int)
        File(c.cacheDir,"live-report.json").writeText(buildJsonObject{put("statusMs",statusMs);put("commandMs",commandMs);put("transport",Companion.state.value.transport);put("observedSeconds",observationSeconds);put("maxSnapshotAgeMs",maxSnapshotAgeMs)}.toString())
    }
}

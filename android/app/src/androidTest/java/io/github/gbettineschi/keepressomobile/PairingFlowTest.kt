package io.github.gbettineschi.keepressomobile

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.app.Instrumentation.ActivityResult
import android.content.Intent
import android.os.Build
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.espresso.intent.Intents
import androidx.test.espresso.intent.Intents.intending
import androidx.test.espresso.intent.matcher.IntentMatchers.hasComponent
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import org.junit.*
import org.junit.rules.RuleChain
import java.time.Instant
import java.net.URLEncoder
import kotlinx.serialization.json.*
import androidx.compose.ui.graphics.asAndroidBitmap

/** Uses real Android GATT/framing/crypto between two isolated virtual devices. */
class PairingFlowTest {
    private val ui=createAndroidComposeRule<MainActivity>()
    @get:Rule val rules=RuleChain.outerRule(EmulatorOnlyRule()).around(GrantPermissionRule.grant(Manifest.permission.BLUETOOTH_SCAN,Manifest.permission.BLUETOOTH_CONNECT,Manifest.permission.POST_NOTIFICATIONS)).around(ui)
    @Before fun setup(){check(Build.HARDWARE=="ranchu");Intents.init()}
    @After fun finish(){Intents.release()}
    private fun scan(){
        val token=URLEncoder.encode("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","UTF-8")
        val invitation="keespresso://pair?v=1&mac=11111111-1111-4111-8111-111111111111&token=$token&expires=${Instant.now().epochSecond+300}&name=Emulated%20Mac"
        intending(hasComponent("com.journeyapps.barcodescanner.CaptureActivity")).respondWith(ActivityResult(Activity.RESULT_OK,Intent().putExtra("SCAN_RESULT",invitation).putExtra("SCAN_RESULT_FORMAT","QR_CODE")))
        ui.onNodeWithText("Scan QR").performClick()
    }
    @Test fun qrApprovalEncryptedDashboardControlsAndReconnect(){
        Assume.assumeTrue(InstrumentationRegistry.getArguments().getString("virtualPeer")=="true")
        scan()
        ui.waitUntil(25000){Companion.state.value.connection.contains("approval",ignoreCase=true)}
        ui.onNodeWithText("Waiting for local approval on Mac…").assertIsDisplayed()
        ui.waitUntil(25000){Companion.state.value.reachable(Instant.now())}
        ui.onNodeWithText("Awake").assertIsDisplayed()
        ui.onNodeWithText("83%").performScrollTo().assertIsDisplayed()
        ui.onNodeWithText("Start").performScrollTo().assertIsEnabled().performClick()
        ui.waitUntil(10000){Companion.state.value.snapshot?.get("keepresso")?.toString()?.contains("\"manual\"")==true}
        ui.onNodeWithText("Stop manual session").assertIsEnabled()
        val notifications=InstrumentationRegistry.getInstrumentation().targetContext.getSystemService(NotificationManager::class.java)
        fun reminders()=notifications.activeNotifications.filter{it.notification.extras.getString("android.title")=="Keepresso test reminder"}
        ui.waitUntil(5000){reminders().isNotEmpty()};Assert.assertEquals(1,reminders().size)
        reminders().single().notification.actions.first{it.title.toString()=="OK"}.actionIntent.send()
        ui.waitUntil(5000){reminders().isEmpty()}
        ui.waitUntil(5000){!Companion.state.value.busy && ui.activity.lifecycle.currentState==androidx.lifecycle.Lifecycle.State.RESUMED}
        ui.waitUntil(5000){runCatching{ui.onNodeWithText("Resume triggers").assertIsEnabled()}.isSuccess}
        ui.onNodeWithText("Resume triggers").performScrollTo().assertIsEnabled().performClick()
        ui.waitUntil(5000){runCatching{ui.onNodeWithText("Resume triggers?").assertIsDisplayed()}.isSuccess}
        ui.onNodeWithText("Resume triggers?").assertIsDisplayed()
        ui.onNodeWithText("Cancel").performClick()
        Assert.assertTrue(Companion.state.value.snapshot.toString().contains("\"manual\""))
        ui.onNodeWithText("Stop manual session").performScrollTo().performClick()
        ui.waitUntil(10000){Companion.state.value.snapshot.toString().contains("\"isActive\":false")}
        ui.onNodeWithText("Settings").performClick()
        ui.onNodeWithContentDescription("Every 2 hours").performScrollTo().performClick()
        ui.waitUntil(10000){Companion.state.value.snapshot.toString().contains("\"intervalSeconds\":7200")}
        ui.onNodeWithText("Snooze 6 hours").performScrollTo().performClick()
        ui.waitUntil(10000){Companion.state.value.snapshot?.get("reminders")?.jsonObject?.get("snoozedUntil")?.let{it!=JsonNull}==true}
        ui.onNodeWithText("Status").performClick()
        ui.onNodeWithText("Check").performScrollTo().performClick()
        ui.waitUntil(10000){Companion.state.value.snapshot.toString().contains("\"state\":\"ready\"")}
        ui.waitUntil(10000){!Companion.state.value.authenticated}
        ui.onNodeWithText("Unreachable").performScrollTo().assertIsDisplayed()
        ui.onNodeWithText("Start").performScrollTo().assertIsNotEnabled()
        ui.waitUntil(35000){Companion.state.value.reachable(Instant.now())}
        ui.onNodeWithText("Awake").performScrollTo().assertIsDisplayed()
        Assert.assertEquals("Emulated Mac",Companion.state.value.pairedName)
        ui.onNodeWithText("Keepresso Mobile").performScrollTo()
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        java.io.File(context.cacheDir,"pairing-flow.png").outputStream().use{ui.onRoot().captureToImage().asAndroidBitmap().compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)}
    }
    @Test fun localDenialDoesNotPersistPhoneAuthorization(){
        Assume.assumeTrue(InstrumentationRegistry.getArguments().getString("virtualPeer")=="deny")
        scan();ui.waitUntil(25000){Companion.state.value.connection=="Pairing denied or expired"}
        ui.onNodeWithText("Pairing denied or expired").assertIsDisplayed()
        Assert.assertNull(CredentialStore(InstrumentationRegistry.getInstrumentation().targetContext).load())
        Assert.assertFalse(Companion.state.value.authenticated)
    }
    @Test fun quietPollKeepsControlsEnabledAndTapWaitsBehindReadWithoutDuplicates(){
        Assume.assumeTrue(InstrumentationRegistry.getArguments().getString("virtualPeer")=="true")
        scan()
        try{ui.waitUntil(25000){Companion.state.value.reachable(Instant.now())}}
        catch(error:Throwable){throw AssertionError("Synthetic peer connection: ${Companion.state.value.connection}; ${Companion.state.value.result}",error)}
        val service=requireNotNull(Companion.service)
        val pending=NearbyService::class.java.getDeclaredField("pending").apply{isAccessible=true}
        fun statusPending():Boolean{
            val value=pending.get(service)?:return false
            return value.javaClass.getDeclaredField("action").apply{isAccessible=true}.get(value)=="status"
        }
        ui.waitUntil(7000){statusPending() && Companion.state.value.reachable(Instant.now())}
        Assert.assertFalse("Quiet reads must not mark the UI busy",Companion.state.value.busy)
        ui.onNodeWithText("Start").performScrollTo().assertIsEnabled().performClick()
        ui.waitUntil(8000){Companion.state.value.snapshot?.get("fixtureStartCount")?.jsonPrimitive?.int==1}
        ui.onNodeWithText("Stop manual session").assertIsEnabled()
        Assert.assertEquals(1,Companion.state.value.snapshot!!.getValue("fixtureStartCount").jsonPrimitive.int)
        ui.onAllNodesWithText("Checking Mac",substring=true).assertCountEquals(0)
    }
}

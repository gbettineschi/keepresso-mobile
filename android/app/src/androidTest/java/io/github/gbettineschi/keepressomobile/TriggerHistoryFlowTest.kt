package io.github.gbettineschi.keepressomobile

import android.Manifest
import android.app.Activity
import android.app.Instrumentation.ActivityResult
import android.content.Intent
import android.os.SystemClock
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.Lifecycle
import androidx.test.espresso.intent.Intents
import androidx.test.espresso.intent.Intents.intending
import androidx.test.espresso.intent.matcher.IntentMatchers.hasComponent
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import kotlinx.serialization.json.*
import org.junit.*
import org.junit.rules.RuleChain
import java.net.URLEncoder
import java.time.Instant

/** A real encrypted GATT exchange with the disposable peer; never an owner Mac. */
class TriggerHistoryFlowTest {
    private val ui=createAndroidComposeRule<MainActivity>()
    @get:Rule val rules=RuleChain.outerRule(EmulatorOnlyRule()).around(GrantPermissionRule.grant(Manifest.permission.BLUETOOTH_ADVERTISE,Manifest.permission.BLUETOOTH_CONNECT,Manifest.permission.POST_NOTIFICATIONS)).around(ui)
    @Before fun setup(){Intents.init()}
    @After fun finish(){Intents.release()}
    private fun checkNow(){ui.onNodeWithText("Check").performScrollTo().assertIsEnabled().performClick()}
    @Test fun explicitChecksRetainTheirAnswerAcrossPollsAndFailures(){
        Assume.assumeTrue(InstrumentationRegistry.getArguments().getString("virtualPeer")=="true")
        val token=URLEncoder.encode("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","UTF-8")
        val invitation="keespresso://pair?v=1&mac=11111111-1111-4111-8111-111111111111&token=$token&expires=${Instant.now().epochSecond+300}&name=Emulated%20Mac"
        intending(hasComponent("com.journeyapps.barcodescanner.CaptureActivity")).respondWith(ActivityResult(Activity.RESULT_OK,Intent().putExtra("SCAN_RESULT",invitation).putExtra("SCAN_RESULT_FORMAT","QR_CODE")))
        ui.onNodeWithText("Scan QR").performClick()
        ui.waitUntil(25000){Companion.state.value.reachable(Instant.now())}
        ui.waitUntil(10000){Companion.state.value.triggerHistory.checkError!=null && !Companion.state.value.checkingTriggers}
        checkNow()
        ui.waitUntil(5000){Companion.state.value.checkingTriggers}
        ui.waitUntil(18000){Companion.state.value.triggerHistory.assessment?.get("rules")?.jsonArray?.size==2 && !Companion.state.value.checkingTriggers}
        val answer=requireNotNull(Companion.state.value.triggerHistory.assessment)
        Assert.assertNull("A successful retry clears the previous error",Companion.state.value.triggerHistory.checkError)
        ui.onNodeWithContentDescription("Fixture agent trigger: Active").performScrollTo().assertIsDisplayed()
        val deadline=SystemClock.elapsedRealtime()+12000
        var polls=0
        while(SystemClock.elapsedRealtime()<deadline){
            val state=Companion.state.value
            Assert.assertTrue("Lightweight status must remain fresh",state.reachable(Instant.now()))
            Assert.assertEquals("Ordinary polling must not replace a manual answer",answer,state.triggerHistory.assessment)
            Assert.assertFalse("Polling must never initiate another check",state.checkingTriggers)
            Assert.assertEquals(2,state.snapshot!!.getValue("fixtureCheckCount").jsonPrimitive.int)
            polls++;Thread.sleep(250)
        }
        checkNow()
        ui.waitUntil(10000){Companion.state.value.triggerHistory.checkError!=null && !Companion.state.value.checkingTriggers}
        Assert.assertEquals("A failed recheck retains rows and original checked time",answer,Companion.state.value.triggerHistory.assessment)
        ui.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
        ui.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
        ui.waitUntil(10000){Companion.state.value.triggerHistory.assessment?.get("rules")?.jsonArray?.isEmpty()==true && !Companion.state.value.checkingTriggers}
        Assert.assertNull(Companion.state.value.triggerHistory.checkError)
        Assert.assertEquals(4,Companion.state.value.snapshot!!.getValue("fixtureCheckCount").jsonPrimitive.int)
        ui.activityRule.scenario.recreate()
        Thread.sleep(3500)
        Assert.assertEquals("Recreating the activity is part of the same visit", 4, Companion.state.value.snapshot!!.getValue("fixtureCheckCount").jsonPrimitive.int)
        java.io.File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir,"trigger-history.json").writeText(buildJsonObject{put("observations",polls);put("explicitChecks",2);put("foregroundChecks",2);put("delayedCheckMs",8000);put("retainedAfterFailure",true);put("emptySuccessReplacedRows",true)}.toString())
    }
}

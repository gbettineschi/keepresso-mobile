package io.github.gbettineschi.keepressomobile

import android.Manifest
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.rule.GrantPermissionRule
import androidx.test.platform.app.InstrumentationRegistry
import androidx.compose.ui.graphics.asAndroidBitmap
import io.github.gbettineschi.keepressomobile.core.obj
import org.junit.*
import org.junit.rules.RuleChain
import java.time.Instant

/** Render the actual screen using synthetic readings, never native controls. */
class DashboardUiTest {
    private val ui=createAndroidComposeRule<MainActivity>()
    @get:Rule val rules=RuleChain.outerRule(EmulatorOnlyRule()).around(GrantPermissionRule.grant(Manifest.permission.BLUETOOTH_SCAN,Manifest.permission.BLUETOOTH_CONNECT,Manifest.permission.POST_NOTIFICATIONS)).around(ui)
    @Before fun state(){show()}
    private fun show(error:Boolean=false,battery:Int=83,thermal:String="normal"){
        val now=Instant.now()
        val json="""{"capturedAt":"$now","macName":"Test Mac","mac":{"lock":"locked","display":"off","lid":"closed","batteryPercent":$battery,"powerSource":"ac","isCharging":true,"temperatureC":58.4,"temperatureSensor":"CPU test","thermal":"$thermal"},"keepresso":{"appRunning":true,"version":"1.27.0","isActive":false,"endsAt":null,"triggersEnabled":true,"triggersPaused":true,"sessionKind":"unknown","safetyPause":"none"},"capabilities":{"startManual":true,"stopManual":false,"pauseTriggers":true,"resumeTriggers":true,"sleepNow":true,"refreshTriggers":true},"triggers":{"state":"${if(error)"error" else "unknown"}","checkedAt":"$now","combined":null,"rules":[{"id":"0","label":"AI agent working (+180s)","satisfied":true,"inGrace":false,"graceRemaining":null,"details":[{"label":"Private agent session","active":true,"agent":"Codex"}]},{"id":"1","label":"Microphone in use","satisfied":null,"inGrace":false,"graceRemaining":null,"details":[]}],"message":"Trigger refresh exceeded its five-second budget or its input/output was unavailable. Worker stopped; previous assessment time preserved."},"reminders":{"enabled":true,"intervalSeconds":3600,"endedAwakeDelaySeconds":300,"snoozedUntil":null}}"""
        ui.runOnIdle{Companion.mutable.value=UiState(connection="Connected nearby",authenticated=true,snapshot=obj(json),receivedAt=now,lastContact=now,pairedName="Test Mac",macId="11111111-1111-4111-8111-111111111111")}
    }
    @Test fun dashboardUsesCompactFactsAndNativeStyleTriggerRows(){
        ui.onNodeWithText("Keepresso Mobile").assertIsDisplayed()
        ui.onNodeWithText("83%").assertIsDisplayed()
        ui.onNodeWithContentDescription("Charging").assertIsDisplayed()
        ui.onNodeWithText("58 °C").assertIsDisplayed()
        ui.onAllNodesWithText("Normal",substring=true,ignoreCase=true).assertCountEquals(0)
        ui.onAllNodesWithText("Connected to power").assertCountEquals(0)
        ui.onNodeWithText("AI agent working (+180s)").performScrollTo().assertIsDisplayed()
        ui.onAllNodesWithText("Codex",substring=true).assertCountEquals(0)
        ui.onAllNodesWithText("Unknown · input unavailable").assertCountEquals(0)
        ui.onNodeWithContentDescription("Microphone in use: Not confirmed").assertExists()
        val title=ui.onNodeWithText("Active triggers").fetchSemanticsNode().boundsInRoot
        val check=ui.onNodeWithText("Check").fetchSemanticsNode().boundsInRoot
        Assert.assertEquals(title.center.y,check.center.y,3f)
    }
    @Test fun durationChangesDoNotResizeStartButton(){
        val button=ui.onNodeWithText("Start").performScrollTo()
        val before=button.fetchSemanticsNode().boundsInRoot.width
        ui.onNodeWithContentDescription("Increase duration").performClick()
        val after=button.fetchSemanticsNode().boundsInRoot.width
        Assert.assertEquals(before,after,0.1f)
    }
    @Test fun triggerFailureDoesNotExposeWorkerDiagnostics(){
        show(true)
        ui.onNodeWithText("Couldn't check triggers").performScrollTo().assertIsDisplayed()
        ui.onAllNodesWithText("five-second budget",substring=true).assertCountEquals(0)
    }
    @Test fun settingsGroupsControlsAndWarningSetup(){
        ui.onNodeWithText("Settings").performClick()
        ui.onNodeWithText("Connection").assertIsDisplayed()
        ui.onNodeWithText("Reminders").performScrollTo().assertIsDisplayed()
        ui.onNodeWithText("Warning alerts").performScrollTo().assertIsDisplayed()
        ui.onNodeWithText("Android alert settings").assertExists()
        ui.onAllNodesWithText("Thermal warnings are not snoozed.",substring=true).assertCountEquals(0)
        ui.onNodeWithText("Test alert").performScrollTo().assertIsDisplayed()
        capture("settings-polish.png")
    }
    @Test fun captureWarmLowBattery(){show(battery=15,thermal="warm");capture("dashboard-warm.png")}
    @Test fun captureDashboard(){capture("dashboard-polish.png")}
    private fun capture(name:String){
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        java.io.File(context.cacheDir,name).outputStream().use{ui.onRoot().captureToImage().asAndroidBitmap().compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)}
    }
}

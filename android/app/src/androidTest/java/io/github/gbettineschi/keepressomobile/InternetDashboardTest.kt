package io.github.gbettineschi.keepressomobile

import android.Manifest
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.test.rule.GrantPermissionRule
import androidx.test.platform.app.InstrumentationRegistry
import io.github.gbettineschi.keepressomobile.core.obj
import org.junit.*
import org.junit.rules.RuleChain
import java.time.Instant

/** Real Compose dashboard, synthetic Mac telemetry, emulator only. */
class InternetDashboardTest {
    private val ui=createAndroidComposeRule<MainActivity>()
    @get:Rule val rules=RuleChain.outerRule(EmulatorOnlyRule()).around(GrantPermissionRule.grant(Manifest.permission.BLUETOOTH_SCAN,Manifest.permission.BLUETOOTH_CONNECT,Manifest.permission.POST_NOTIFICATIONS)).around(ui)
    @Before fun isolated(){Assert.assertNull("Clear this disposable emulator's prior pairing fixture before UI tests",CredentialStore(InstrumentationRegistry.getInstrumentation().targetContext).load())}
    private fun show(internet:String="online",network:String="wifi",name:String?="Home Wi-Fi",age:Long=0,unreachable:Boolean=false,legacy:Boolean=false,checkedAt:String?=null){
        val now=Instant.now()
        val fields=if(legacy) "" else """, "internet":"$internet","internetCheckedAt":"${checkedAt ?: now.minusSeconds(age)}","networkType":"$network","wifiName":${name?.let{"\"$it\""} ?: "null"}"""
        val json="""{"capturedAt":"$now","mac":{"lock":"locked","display":"off","lid":"closed","batteryPercent":83,"powerSource":"ac","isCharging":true,"temperatureC":58.4,"thermal":"normal"$fields},"keepresso":{"appRunning":true,"isActive":false,"triggersPaused":true},"capabilities":{"startManual":true,"sleepNow":true},"triggers":{"state":"not_checked"}}"""
        ui.runOnIdle{Companion.mutable.value=UiState(connection=if(unreachable) "Disconnected" else "Connected nearby",authenticated=!unreachable,snapshot=obj(json),receivedAt=if(unreachable)now.minusSeconds(60) else now,lastContact=now,pairedName="Test Mac",macId="11111111-1111-4111-8111-111111111111")}
    }
    @Test fun internetProofAndWifiAppearTogetherInCompactRow(){
        show()
        ui.onNodeWithText("Online").assertIsDisplayed()
        ui.onNodeWithText("Home Wi-Fi").assertIsDisplayed()
        val internet=ui.onNodeWithText("Internet").fetchSemanticsNode().boundsInRoot
        val wifi=ui.onNodeWithText("Wi-Fi").fetchSemanticsNode().boundsInRoot
        Assert.assertEquals(internet.center.y,wifi.center.y,2f)
        capture("internet-online.png")
    }
    @Test fun offlineMacStillHasNearbyControlsAndAssociatedWifi(){
        show(internet="offline")
        ui.onNodeWithText("Awake").performScrollTo().assertIsDisplayed()
        ui.onNodeWithText("Offline").assertIsDisplayed()
        ui.onNodeWithText("Home Wi-Fi").assertIsDisplayed()
        capture("internet-offline.png")
        ui.onNodeWithText("Start").performScrollTo().assertIsEnabled()
    }
    @Test fun failedProbeDoesNotClaimProvenOffline(){
        show(internet="check_failed")
        ui.onNodeWithText("Check failed").assertIsDisplayed()
        ui.onAllNodesWithText("Offline").assertCountEquals(0)
        capture("internet-check-failed.png")
    }
    @Test fun hiddenWifiAndInitialCheckRemainExplicit(){
        show(internet="checking",name=null)
        ui.onNodeWithText("Checking…").assertIsDisplayed()
        ui.onNodeWithText("Name unavailable").assertIsDisplayed()
        capture("internet-hidden-wifi.png")
    }
    @Test fun longWifiNameFitsAndEthernetDoesNotPretendToBeWifi(){
        show(name="Research-Conference-Network-5GHz")
        ui.onNodeWithText("Research-Conference-Network-5GHz").assertIsDisplayed()
        capture("internet-long-wifi.png")
        show(network="ethernet",name=null)
        ui.onNodeWithText("Ethernet").assertIsDisplayed()
        ui.onAllNodesWithText("Wi-Fi").assertCountEquals(0)
    }
    @Test fun oldInternetProofAndOldHelperDoNotClaimOnline(){
        show(age=60)
        internetValue("Not checked").assertIsDisplayed()
        ui.onAllNodesWithText("Online").assertCountEquals(0)
        show(age=-60)
        internetValue("Not checked").assertIsDisplayed()
        show(legacy=true)
        internetValue("Not checked").assertIsDisplayed()
    }
    @Test fun unreachableMacKeepsExplicitLastKnownContext(){
        show(unreachable=true)
        ui.onNodeWithText("Unreachable").assertIsDisplayed()
        ui.onNodeWithText("Readings below are last known",substring=true).assertIsDisplayed()
        ui.onNodeWithText("Start").performScrollTo().assertIsNotEnabled()
    }
    @Test fun extremeTimestampDoesNotCrashTheDashboard(){
        show(checkedAt="+1000000000-12-31T23:59:59.999999999Z")
        ui.waitForIdle()
        ui.onAllNodesWithText("Online").assertCountEquals(0)
    }
    private fun capture(name:String){
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        java.io.File(context.cacheDir,name).outputStream().use{ui.onRoot().captureToImage().asAndroidBitmap().compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)}
    }
    private fun internetValue(value:String)=ui.onNode(hasText(value) and hasAnyAncestor(hasContentDescription("Mac internet")))
}

package io.github.gbettineschi.keepressomobile

import android.Manifest
import android.app.Activity
import android.app.Instrumentation.ActivityResult
import android.content.Intent
import android.os.Build
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.espresso.intent.Intents
import androidx.test.espresso.intent.Intents.intending
import androidx.test.espresso.intent.matcher.IntentMatchers.hasComponent
import androidx.test.rule.GrantPermissionRule
import org.junit.*
import org.junit.rules.RuleChain
import java.time.Instant
import java.net.URLEncoder

/** Only run against the isolated emulator; scan results contain public synthetic fixture keys. */
class PairingScreenTest {
    private val ui=createAndroidComposeRule<MainActivity>()
    @get:Rule val rules=RuleChain.outerRule(EmulatorOnlyRule()).around(GrantPermissionRule.grant(Manifest.permission.BLUETOOTH_SCAN,Manifest.permission.BLUETOOTH_CONNECT,Manifest.permission.POST_NOTIFICATIONS)).around(ui)
    @Before fun setup(){check(Build.HARDWARE=="ranchu");Intents.init();ui.runOnIdle{Companion.mutable.value=UiState()}}
    @After fun finish(){Intents.release()}
    private fun scan(value:String?){
        val data=Intent().putExtra("SCAN_RESULT",value).putExtra("SCAN_RESULT_FORMAT","QR_CODE")
        intending(hasComponent("com.journeyapps.barcodescanner.CaptureActivity")).respondWith(ActivityResult(if(value==null)Activity.RESULT_CANCELED else Activity.RESULT_OK,data))
        ui.onNodeWithText("Scan QR").performClick()
    }
    @Test fun invalidScannedQrShowsErrorWithoutScrolling(){
        scan("https://example.invalid/not-an-invitation")
        ui.waitUntil(5000){Companion.state.value.result?.contains("Invalid")==true}
        ui.onNodeWithText("Invalid or expired pairing invitation").assertIsDisplayed()
    }
    @Test fun validScannedQrStartsVisibleDiscovery(){
        val token=URLEncoder.encode("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","UTF-8")
        scan("keespresso://pair?v=1&mac=11111111-1111-4111-8111-111111111111&token=$token&expires=${Instant.now().epochSecond+300}&name=TestMac")
        ui.waitUntil(5000){Companion.state.value.connection.contains("Looking")}
        ui.onNodeWithText("Looking for your Mac nearby…",substring=true).assertIsDisplayed()
    }
    @Test fun expiredScannedQrShowsErrorWithoutConnecting(){
        val token=URLEncoder.encode("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","UTF-8")
        // Beyond the client's deliberate clock-skew tolerance; the Mac remains
        // authoritative for the exact invitation deadline.
        scan("keespresso://pair?v=1&mac=11111111-1111-4111-8111-111111111111&token=$token&expires=${Instant.now().epochSecond-601}&name=TestMac")
        ui.waitUntil(5000){Companion.state.value.result?.contains("Invalid")==true}
        ui.onNodeWithText("Invalid or expired pairing invitation").assertIsDisplayed()
        Assert.assertNull(Companion.state.value.pairedName)
    }
    @Test fun cancelledScanLeavesPairingAvailable(){
        scan(null)
        ui.onNodeWithText("Authorize this phone").assertIsDisplayed()
        ui.onNodeWithText("Scan QR").assertIsEnabled()
        Assert.assertNull(Companion.state.value.pairedName)
    }
}

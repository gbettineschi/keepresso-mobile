package io.github.gbettineschi.keepressomobile

import android.app.Activity
import android.app.Instrumentation.ActivityResult
import android.content.Intent
import android.os.Build
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.espresso.intent.Intents
import androidx.test.espresso.intent.Intents.intending
import androidx.test.espresso.intent.matcher.IntentMatchers.hasComponent
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.*
import org.junit.*
import org.junit.rules.RuleChain
import java.time.Instant
import java.net.URLEncoder

class PairingPermissionTest {
    private val ui=createAndroidComposeRule<MainActivity>()
    @get:Rule val rules=RuleChain.outerRule(EmulatorOnlyRule()).around(ui)
    @Before fun setup(){
        check(Build.HARDWARE=="ranchu");Intents.init()
    }
    @After fun finish(){Intents.release()}
    @Test fun scannedInvitationContinuesAfterNearbyPermissionApproval()=permissionHandoff(false)
    @Test fun scannedInvitationSurvivesActivityRecreation()=permissionHandoff(true)
    private fun permissionHandoff(recreate:Boolean){
        val token=URLEncoder.encode("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","UTF-8")
        val invitation="keespresso://pair?v=1&mac=11111111-1111-4111-8111-111111111111&token=$token&expires=${Instant.now().epochSecond+300}&name=TestMac"
        intending(hasComponent("com.journeyapps.barcodescanner.CaptureActivity")).respondWith(ActivityResult(Activity.RESULT_OK,Intent().putExtra("SCAN_RESULT",invitation).putExtra("SCAN_RESULT_FORMAT","QR_CODE")))
        val original=ui.activity
        ui.onNodeWithText("Scan QR").performClick()
        val device=UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
        val allow=device.wait(Until.findObject(By.res("com.android.permissioncontroller:id/permission_allow_button")),4000)
        Assert.assertNotNull("Scanning a QR must request missing Nearby permission and retain the invitation",allow)
        // ActivityScenario.recreate() insists on RESUMED, but the permission
        // dialog legitimately pauses the caller. Request recreation directly.
        if(recreate){InstrumentationRegistry.getInstrumentation().runOnMainSync{original.recreate()};ui.waitUntil(5000){original.isDestroyed}}
        device.wait(Until.findObject(By.res("com.android.permissioncontroller:id/permission_allow_button")),4000)!!.click()
        ui.waitUntil(5000){Companion.state.value.connection.contains("Looking")}
        ui.onNodeWithText("Looking for your Mac nearby…",substring=true).assertIsDisplayed()
    }
}

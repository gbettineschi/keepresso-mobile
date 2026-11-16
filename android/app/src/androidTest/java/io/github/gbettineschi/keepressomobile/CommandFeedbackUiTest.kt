package io.github.gbettineschi.keepressomobile

import android.Manifest
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.rule.GrantPermissionRule
import io.github.gbettineschi.keepressomobile.core.obj
import org.junit.*
import org.junit.rules.RuleChain
import java.time.Instant

/** Synthetic state only: feedback must leave actual scrolled controls exposed. */
class CommandFeedbackUiTest {
    private val ui = createAndroidComposeRule<MainActivity>()
    @get:Rule val rules = RuleChain.outerRule(EmulatorOnlyRule()).around(GrantPermissionRule.grant(Manifest.permission.BLUETOOTH_ADVERTISE,Manifest.permission.BLUETOOTH_CONNECT,Manifest.permission.POST_NOTIFICATIONS)).around(ui)
    private fun show(manual: Boolean = false, result: String? = "Mac acknowledged the command") {
        val now = Instant.now()
        val snapshot = obj("""{"capturedAt":"$now","keepresso":{"isActive":$manual,"sessionKind":"${if(manual) "manual" else "unknown"}","triggersPaused":true},"capabilities":{"startManual":true,"stopManual":true,"resumeTriggers":true,"sleepNow":true,"refreshTriggers":true},"triggers":{"state":"not_checked","rules":[]},"reminders":{"enabled":true,"intervalSeconds":3600,"endedAwakeDelaySeconds":300}}""")
        ui.runOnIdle { Companion.mutable.value = UiState(pairedName="Test Mac",authenticated=true,receivedAt=now,lastContact=now,snapshot=snapshot,result=result) }
    }
    @Test fun persistentAcknowledgementLeavesStopControlAboveFeedback() {
        show(manual=true)
        ui.onNodeWithText("Unattended brewing alert on").performScrollTo()
        val stop = ui.onNodeWithText("Stop manual session").performScrollTo().assertIsEnabled().fetchSemanticsNode().boundsInRoot
        val feedback = ui.onNodeWithText("Mac acknowledged the command").fetchSemanticsNode().boundsInRoot
        Assert.assertTrue("Stop must scroll fully clear of persistent feedback: stop=$stop feedback=$feedback",stop.bottom <= feedback.top)
        Assert.assertEquals("Mac acknowledged the command",Companion.state.value.result)
    }
    @Test fun durationStepperAcceptsPointerInputWithPersistentFeedback() {
        show()
        ui.onNodeWithText("Unattended brewing alert on").performScrollTo()
        ui.onNodeWithContentDescription("Increase duration").performScrollTo().assertIsEnabled().performTouchInput { click() }
        ui.onNodeWithText("2h 15m").assertExists()
        Assert.assertEquals("Mac acknowledged the command",Companion.state.value.result)
    }
    @Test fun settingsActionsStayClearOfPersistentFeedback() {
        show()
        ui.onNodeWithText("Settings").performClick()
        ui.onNodeWithText("Remove phone authorization").performScrollTo()
        val action = ui.onNodeWithText("Snooze 6 hours").performScrollTo().assertIsEnabled().fetchSemanticsNode().boundsInRoot
        val feedback = ui.onNodeWithText("Mac acknowledged the command").fetchSemanticsNode().boundsInRoot
        Assert.assertTrue("Settings action must scroll clear of persistent feedback",action.bottom <= feedback.top)
    }
    @Test fun uncertainMeaningIsVisibleAndOriginalOutcomeIsAvailableInDetails() {
        val original = "Command outcome uncertain. It will never be retried automatically. Check the Mac before issuing another command."
        show(result=original)
        ui.onNodeWithText("Command outcome uncertain. Never retried automatically.").assertIsDisplayed()
        ui.onNodeWithText("Details").performTouchInput { click() }
        ui.onNodeWithText(original).assertIsDisplayed()
        ui.onNodeWithText("Close").performClick()
        Assert.assertEquals(original,Companion.state.value.result)
    }
}

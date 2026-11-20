package io.github.gbettineschi.keepressomobile

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import io.github.gbettineschi.keepressomobile.core.obj
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.time.Instant

/** Rendering only: the callback records a confirmation request, never a power command. */
class SleepButtonTest {
    private val ui = createComposeRule()
    @get:Rule val rules = RuleChain.outerRule(EmulatorOnlyRule()).around(ui)

    private fun show(connection: MacConnectionStatus, busy: Boolean = false): MutableList<String> {
        val confirmations = mutableListOf<String>()
        val now = Instant.now()
        val state = UiState(
            pairedName = "Test Mac", macId = "11111111-1111-4111-8111-111111111111", busy = busy,
            snapshot = obj("""{"capturedAt":"$now","mac":{},"keepresso":{},"capabilities":{"sleepNow":false},"triggers":{},"reminders":{}}"""),
        )
        ui.setContent {
            MaterialTheme {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    StatusScreen(state, now, connection) { confirmations.add(it) }
                }
            }
        }
        return confirmations
    }

    @Test fun sleepCanBeConfirmedWhenCapabilityIsUnavailable() {
        val confirmations = show(MacConnectionStatus.AWAKE)
        ui.onNodeWithText("Sleep now").performScrollTo().assertIsEnabled().performClick()
        ui.runOnIdle { assertEquals(listOf("sleep_now"), confirmations) }
    }

    @Test fun statusRefreshDoesNotDisableSleepConfirmation() {
        val confirmations = show(MacConnectionStatus.UPDATING, busy = true)
        ui.onNodeWithText("Sleep now").performScrollTo().assertIsEnabled().performClick()
        ui.runOnIdle { assertEquals(listOf("sleep_now"), confirmations) }
    }

    @Test fun unreachableMacStillOffersSleepConfirmation() {
        val confirmations = show(MacConnectionStatus.UNREACHABLE)
        ui.onNodeWithText("Sleep now").performScrollTo().assertIsEnabled().performClick()
        ui.runOnIdle { assertEquals(listOf("sleep_now"), confirmations) }
    }
}

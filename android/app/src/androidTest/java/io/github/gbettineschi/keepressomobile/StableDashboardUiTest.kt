package io.github.gbettineschi.keepressomobile

import android.Manifest
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.Lifecycle
import androidx.test.rule.GrantPermissionRule
import io.github.gbettineschi.keepressomobile.core.obj
import io.github.gbettineschi.keepressomobile.core.NearbyRecoveryIssue
import org.junit.*
import org.junit.rules.RuleChain
import java.time.Instant

/** Synthetic readings only; measure actual dashboard geometry on a disposable emulator. */
class StableDashboardUiTest {
    private val ui = createAndroidComposeRule<MainActivity>()
    @get:Rule val rules = RuleChain.outerRule(EmulatorOnlyRule()).around(GrantPermissionRule.grant(Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.POST_NOTIFICATIONS)).around(ui)
    private fun show(longValues: Boolean = false) {
        val now = Instant.now()
        val snapshot = obj("""{"capturedAt":"$now","mac":{"lock":"${if(longValues)"unknown" else "locked"}","display":"off","lid":"closed","batteryPercent":83,"powerSource":"ac","temperatureC":58,"thermal":"normal","internet":"${if(longValues)"check_failed" else "online"}","internetCheckedAt":"$now","networkType":"wifi","wifiName":"${if(longValues)"Research-Conference-Network-5GHz" else "Home"}"},"keepresso":{"isActive":false,"sessionKind":"unknown","triggersPaused":true},"capabilities":{"startManual":true,"refreshTriggers":true,"resumeTriggers":true,"sleepNow":true},"triggers":{"state":"ready","checkedAt":"$now","rules":[{"id":"a","label":"Microphone in use","satisfied":true,"inGrace":false,"details":[]}]},"reminders":{"enabled":true,"intervalSeconds":3600}}""")
        ui.runOnIdle { Companion.mutable.value = UiState(pairedName="Test Mac", authenticated=!longValues, receivedAt=now, lastContact=now, snapshot=snapshot, connection=if(longValues)"Bluetooth service recovered, waiting for an authenticated connection with the paired Mac" else "Connected nearby") }
    }
    @Test fun volatileTextDoesNotMoveBrewingOrTriggerControls() {
        show()
        val brewing = ui.onNodeWithText("Brewing session").fetchSemanticsNode().boundsInRoot.top
        val trigger = ui.onNodeWithText("Active triggers").fetchSemanticsNode().boundsInRoot.top
        show(true)
        Assert.assertEquals(brewing,ui.onNodeWithText("Brewing session").fetchSemanticsNode().boundsInRoot.top,1f)
        Assert.assertEquals(trigger,ui.onNodeWithText("Active triggers").fetchSemanticsNode().boundsInRoot.top,1f)
        ui.onAllNodesWithText("Bluetooth service recovered",substring=true).assertCountEquals(0)
    }
    @Test fun fontScaleKeepsVolatileSlotsAndTriggerHeaderOnOneLine() {
        show()
        ui.runOnUiThread {
            ui.activity.setContent {
                val state = Companion.state.collectAsState().value
                val density = LocalDensity.current.density
                CompositionLocalProvider(LocalDensity provides Density(density, 1.3f)) {
                    MaterialTheme {
                        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal=20.dp)) {
                            StatusScreen(state, Instant.now(), if (state.authenticated) MacConnectionStatus.AWAKE else MacConnectionStatus.UNREACHABLE) {}
                        }
                    }
                }
            }
        }
        val title = ui.onNodeWithText("Active triggers").fetchSemanticsNode().boundsInRoot
        val check = ui.onNodeWithText("Check").fetchSemanticsNode().boundsInRoot
        Assert.assertEquals(title.center.y, check.center.y, 3f)
        val before = ui.onNodeWithText("Brewing session").fetchSemanticsNode().boundsInRoot.top
        show(true)
        Assert.assertEquals(before, ui.onNodeWithText("Brewing session").fetchSemanticsNode().boundsInRoot.top, 1f)
    }
    @Test fun historicalVerdictRemainsVisibleWhenUnreachable() {
        show(true)
        ui.onNodeWithContentDescription("Microphone in use: Active").assertExists()
    }
    @Test fun thermalInfoButtonOpensDetailsWithoutRepeatingMacReadings() {
        show()
        ui.runOnIdle {
            Companion.update {
                it.copy(snapshot = obj("""{"capturedAt":"${it.receivedAt}","mac":{"temperatureC":78,"temperatureSensor":"CPU die","thermal":"warm","thermalSeverity":"fair","thermalGuardActive":true,"modelIdentifier":"MacBookPro18,3"},"keepresso":{"isActive":false,"safetyPause":"thermal"}}"""))
            }
        }
        ui.onNodeWithText("Paused for heat.").performScrollTo().assertIsDisplayed()
        ui.onNode(hasText("Thermal state") and hasText("Fair")).performScrollTo().assertHasNoClickAction()
        ui.onNodeWithContentDescription("Thermal info").performClick()
        ui.onNodeWithText("Thermal details").assertIsDisplayed()
        ui.onNodeWithText("CPU die").assertDoesNotExist()
        ui.onNodeWithText("°C", substring = true).assertDoesNotExist()
        ui.onNodeWithText("macOS thermal state").assertDoesNotExist()
        ui.onNodeWithText("MacBookPro18,3", substring = true).assertDoesNotExist()
        ui.onNode(hasText("Updated at ", substring = true) and !hasText("Nearby Bluetooth", substring = true)).assertDoesNotExist()
        ui.onNodeWithText("About macOS thermal states").assertHasClickAction()
        ui.onNodeWithText("Keepresso heat guard").assertIsDisplayed()
        ui.onNodeWithText("Active").assertIsDisplayed()
    }
    @Test fun aShortDisconnectShowsUpdatingAndKeepsControlsDisabled() {
        show()
        ui.onNodeWithText("Awake").assertIsDisplayed()
        ui.mainClock.autoAdvance = false
        show(true)
        ui.mainClock.advanceTimeBy(1_000)
        ui.onNodeWithText("Updating…").assertIsDisplayed()
        ui.onNodeWithText("Unreachable").assertDoesNotExist()
        ui.onNodeWithText("Check").assertIsNotEnabled()

        show()
        ui.mainClock.advanceTimeBy(1_000)
        ui.onNodeWithText("Awake").assertIsDisplayed()

        show(true)
        ui.mainClock.advanceTimeBy(1_000)
        ui.onNodeWithText("Updating…").assertIsDisplayed()
        ui.runOnIdle { Companion.update { it.copy(connection = "Trying internet") } }
        ui.mainClock.advanceTimeBy(5_200)
        ui.onNodeWithText("Unreachable").assertIsDisplayed()
        ui.onNodeWithText("Readings below are last known", substring = true).assertIsDisplayed()
    }
    @Test fun reopeningStartsAFreshStatusWaitAfterAnExpiredOutage() {
        show(true)
        ui.mainClock.autoAdvance = false
        ui.mainClock.advanceTimeBy(6_200)
        ui.onNodeWithText("Unreachable").assertIsDisplayed()

        ui.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
        ui.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
        ui.mainClock.advanceTimeBy(1_000)
        ui.onNodeWithText("Updating…").assertIsDisplayed()
        ui.onNodeWithText("Unreachable").assertDoesNotExist()
        ui.onNodeWithText("Check").assertIsNotEnabled()

        show()
        ui.mainClock.advanceTimeBy(1_000)
        ui.onNodeWithText("Awake").assertIsDisplayed()
    }
    @Test fun failedCheckFeedbackStaysCompactAndSuccessClearsIt() {
        show()
        ui.runOnIdle {
            Companion.update {
                val history = it.triggerHistory.telemetry(it.snapshot?.get("triggers") as kotlinx.serialization.json.JsonObject)
                it.copy(triggerHistory=history.failed("Bounded worker failed: private diagnostic"))
            }
        }
        ui.onNodeWithText("Couldn't check triggers. Showing previous result.").performScrollTo().assertIsDisplayed()
        ui.onAllNodesWithText("private diagnostic",substring=true).assertCountEquals(0)
        ui.runOnIdle { Companion.update { it.copy(triggerHistory=it.triggerHistory.completed(it.triggerHistory.assessment)) } }
        ui.onAllNodesWithText("Couldn't check triggers",substring=true).assertCountEquals(0)
    }
    @Test fun actionableRecoveryGuidanceDoesNotMoveDashboardControls() {
        show(true)
        val before = ui.onNodeWithText("Brewing session").fetchSemanticsNode().boundsInRoot.top
        for (issue in listOf(NearbyRecoveryIssue.PERMISSION_REQUIRED, NearbyRecoveryIssue.AUTHORIZATION_STOPPED)) {
            ui.runOnIdle { Companion.update { it.copy(nearbyRecoveryIssue=issue) } }
            ui.onNodeWithText(issue.compactMessage,substring=true).assertIsDisplayed()
            Assert.assertEquals(before,ui.onNodeWithText("Brewing session").fetchSemanticsNode().boundsInRoot.top,1f)
            ui.onAllNodesWithText("Bluetooth service recovered",substring=true).assertCountEquals(0)
        }
    }
    @Test fun connectionSettingsExplainStoppedAuthorizationAndPermissionRecovery() {
        show(true)
        ui.onNodeWithText("Settings").performClick()
        for (issue in listOf(NearbyRecoveryIssue.AUTHORIZATION_STOPPED, NearbyRecoveryIssue.PERMISSION_REQUIRED)) {
            ui.runOnIdle { Companion.update { it.copy(nearbyRecoveryIssue=issue) } }
            ui.onNodeWithText(issue.message).assertIsDisplayed()
            ui.onNodeWithText(if(issue==NearbyRecoveryIssue.PERMISSION_REQUIRED) "Permissions" else "Reconnect").assertIsDisplayed()
        }
    }
    @Test fun commandFeedbackAppearsOnlyForOutcomesAndDoesNotMoveControls() {
        show()
        ui.onNodeWithText("No recent commands").assertDoesNotExist()
        ui.onNodeWithText("Details").assertDoesNotExist()
        val trigger = ui.onNodeWithText("Active triggers").fetchSemanticsNode().boundsInRoot.top
        ui.runOnIdle { Companion.update { it.copy(result="Command outcome uncertain. It will never be retried automatically.") } }
        Assert.assertEquals(trigger,ui.onNodeWithText("Active triggers").fetchSemanticsNode().boundsInRoot.top,1f)
        ui.onNodeWithText("Command outcome uncertain. Never retried automatically.").assertIsDisplayed()
        ui.onNodeWithText("Details").performClick()
        ui.onNodeWithText("Command outcome uncertain. It will never be retried automatically.").assertIsDisplayed()
        ui.onNodeWithText("Close").performClick()
        Assert.assertEquals("Command outcome uncertain. It will never be retried automatically.",Companion.state.value.result)
    }
}

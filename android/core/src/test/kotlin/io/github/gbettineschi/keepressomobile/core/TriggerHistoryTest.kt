package io.github.gbettineschi.keepressomobile.core

import kotlinx.serialization.json.*
import kotlin.test.*
import org.junit.Test
import java.time.Instant

class TriggerHistoryTest {
    private fun assessment(time: String = "2026-10-28T12:00:00Z", verdict: String = "true", state: String = "ready", extra: String = "", rules: Boolean = true) =
        obj("""{"state":"$state","checkedAt":"$time","combined":$verdict,"rules":${if(rules) """[{"id":"a","label":"Microphone","satisfied":$verdict,"inGrace":false,"details":[]}]""" else "[]"}$extra}""")

    @Test fun pollsSeedOnlyOnceAndCannotChangeHistoricalVerdictsOrTime() {
        val original = assessment()
        val history = TriggerHistory().telemetry(original).telemetry(assessment("2026-10-28T12:30:00Z", "false"))
        assertEquals(original, history.assessment)
    }
    @Test fun progressAndFailedChecksRetainAssessment() {
        val original = assessment()
        val history = TriggerHistory().telemetry(original).failed("Couldn't check triggers").telemetry(assessment(state="checking", extra=",\"checking\":true"))
        assertEquals(original, history.assessment)
        assertEquals("Couldn't check triggers", history.checkError)
    }
    @Test fun matchingSuccessfulResponseReplacesEvenWithEarlierCaptureAndUnknownInputs() {
        val partial = assessment("2026-10-28T12:01:00Z", "null", "unknown")
        val history = TriggerHistory().telemetry(assessment()).failed("Failed").completed(partial)
        assertEquals(partial, history.assessment)
        assertNull(history.checkError)
    }
    @Test fun completedEmptyRulesReplacePreviousRows() {
        val empty = assessment(rules=false)
        assertEquals(empty, TriggerHistory().telemetry(assessment()).completed(empty).assessment)
    }
    @Test fun contextDoesNotChangeQualityAndSuccessClearsContextAndError() {
        val original = assessment()
        val history = TriggerHistory().telemetry(original).telemetry(assessment(state="stale", extra=",\"outdated\":true"))
        assertEquals(original, history.assessment)
        assertTrue(history.outdated)
        val refreshed = history.failed("Failed").completed(assessment())
        assertFalse(refreshed.outdated)
        assertNull(refreshed.checkError)
    }
    @Test fun pollFailureAndOldPollMetadataCannotRestoreClearedLocalFailure() {
        val history = TriggerHistory().telemetry(assessment()).failed("Failed").completed(assessment())
            .telemetry(assessment(state="error",extra=",\"checkError\":\"Old failure\""))
        assertNull(history.checkError)
        assertEquals("ready", history.assessment?.string("state"))
    }
    @Test fun invalidCompletionKeepsHistoricalAssessmentAndReportsFailure() {
        val original = assessment()
        val history = TriggerHistory().telemetry(original).completed(obj("""{"state":"error","checkedAt":null,"rules":[]}"""))
        assertEquals(original, history.assessment)
        assertNotNull(history.checkError)
    }
    @Test fun optionalProgressContextAndErrorFieldsAreStrictlyValidated() {
        validateSnapshot(obj("""{"triggers":{"checking":true,"outdated":false,"checkError":"Failed"}}"""))
        assertFails { validateSnapshot(obj("""{"triggers":{"checking":"true"}}""")) }
        assertFails { validateSnapshot(obj("""{"triggers":{"outdated":"false"}}""")) }
        assertFails { validateSnapshot(obj("""{"triggers":{"checkError":42}}""")) }
    }
    @Test fun checkTimeoutStaysWithinExistingThirtySecondCommandValidity() {
        val sent = Instant.parse("2026-10-28T12:00:00Z")
        assertFalse(triggerCheckTimedOut(sent, sent.plusSeconds(24)))
        assertTrue(triggerCheckTimedOut(sent, sent.plusSeconds(25)))
        assertTrue(triggerCheckTimedOut(sent, sent.plusSeconds(26)))
    }
}

package io.github.gbettineschi.keepressomobile.core

import java.time.Instant
import kotlin.test.*
import kotlinx.serialization.json.*

class AlertIncidentTest {
    private val now = Instant.parse("2026-11-16T12:00:00Z")
    private val mac = "11111111-1111-4111-8111-111111111111"
    private val incident = "22222222-2222-4222-8222-222222222222"
    private val eventId = "33333333-3333-4333-8333-333333333333"
    private fun event(kind: String, phase: String? = null, at: Instant = now, thermalState: String? = null) = buildJsonObject {
        put("id", eventId)
        put("kind", kind)
        put("title", "Fixture")
        put("body", "Fixture")
        put("createdAt", at.toString())
        phase?.let { put("alertPhase", it); put("incidentId", incident) }
        thermalState?.let { put("thermalState", it); put("thermalSeverity", "critical") }
    }

    @Test fun resolutionIsTerminalAcrossOutOfOrderDeliveries() {
        val active = requireNotNull(AlertIncident.fromEvent(event("lid_awake", "active")))
        val updated = requireNotNull(AlertIncident.fromEvent(event("lid_awake", "updated", now.plusSeconds(1))))
        val resolved = requireNotNull(AlertIncident.fromEvent(event("lid_awake", "resolved", now.plusSeconds(2))))
        assertTrue(updated.isNewerThan(active))
        assertTrue(resolved.isNewerThan(updated))
        assertFalse(updated.isNewerThan(resolved))
        assertFalse(AlertIncident.fromEvent(event("lid_awake", "updated", now.plusSeconds(3)))!!.isNewerThan(resolved))
        assertTrue(AlertIncident.fromEvent(event("lid_awake", "resolved"))!!.isNewerThan(active))
        assertFalse(active.isNewerThan(AlertIncident.fromEvent(event("lid_awake", "resolved"))!!))
    }

    @Test fun resolutionsAreDeliveredEvenIfFreshTelemetryAlreadyProvesRecovery() {
        val snapshot = obj("""{"capturedAt":"${now.plusSeconds(1)}","mac":{"thermalSeverity":"serious","lid":"open","wakeState":"full"}}""")
        fun claim(event: JsonObject) = EventClaims({ null }, {}).claim(mac, event, now.plusSeconds(2), snapshot)
        assertTrue(claim(event("thermal", "resolved", thermalState = "serious")))
        assertFalse(claim(event("thermal", "updated", thermalState = "critical")))
        assertTrue(claim(event("lid_awake", "resolved")))
        assertTrue(claim(event("unattended_brew")))
        assertFails { claim(event("battery", "active")) }
        val recovery = event("thermal", "resolved", at = now.minusSeconds(120), thermalState = "serious")
        assertTrue(claim(recovery))
    }

    @Test fun staleCriticalSilencesAndAnExplicitSnoozeRearmsOnlyWithFreshEvidence() {
        val active = requireNotNull(AlertIncident.fromEvent(event("thermal", "active", thermalState = "critical")))
        val alarm = CriticalAlarmState(active, observedAt = now, snoozedUntil = now.plusSeconds(300))
        assertEquals(CriticalAlarmStatus.SNOOZED, alarm.status(now.plusSeconds(60)))
        assertEquals(CriticalAlarmStatus.STALE, alarm.status(now.plusSeconds(300)))
        assertFalse(alarm.shouldRearm(now.plusSeconds(300)))
        val refreshed = alarm.copy(observedAt = now.plusSeconds(290))
        assertTrue(refreshed.shouldRearm(now.plusSeconds(300)))
        assertFalse(refreshed.copy(snoozedUntil = null).shouldRearm(now.plusSeconds(300)))
        assertEquals(CriticalAlarmStatus.RECOVERED, refreshed.copy(recoveryState = "fair").status(now.plusSeconds(300)))
    }

    @Test fun sleepOutcomesRequireAnExplicitVerifiedOutcome() {
        fun response(status: String, outcome: String? = null): Response {
            val record = buildJsonObject {
                put("type", "response"); put("id", eventId); put("status", status)
                outcome?.let { put("sleepOutcome", it) }
            }
            return Response.parse(record.toString(), now)
        }
        assertEquals("Going to sleep", response("ok", "going_to_sleep").sleepResult().label)
        assertEquals("Couldn’t sleep", response("error", "could_not_sleep").sleepResult().label)
        assertEquals("Couldn’t request sleep", response("uncertain").sleepResult().label)
        assertEquals("Couldn’t request sleep", response("ok").sleepResult().label)
        assertFails { response("ok", "done") }
    }
}

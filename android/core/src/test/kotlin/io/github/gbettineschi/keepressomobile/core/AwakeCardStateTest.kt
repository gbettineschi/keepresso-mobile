package io.github.gbettineschi.keepressomobile.core

import java.time.Instant
import kotlin.test.*
import kotlinx.serialization.json.*

class AwakeCardStateTest {
    private val now = Instant.parse("2026-11-18T12:00:00Z")
    private val mac = "11111111-1111-4111-8111-111111111111"
    private val incident = AlertIncident("22222222-2222-4222-8222-222222222222", AlertPhase.ACTIVE, now)
    private val eventId = "33333333-3333-4333-8333-333333333333"
    private val state = AwakeCardState(incident, eventId, AwakeWarningContext.LID_CLOSED, now, 180_000, 2)
    private fun event(context: String? = null, at: Instant = now, phase: String = "active") = buildJsonObject {
        put("id", eventId); put("kind", "lid_awake"); put("createdAt", at.toString())
        put("title", "Fixture"); put("body", "Fixture"); put("incidentId", incident.id); put("alertPhase", phase)
        context?.let { put("awakeContext", it) }
    }

    @Test fun evidenceIsLiveOnlyBeforeItsElapsedDeadlineOnTheSameBoot() {
        assertEquals(AwakeCardPresentation.LIVE, state.presentation(179_999, 2))
        assertEquals(AwakeCardPresentation.HISTORICAL, state.presentation(180_000, 2))
        assertEquals(AwakeCardPresentation.HISTORICAL, state.presentation(180_001, 2))
        assertEquals(AwakeCardPresentation.HISTORICAL, state.presentation(100, 3))
        assertEquals(AwakeCardPresentation.HISTORICAL, state.copy(expiresAtElapsed = null).presentation(100, 2))
        assertEquals(AwakeCardPresentation.HISTORICAL, state.copy(bootCount = null).presentation(100, 2))
        assertEquals(AwakeCardPresentation.HISTORICAL, state.copy(observedAt = now.plusSeconds(3_600)).presentation(180_001, 2))
    }
    @Test fun resolutionDismissalAndDarkWakeCannotBeRestoredAsHistory() {
        assertEquals(AwakeCardPresentation.HIDDEN, state.copy(incident = incident.copy(phase = AlertPhase.RESOLVED)).presentation(200_000, 2))
        assertEquals(AwakeCardPresentation.HIDDEN, state.copy(dismissedEventId = eventId).presentation(200_000, 2))
        val hidden = state.copy(darkWakeAt = now.plusSeconds(1))
        assertEquals(AwakeCardPresentation.HIDDEN, hidden.presentation(200_000, 2))
        val fresh = hidden.copy(incident = incident.copy(createdAt = now.plusSeconds(2)), eventId = "44444444-4444-4444-8444-444444444444", expiresAtElapsed = 360_000)
        assertEquals(AwakeCardPresentation.LIVE, fresh.presentation(200_000, 2))
    }
    @Test fun optionalContextIsCompatibleButInvalidContextDoesNotConsumeTheEvent() {
        assertEquals(AwakeWarningContext.LID_CLOSED, AwakeWarningContext.fromEvent(event()))
        assertEquals(AwakeWarningContext.SCREEN_OFF, AwakeWarningContext.fromEvent(event("screen_off")))
        var saved: String? = null
        val claims = EventClaims({ saved }, { saved = it })
        assertFails { claims.claim(mac, event("normal"), now, null) }
        assertNull(saved)
        assertFails { claims.claim(mac, JsonObject(event() + ("awakeContext" to JsonPrimitive(3))), now, null) }
        assertNull(saved)
    }
    @Test fun openLidCannotSupersedeAScreenOffIncident() {
        val open = obj("""{"capturedAt":"${now.plusSeconds(1)}","mac":{"lid":"open","wakeState":"full","awakeContext":"screen_off"}}""")
        assertTrue(EventClaims({ null }, {}).claim(mac, event("screen_off"), now.plusSeconds(2), open))
        val normal = obj("""{"capturedAt":"${now.plusSeconds(1)}","mac":{"lid":"closed","wakeState":"full","awakeContext":"normal"}}""")
        assertFalse(EventClaims({ null }, {}).claim(mac, event("screen_off"), now.plusSeconds(2), normal))
        val unknown = obj("""{"capturedAt":"${now.plusSeconds(1)}","mac":{"lid":"open","wakeState":"full","awakeContext":"unknown"}}""")
        assertTrue(EventClaims({ null }, {}).claim(mac, event("lid_closed"), now.plusSeconds(2), unknown))
    }
    @Test fun newNormalEvidenceRequiresFullWakeAndLegacyOpenStillEndsALidWarning() {
        assertTrue(AwakeWarningContext.LID_CLOSED.endedBy(obj("""{"lid":"open"}""")))
        assertFalse(AwakeWarningContext.SCREEN_OFF.endedBy(obj("""{"lid":"open","display":"off"}""")))
        assertFalse(AwakeWarningContext.SCREEN_OFF.endedBy(obj("""{"wakeState":"unknown","awakeContext":"normal"}""")))
        assertTrue(AwakeWarningContext.SCREEN_OFF.endedBy(obj("""{"wakeState":"full","awakeContext":"normal"}""")))
    }
    @Test fun delayedActivityEventsRetainTransportExpiryAndResolutionWins() {
        assertTrue(EventClaims({ null }, {}).claim(mac, event("screen_off", now.minusSeconds(181)), now, null))
        assertTrue(EventClaims({ null }, {}).claim(mac, event("screen_off", now.minusSeconds(299)), now, null))
        assertFalse(EventClaims({ null }, {}).claim(mac, event("screen_off", now.minusSeconds(301)), now, null))
        assertFalse(EventClaims({ null }, {}).claim(mac, event("screen_off", now.minusSeconds(301), "resolved"), now, null))
        val resolved = incident.copy(phase = AlertPhase.RESOLVED)
        assertFalse(incident.copy(phase = AlertPhase.UPDATED, createdAt = now.plusSeconds(1)).isNewerThan(resolved))
    }
}

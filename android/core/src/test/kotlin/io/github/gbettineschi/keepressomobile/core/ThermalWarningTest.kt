package io.github.gbettineschi.keepressomobile.core

import java.time.Instant
import java.util.UUID
import kotlin.test.*
import kotlinx.serialization.json.*
import org.junit.Test

class ThermalWarningTest {
    private val now = Instant.parse("2026-11-16T12:00:00Z")
    private val mac = "11111111-1111-4111-8111-111111111111"

    private fun event(severity: String? = null, createdAt: Instant = now, state: String? = null) = buildJsonObject {
        put("id", UUID.randomUUID().toString())
        put("kind", "thermal")
        put("createdAt", createdAt.toString())
        put("title", "Heat warning")
        put("body", "Fixture")
        severity?.let { put("thermalSeverity", it) }
        state?.let { put("thermalState", it) }
    }

    private fun snapshot(thermal: String, severity: String? = null, age: Long = 1, guardActive: Boolean? = null) = buildJsonObject {
        put("capturedAt", now.plusSeconds(age).toString())
        put("mac", buildJsonObject {
            put("thermal", thermal)
            severity?.let { put("thermalSeverity", it) }
            guardActive?.let { put("thermalGuardActive", it) }
            put("modelIdentifier", "MacBookPro18,3")
        })
    }

    private fun claim(event: JsonObject, snapshot: JsonObject?): Boolean {
        var saved: String? = null
        return EventClaims({ saved }, { saved = it }).claim(mac, event, now.plusSeconds(2), snapshot)
    }

    @Test fun fresherCoolOrDifferentSeverityDiscardsDelayedWarning() {
        assertFalse(claim(event("serious"), snapshot("warm", "fair")))
        assertFalse(claim(event("critical"), snapshot("hot", "serious")))
        assertFalse(claim(event("serious"), snapshot("hot", "critical")))
        assertFalse(claim(event(), snapshot("warm")))
        assertFalse(claim(event(), snapshot("normal", "nominal")))
        assertTrue(claim(event("critical"), snapshot("hot", "critical")))
        assertTrue(claim(event("critical"), snapshot("hot")))
        assertTrue(claim(event("serious"), snapshot("unknown", "unknown")))
        assertTrue(claim(event(), snapshot("hot", "critical")))
        assertTrue(claim(event("serious"), snapshot("normal", "nominal", age = -1)))
    }

    @Test fun newerCriticalOutranksStaleSeriousAndAllowsFreshDowngrades() {
        val critical = ThermalWarning.fromEvent(event("critical"))
        assertFalse(ThermalWarning.fromEvent(event("serious", now.minusSeconds(1))).isNewerThan(critical))
        assertFalse(ThermalWarning.fromEvent(event("serious")).isNewerThan(critical))
        assertTrue(critical.isNewerThan(ThermalWarning.fromEvent(event("serious"))))
        assertTrue(ThermalWarning.fromEvent(event("critical", now.plusSeconds(1))).isNewerThan(critical))
        assertTrue(ThermalWarning.fromEvent(event("serious", now.plusSeconds(1))).isNewerThan(critical))
    }

    @Test fun optionalFieldsValidateWithoutBreakingLegacySnapshotsOrEvents() {
        validateSnapshot(snapshot("hot"))
        validateSnapshot(snapshot("hot", "serious"))
        assertFails { validateSnapshot(snapshot("hot", "extreme")) }
        assertTrue(claim(event(), null))
        assertFails { claim(event("fair"), null) }
        assertFails { claim(event("unknown"), null) }
    }

    @Test fun criticalDeliveryHasTheSameShortLifetimeAsDirectPush() {
        assertTrue(claim(event("critical", now.minusSeconds(57)), null))
        assertFalse(claim(event("critical", now.minusSeconds(58)), null))
        assertTrue(claim(event("serious", now.minusSeconds(58)), null))
    }

    @Test fun fairWarningFollowsTheGuardUntilAReleaseOrCriticalEscalation() {
        val fairWarning = event("serious", state = "fair")
        assertTrue(claim(fairWarning, snapshot("warm", "fair", guardActive = true)))
        assertTrue(claim(fairWarning, snapshot("hot", "serious", guardActive = true)))
        assertFalse(claim(fairWarning, snapshot("warm", "fair", guardActive = false)))
        assertFalse(claim(fairWarning, snapshot("hot", "serious", guardActive = false)))
        assertFalse(claim(fairWarning, snapshot("hot", "critical", guardActive = true)))
        assertTrue(claim(event("critical", state = "critical"), snapshot("hot", "critical", guardActive = false)))
        assertFalse(claim(event("critical", state = "critical"), snapshot("warm", "fair", guardActive = true)))
    }

    @Test fun guardAndEventThermalStateValidateAsOptionalNativeValues() {
        validateSnapshot(snapshot("warm", "fair", guardActive = true))
        assertFails { validateSnapshot(obj("""{"mac":{"thermalGuardActive":"true"}}""")) }
        assertFails { claim(event("serious", state = "warm"), null) }
        assertTrue(claim(event("serious", state = "unknown"), null))
    }
}

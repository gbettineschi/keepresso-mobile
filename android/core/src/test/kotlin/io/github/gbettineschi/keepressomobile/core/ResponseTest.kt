package io.github.gbettineschi.keepressomobile.core
import java.time.Instant
import kotlin.test.*
class ResponseTest {
    private val now = Instant.parse("2026-10-23T12:00:00Z")
    @Test fun acceptsAcknowledgementOnlyAfterFullSnapshotValidation() {
        val r = Response.parse("""{"type":"response","id":"33333333-3333-4333-8333-333333333333","status":"ok","snapshot":{"capturedAt":"2026-10-23T12:00:00Z","keepresso":{"isActive":null}}}""", now)
        assertEquals("ok", r.status); assertNull(r.snapshot?.get("keepresso")?.let { (it as kotlinx.serialization.json.JsonObject).boolOrNull("isActive") })
        assertFailsWith<IllegalArgumentException> { Response.parse("""{"type":"response","id":"33333333-3333-4333-8333-333333333333","status":"ok","snapshot":{"capturedAt":"2026-10-23T12:00:00Z","keepresso":{"isActive":"false"}}}""", now) }
    }
    @Test fun rejectsMadeUpOutcomeAndFutureSnapshots() {
        assertFailsWith<IllegalArgumentException> { Response.parse("""{"type":"response","id":"33333333-3333-4333-8333-333333333333","status":"done"}""", now) }
        assertFailsWith<IllegalArgumentException> { Response.parse("""{"type":"response","id":"33333333-3333-4333-8333-333333333333","status":"ok","snapshot":{"capturedAt":"2026-10-23T13:00:00Z"}}""", now) }
    }
}

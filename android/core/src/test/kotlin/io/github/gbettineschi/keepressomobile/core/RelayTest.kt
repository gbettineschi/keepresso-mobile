package io.github.gbettineschi.keepressomobile.core

import java.time.Instant
import kotlin.test.*
import kotlinx.serialization.json.*

class RelayTest {
    private val mac = "11111111-1111-4111-8111-111111111111"
    private val phone = "22222222-2222-4222-8222-222222222222"
    private val epoch = "33333333-3333-4333-8333-333333333333"
    private val id = "44444444-4444-4444-8444-444444444444"
    private val now = Instant.ofEpochSecond(1800000000)
    private val codec = RelayCodec(mac, phone, ByteArray(32) { it.toByte() })
    @Test fun envelopeRoundTripRejectsMetadataTamperingAndWrongEpoch() {
        val sealed = codec.seal("{}", id, epoch, "s2c", "event", now, now.plusSeconds(300))
        assertEquals("{}", codec.open(sealed, now, "s2c", setOf("event"), epoch).plaintext)
        val tampered = JsonObject(obj(sealed) + ("kind" to JsonPrimitive("response"))).toString()
        assertFails { codec.open(tampered, now, "s2c", setOf("response"), epoch) }
        assertFails { codec.open(sealed, now, "s2c", setOf("event"), id) }
    }
    @Test fun expiredFutureOverlongAndWrongDirectionEnvelopesAreRejected() {
        val sealed = codec.seal("{}", id, epoch, "s2c", "state", now, now.plusSeconds(15))
        assertFails { codec.open(sealed, now.plusSeconds(15), "s2c", setOf("state")) }
        assertFails { codec.open(sealed, now.minusSeconds(11), "s2c", setOf("state")) }
        assertFails { codec.open(sealed, now, "c2s", setOf("state")) }
        assertFails { codec.seal("{}", id, epoch, "c2s", "command", now, now.plusSeconds(31)) }
        assertFails { codec.open(" ".repeat(65537), now, "s2c", setOf("state")) }
    }
    @Test fun secureRelayConfigurationRejectsCredentialsQueriesAndCleartext() {
        assertEquals("https://example.org/api/relay", RelayEndpoint("https://example.org/").url.toString())
        for (url in listOf("http://example.org", "https://user:pass@example.org", "https://example.org/?token=abc", "https://example.org/#token", "https://example.org/another")) assertFails { RelayEndpoint(url) }
    }
    @Test fun relayFreshnessRequiresStatusRoundtripAndNeverRefreshesCachedAge() {
        val tracker = RelayFreshness()
        val snap = obj("""{"capturedAt":"${now}","keepresso":{"isActive":true}}""")
        assertTrue(tracker.state(epoch, 1, now, snap, now))
        assertFalse(tracker.reachable(now))
        tracker.expectStatus(id, now)
        assertTrue(tracker.status(id, epoch, snap, now.plusSeconds(1)))
        assertTrue(tracker.reachable(now.plusSeconds(14)))
        assertFalse(tracker.reachable(now.plusSeconds(16)))
        assertFalse(tracker.state(epoch, 1, now, snap, now.plusSeconds(2)))
        assertFalse(tracker.state(epoch, 0, now, snap, now.plusSeconds(2)))
        assertTrue(tracker.state(id, 0, now.plusSeconds(2), snap, now.plusSeconds(2)))
        assertFalse(tracker.reachable(now.plusSeconds(2)))
    }
    @Test fun increasingFreshStateMaintainsProvenConnectionButAGapRequiresAnotherRoundtrip() {
        val tracker = RelayFreshness()
        fun snapshot(time: Instant) = obj("""{"capturedAt":"$time"}""")
        tracker.state(epoch, 0, now, snapshot(now), now)
        tracker.expectStatus(id, now)
        tracker.status(id, epoch, snapshot(now), now.plusSeconds(1))
        assertTrue(tracker.state(epoch, 1, now.plusSeconds(10), snapshot(now.plusSeconds(10)), now.plusSeconds(11)))
        assertTrue(tracker.reachable(now.plusSeconds(22)))
        tracker.state(epoch, 2, now.plusSeconds(30), snapshot(now.plusSeconds(30)), now.plusSeconds(31))
        assertFalse(tracker.reachable(now.plusSeconds(31)))
    }
    @Test fun mutationIntentSurvivesRestartAsUncertainAndKeepsExactBody() {
        var stored: String? = null
        val raw = Requests.create("sleep_now", now)
        val journal = MutationJournal({ stored }, { stored = it })
        val operation = journal.reserve(raw)
        assertEquals(raw, MutationJournal({ stored }, { stored = it }).unresolved().single().body)
        journal.transmitting(operation.id)
        val restarted = MutationJournal({ stored }, { stored = it })
        assertEquals("uncertain", restarted.unresolved().single().status)
        assertFails { restarted.reserve(raw) }
        restarted.reconcile(operation.id, "not_found")
        assertEquals("uncertain", restarted.unresolved().single().status)
        restarted.reconcile(operation.id, "ok")
        assertTrue(restarted.unresolved().isEmpty())
    }
    @Test fun routeSelectionNeverFallsBackAfterTransmission() {
        val router = RequestRoute()
        assertEquals("nearby", router.select(true, true))
        router.begin()
        assertFails { router.select(false, true) }
        assertEquals("relay", RequestRoute().select(false, true))
        assertFails { RequestRoute().select(false, false) }
    }
    @Test fun persistedSubmissionPrecedesSendingAndFailureCannotChooseAnotherRoute() {
        var stored: String? = null
        val journal = MutationJournal({ stored }, { stored = it })
        val body = Requests.create("sleep_now", now)
        val submission = CommandSubmission(body, nearby = true, relay = true)
        assertEquals("nearby", submission.route)
        var received: String? = null
        assertFails { submission.transmit(journal) { raw ->
            received = raw
            assertEquals("uncertain", MutationJournal({ stored }, { stored = it }).unresolved().single().status)
            throw IllegalStateException("transport lost after submission began")
        } }
        assertEquals(body, received)
        assertFails { submission.transmit(journal) { fail("must not retry over another route") } }
    }
    @Test fun persistedEventClaimRejectsHandoffDuplicateExpiredAndResolvedIncident() {
        var stored: String? = null
        val claims = EventClaims({ stored }, { stored = it })
        val e = obj("""{"id":"$id","kind":"thermal","createdAt":"$now","title":"Hot","body":"Check Mac"}""")
        assertTrue(claims.claim(mac, e, now, null))
        assertFalse(EventClaims({ stored }, { stored = it }).claim(mac, e, now, null))
        val other = JsonObject(e + ("id" to JsonPrimitive(epoch)))
        assertFalse(claims.claim(mac, other, now.plusSeconds(301), null))
        val snapshot = obj("""{"capturedAt":"${now.plusSeconds(1)}","mac":{"thermal":"normal"}}""")
        assertFalse(claims.claim(mac, other, now.plusSeconds(2), snapshot))
    }
    @Test fun fullEventClaimStoreNeverEvictsAnUnexpiredIdToPermitReplay() {
        var stored: String? = null
        val claims = EventClaims({ stored }, { stored = it })
        fun event(n: Int) = obj("""{"id":"${java.util.UUID(0, n.toLong())}","kind":"hourly","createdAt":"$now","title":"Reminder","body":"Check Mac"}""")
        for (i in 1..256) assertTrue(claims.claim(mac, event(i), now, null))
        assertFalse(claims.claim(mac, event(257), now, null))
        assertFalse(claims.claim(mac, event(1), now, null))
    }
    @Test fun lookupRequestBindsDigestAndCannotCarryPowerFields() {
        val raw = Requests.operationStatus(id, encode64(ByteArray(32)), now)
        Requests.validate(raw, now)
        assertEquals(id, obj(raw).string("operationId"))
        assertFails { Requests.validate(JsonObject(obj(raw) + ("durationMinutes" to JsonPrimitive(15))).toString(), now) }
    }
}

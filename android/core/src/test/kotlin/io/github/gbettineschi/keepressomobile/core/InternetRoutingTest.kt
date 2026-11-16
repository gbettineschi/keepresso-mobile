package io.github.gbettineschi.keepressomobile.core

import java.time.Instant
import kotlin.test.*
import org.junit.Test
import kotlinx.serialization.json.*

class InternetRoutingTest {
    private val mac="11111111-1111-4111-8111-111111111111"
    private val device="22222222-2222-4222-8222-222222222222"
    private val key=ByteArray(32){0x42}
    @Test fun authenticatedMetadataIsBoundToTheUnchangedPairing() {
        var saved:String?=null
        val store=InternetEnrollmentStore(mac,device,key,{saved},{saved=it})
        val config=InternetConfiguration(encode64(ByteArray(32){3}))
        assertFails{store.accept(config.encoded(),false)}
        assertNull(saved)
        store.accept(config.encoded(),true)
        assertEquals(config,InternetEnrollmentStore(mac,device,key,{saved},{saved=it}).configuration)
        val valid=saved
        assertFails{store.accept("{}",true)}
        assertEquals(valid,saved)
        assertFails{InternetEnrollmentStore(device,mac,key,{saved},{})}
        assertFails{InternetEnrollmentStore(mac,device,ByteArray(32){4},{saved},{})}
        assertContentEquals(ByteArray(32){0x42},key)
    }
    @Test fun repeatedStatusMetadataDoesNotRewriteEncryptedStorage() {
        var writes=0;var saved:String?=null
        val store=InternetEnrollmentStore(mac,device,key,{saved},{writes++;saved=it})
        val config=InternetConfiguration(encode64(ByteArray(32){3}))
        store.accept(config.encoded(),true);store.accept(config.encoded(),true)
        assertEquals(1,writes)
    }
    @Test fun routePreferenceAndSingleSubmissionNeverReplayAnUncertainMutation() {
        assertEquals("nearby",RequestRoute().select(true,true,true))
        assertEquals("iroh",RequestRoute().select(false,true,true))
        assertEquals("relay",RequestRoute().select(false,true,false))
        val body=Requests.create("pause_triggers",Instant.parse("2026-10-30T12:00:00Z"))
        var saved:String?=null;var sends=0
        val journal=MutationJournal({saved},{saved=it});val submission=CommandSubmission(body,false,true,true)
        assertEquals("iroh",submission.route)
        assertFails{submission.transmit(journal){sends++;error("ambiguous link loss")}}
        assertEquals("uncertain",journal.unresolved().single().status)
        assertFails{submission.transmit(journal){sends++}}
        assertEquals(1,sends)
    }
    @Test fun statusProofExpiresAndAChangedConnectionCannotUseIt() {
        val now=Instant.parse("2026-10-30T12:00:00Z");val fresh=InternetFreshness()
        fresh.connected("one")
        assertFalse(fresh.reachable(now))
        val snapshot=buildJsonObject{put("capturedAt",now.toString())}
        assertFalse(fresh.status("old",snapshot,now))
        assertTrue(fresh.status("one",snapshot,now))
        assertTrue(fresh.reachable(now.plusSeconds(14)))
        // A quiet read failure supplies no evidence and cannot renew the proof.
        assertFalse(fresh.reachable(now.plusSeconds(16)))
        fresh.connected("two");assertFalse(fresh.reachable(now))
        assertFalse(fresh.status("one",snapshot,now))
        fresh.disconnect();assertFalse(fresh.reachable(now))
    }
}

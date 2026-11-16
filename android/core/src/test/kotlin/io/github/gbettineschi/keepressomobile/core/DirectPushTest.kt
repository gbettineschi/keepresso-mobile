package io.github.gbettineschi.keepressomobile.core

import kotlin.test.*
import org.junit.Test
import java.time.Instant
import kotlinx.serialization.json.*

class DirectPushTest {
    @Test fun rotationRestartAndOldAcknowledgementKeepNewestRegistrationPending() {
        var saved:String?=null
        fun state()=DirectPushEnrollment({saved},{saved=it})
        state().tokenChanged("keepresso-test","one")
        val first=requireNotNull(state().pending("keepresso-test"))
        state().tokenChanged("keepresso-test","two")
        assertFalse(state().acknowledge(PushRegistrationAck(first.projectId,first.revision,first.tokenHash)))
        val newest=requireNotNull(state().pending("keepresso-test"))
        assertEquals("two",newest.token);assertTrue(newest.revision>first.revision)
        assertFalse(state().tokenRequested("keepresso-test","older-callback",first.revision))
        // An unavailable Mac changes no durable state: the same maintenance
        // registration survives process death and may be sent again safely.
        assertEquals(newest,state().pending("keepresso-test"))
        assertTrue(state().acknowledge(PushRegistrationAck(newest.projectId,newest.revision,newest.tokenHash)))
        assertNull(state().pending("keepresso-test"))
        state().tokenChanged("other-project","three")
        assertTrue(requireNotNull(state().pending("other-project")).revision>newest.revision)
        assertNull(state().pending("keepresso-test"))
    }
    @Test fun fullEncryptedEventNeedsNoLegacyRelayAndDeduplicatesWithNearby() {
        val mac="11111111-1111-4111-8111-111111111111";val device="22222222-2222-4222-8222-222222222222"
        val id="33333333-3333-4333-8333-333333333333";val now=Instant.parse("2026-10-30T12:00:00Z")
        val codec=RelayCodec(mac,device,ByteArray(32){0x42})
        val event=buildJsonObject{put("id",id);put("kind","hourly");put("createdAt",now.toString());put("title","Fixture");put("body","Still running")}
        val raw=buildJsonObject{put("type","event");put("event",event)}.toString()
        val envelope=codec.seal(raw,id,id,"s2c","event",now,now.plusSeconds(300))
        assertEquals(event,DirectPushEvent.decode(codec,envelope,now))
        var claims:String?=null
        val dedup=EventClaims({claims},{claims=it})
        assertTrue(dedup.claim(mac,event,now,null))
        assertFalse(dedup.claim(mac,DirectPushEvent.decode(codec,envelope,now),now,null))
        assertFails{DirectPushEvent.decode(codec,envelope,now.plusSeconds(301))}
        assertFails{DirectPushEvent.decode(RelayCodec(mac,id,ByteArray(32){0x42}),envelope,now)}
        assertFails{DirectPushEvent.decode(codec,envelope.replace("ciphertext","broken"),now)}
    }
}

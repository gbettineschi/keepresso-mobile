package io.github.gbettineschi.keepressomobile.core
import java.time.Instant
import kotlin.test.*

class LidEventTest {
    private val now=Instant.parse("2026-10-24T00:00:00Z")
    private val mac="11111111-1111-4111-8111-111111111111"
    private val event=obj("""{"id":"22222222-2222-4222-8222-222222222222","kind":"lid_awake","createdAt":"$now","title":"Lid closed","body":"Mac is awake"}""")
    @Test fun lidWarningBypassesRoutineSnoozeButIsClaimedOnlyOnceAcrossRoutes(){
        var stored:String?=null
        val first=EventClaims({stored},{stored=it})
        assertTrue(first.claim(mac,event,now,null));assertFalse(EventClaims({stored},{stored=it}).claim(mac,event,now,null))
        val snooze=LocalSnooze({now.plusSeconds(21600).epochSecond},{_,_->})
        assertFalse(snooze.suppressed(mac,"lid_awake",now))
    }
    @Test fun aNewerOpenLidSnapshotSuppressesAnObsoleteWarning(){
        val snapshot=obj("""{"capturedAt":"${now.plusSeconds(1)}","mac":{"lid":"open"}}""")
        assertFalse(EventClaims({null},{}).claim(mac,event,now.plusSeconds(2),snapshot))
    }
}

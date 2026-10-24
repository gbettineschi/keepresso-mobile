package io.github.gbettineschi.keepressomobile.core
import java.time.Instant
import kotlin.test.*
class LocalSnoozeTest {
    private val records = mutableMapOf<String, Long>()
    private val snooze = LocalSnooze({ records[it] }, { id, until -> if (until == null) records.remove(id) else records[id] = until })
    private val now = Instant.parse("2026-10-23T12:00:00Z")
    @Test fun resumeAcknowledgementClearsLocalSnooze() { snooze.snooze("mac-a", now); assertTrue(snooze.suppressed("mac-a", "hourly", now)); snooze.acknowledge("mac-a", "resume_reminders", "ok"); assertFalse(snooze.suppressed("mac-a", "hourly", now)) }
    @Test fun unreachableAndErrorDoNotPretendMacAcknowledgedResume() { snooze.snooze("mac-a", now); snooze.acknowledge("mac-a", "resume_reminders", "error"); assertTrue(snooze.suppressed("mac-a", "hourly", now)); snooze.acknowledge("mac-a", "resume_reminders", "uncertain"); assertTrue(snooze.suppressed("mac-a", "hourly", now)) }
    @Test fun snoozeIsSixHoursPerMacAndWarningsBypassIt() { snooze.snooze("mac-a", now); assertEquals(now.plusSeconds(21600).epochSecond, records["mac-a"]); assertFalse(snooze.suppressed("mac-b", "hourly", now)); assertFalse(snooze.suppressed("mac-a", "battery", now)); assertFalse(snooze.suppressed("mac-a", "hourly", now.plusSeconds(21600))) }
    @Test fun resetRemovesOldMacSuppression() { snooze.snooze("mac-a", now); snooze.reset("mac-a"); assertFalse(snooze.suppressed("mac-a", "hourly", now)) }
}

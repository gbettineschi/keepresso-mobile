package io.github.gbettineschi.keepressomobile.core
import java.time.Instant
import java.net.URLEncoder
import kotlin.test.*
class ValidationTest {
    @Test fun oldSnapshotDoesNotRenewFreshness() {
        val state = DashboardState(); state.connected = true
        state.update("""{"capturedAt":"2026-10-23T11:59:00Z","keepresso":{"isActive":true}}""", 60000, Instant.parse("2026-10-23T12:00:00Z"))
        assertFalse(state.reachable(60000)); assertEquals(true, state.active())
    }
    @Test fun rejectsMalformedSensorRatherThanShowingInactive() {
        assertFailsWith<IllegalArgumentException> { DashboardState().update("""{"capturedAt":"2026-10-23T12:00:00Z","mac":{"batteryPercent":"72"}}""", 0) }
        assertFailsWith<IllegalArgumentException> { DashboardState().update("""{"capturedAt":"2026-10-23T12:00:00Z","mac":{"lock":"probably"}}""", 0) }
        assertFailsWith<IllegalArgumentException> { DashboardState().update("""{"capturedAt":"2026-10-23T12:00:00Z","triggers":{"rules":[{"satisfied":"true"}]}}""", 0) }
    }
    @Test fun invitationToleratesModestPhoneClockDrift() {
        val token = URLEncoder.encode(encode64(ByteArray(32)), "UTF-8")
        val uri = "keespresso://pair?v=1&mac=11111111-1111-4111-8111-111111111111&token=$token&expires=1300&name=Mac"
        assertEquals(1300, Invitation.parse(uri, 995).expires)
        assertEquals(1300, Invitation.parse(uri, 1305).expires)
    }
    @Test fun rejectsInvalidReminderSettingAndPreservesAllFields() {
        val now = Instant.parse("2026-10-23T12:00:00Z")
        val request = Requests.create("set_reminder_settings", now, settings = ReminderSettings(false, 7200, 600))
        Requests.validate(request, now)
        assertFailsWith<IllegalArgumentException> { Requests.create("set_reminder_settings", now, settings = ReminderSettings(true, 123, 300)) }
    }
}

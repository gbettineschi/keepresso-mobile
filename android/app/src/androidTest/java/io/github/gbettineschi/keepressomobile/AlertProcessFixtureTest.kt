package io.github.gbettineschi.keepressomobile

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import io.github.gbettineschi.keepressomobile.core.obj
import java.time.Instant
import java.util.UUID
import kotlinx.serialization.json.*
import org.junit.*
import org.junit.rules.RuleChain

/** Preparation ends before the host kills the app. Cleanup belongs to the host's final stage. */
class AlertProcessFixtureTest {
    @get:Rule val rules = RuleChain.outerRule(EmulatorOnlyRule()).around(GrantPermissionRule.grant(Manifest.permission.POST_NOTIFICATIONS))
    private val c get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val manager get() = c.getSystemService(NotificationManager::class.java)

    @Test fun prepareAwake() {
        val mac = Credential(UUID.randomUUID().toString(), UUID.randomUUID().toString(), "Process fixture", ByteArray(32) { 11 })
        ReminderDelivery.replace(c, mac)
        val event = buildJsonObject {
            put("id", UUID.randomUUID().toString()); put("kind", "lid_awake")
            put("incidentId", UUID.randomUUID().toString()); put("alertPhase", "active")
            put("createdAt", Instant.now().minusSeconds(172).toString()); put("awakeContext", "screen_off")
            put("title", "Your Mac is running with the screen off"); put("body", "Synthetic process fixture")
        }
        ReminderDelivery.post(c, mac, event, Instant.now())
        LidAlert.clearTimer() // Force the system-owned fallback, even if instrumentation leaves the process alive.
    }

    @Test fun verifyHistory() {
        LidAlert.restore(c)
        val end = android.os.SystemClock.elapsedRealtime() + 3_000
        fun history() = manager.activeNotifications.any {
            it.notification.extras.getString(Notification.EXTRA_TITLE) == "Your Mac was running with the screen off" &&
                it.notification.flags and Notification.FLAG_ONGOING_EVENT == 0
        }
        while (!history() && android.os.SystemClock.elapsedRealtime() < end) android.os.SystemClock.sleep(40)
        Assert.assertTrue("Historical evidence must survive a separate process", history())
    }

    @Test fun prepareCritical() {
        val mac = Credential(UUID.randomUUID().toString(), UUID.randomUUID().toString(), "Process fixture", ByteArray(32) { 11 })
        ReminderDelivery.replace(c, mac)
        ReminderDelivery.post(c, mac, buildJsonObject {
            put("id", UUID.randomUUID().toString()); put("kind", "thermal")
            put("incidentId", UUID.randomUUID().toString()); put("alertPhase", "active")
            put("createdAt", Instant.now().toString()); put("thermalSeverity", "critical"); put("thermalState", "critical")
            put("title", "Synthetic Critical fixture"); put("body", "Synthetic process fixture")
        }, Instant.now())
    }

    @Test fun prepareSnoozedCritical() {
        prepareCritical()
        CriticalHeatAlerts.snooze(c, requireNotNull(CriticalHeatAlerts.state.value))
        val store = CredentialStore(c)
        val record = obj(requireNotNull(store.readPrivate(CRITICAL_INCIDENT_KEY)))
        // Represent an Ignore that began 292s ago; production Ignore remains exactly 300s.
        store.writePrivate(CRITICAL_INCIDENT_KEY, JsonObject(record + mapOf(
            "snoozeElapsed" to JsonPrimitive(android.os.SystemClock.elapsedRealtime() + 8_000),
            "snoozedUntil" to JsonPrimitive(Instant.now().plusSeconds(8).toString()),
            "observedAt" to JsonPrimitive(Instant.now().minusSeconds(100).toString()),
        )).toString())
        CriticalHeatAlerts.restore(c)
    }

    @Test fun verifyCritical() {
        CriticalHeatAlerts.restore(c)
        val end = android.os.SystemClock.elapsedRealtime() + 3_000
        fun ringing() = manager.activeNotifications.any { it.tag?.startsWith("keepresso.critical.") == true && it.notification.flags and Notification.FLAG_INSISTENT != 0 }
        while (!ringing() && android.os.SystemClock.elapsedRealtime() < end) android.os.SystemClock.sleep(40)
        Assert.assertTrue("Unresolved Critical warning must survive a separate process", ringing())
    }

    @Test fun cleanup() { ReminderDelivery.reset(c); manager.cancelAll() }
}

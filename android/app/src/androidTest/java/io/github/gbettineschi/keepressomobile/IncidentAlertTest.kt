package io.github.gbettineschi.keepressomobile

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import io.github.gbettineschi.keepressomobile.core.CriticalAlarmStatus
import java.time.Instant
import java.util.UUID
import kotlinx.serialization.json.*
import org.junit.*
import org.junit.rules.RuleChain

class IncidentAlertTest {
    @get:Rule val rules = RuleChain.outerRule(EmulatorOnlyRule())
        .around(GrantPermissionRule.grant(Manifest.permission.POST_NOTIFICATIONS))
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val notifications get() = context.getSystemService(NotificationManager::class.java)
    private val mac = Credential(UUID.randomUUID().toString(), UUID.randomUUID().toString(), "Fixture", ByteArray(32) { 0x42 })
    private val incident = UUID.randomUUID().toString()
    private val now = Instant.now().truncatedTo(java.time.temporal.ChronoUnit.SECONDS)

    @Before fun setup() { ReminderDelivery.replace(context, mac) }
    @After fun cleanup() { ReminderDelivery.reset(context); notifications.cancelAll() }

    private fun post(kind: String, title: String, phase: String? = null, age: Long = 0, state: String? = null, incidentId: String = incident) {
        val event = buildJsonObject {
            put("id", UUID.randomUUID().toString()); put("kind", kind); put("title", title); put("body", "Fixture")
            put("createdAt", now.plusSeconds(age).toString())
            phase?.let { put("alertPhase", it); put("incidentId", incidentId) }
            state?.let { put("thermalSeverity", "critical"); put("thermalState", it) }
        }
        ReminderDelivery.post(context, mac, event, Instant.now())
    }

    private fun active(kind: String) = notifications.activeNotifications.filter { it.tag?.startsWith("keepresso.$kind.${mac.macId}.") == true }
    private fun await(condition: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 3_000
        while (!condition() && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(30)
        Assert.assertTrue("Expected incident notification state", condition())
    }

    @Test fun lidUsesOneOngoingDefaultPriorityNotificationAndResolutionIsTerminal() {
        post("lid_awake", "Brewing", "active")
        await { active("lid").size == 1 }
        val first = active("lid").single()
        Assert.assertEquals(NotificationManager.IMPORTANCE_DEFAULT, notifications.getNotificationChannel(first.notification.channelId).importance)
        Assert.assertNotEquals(0, first.notification.flags and Notification.FLAG_ONGOING_EVENT)
        Assert.assertEquals(listOf("Sleep now"), first.notification.actions.map { it.title.toString() })
        Assert.assertNotEquals(first.notification.contentIntent, first.notification.actions.single().actionIntent)
        post("lid_awake", "No longer brewing", "updated")
        await { active("lid").singleOrNull()?.notification?.extras?.getString(Notification.EXTRA_TITLE) == "No longer brewing" }
        Assert.assertEquals(first.key, active("lid").single().key)
        Assert.assertNotEquals(0, active("lid").single().notification.flags and Notification.FLAG_ONLY_ALERT_ONCE)
        post("lid_awake", "Resolved", "resolved")
        await { active("lid").isEmpty() }
        post("lid_awake", "Delayed refresh", "updated", age = 1)
        Assert.assertTrue(active("lid").isEmpty())
    }

    @Test fun lidCardExpiresThroughAndroidWhenItsInProcessTimerIsLost() {
        post("lid_awake", "Still awake", "active", age = -178)
        val card = active("lid").single().notification
        Assert.assertTrue(card.timeoutAfter in 1..2_000L)
        LidAlert.clearTimer()
        val deadline = SystemClock.elapsedRealtime() + 10_000
        while (active("lid").isNotEmpty() && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(100)
        Assert.assertTrue("Android should expire the card without an app callback", active("lid").isEmpty())
        LidAlert.restore(context)
        Assert.assertTrue("Reopening must not restore an expired assertion", active("lid").isEmpty())
    }

    @Test fun expiredLidEvidenceNeverCreatesAnAwakeCard() {
        post("lid_awake", "Old closed-lid reading", "active", age = -181)
        Assert.assertTrue(active("lid").isEmpty())
        LidAlert.restore(context)
        Assert.assertTrue(active("lid").isEmpty())
    }

    @Test fun wallClockRollbackCannotRestoreAnExpiredLidCard() {
        post("lid_awake", "Still awake", "active")
        await { active("lid").size == 1 }
        LidAlert.clearTimer()
        val store = CredentialStore(context)
        val record = Json.parseToJsonElement(requireNotNull(store.readPrivate(LID_INCIDENT_KEY))).jsonObject
        // Simulate restoration after the monotonic deadline while wall time appears earlier.
        store.writePrivate(LID_INCIDENT_KEY, JsonObject(record + mapOf(
            "phoneObservedAt" to JsonPrimitive(Instant.now().plusSeconds(3_600).toString()),
            "phoneExpiresAtElapsed" to JsonPrimitive(SystemClock.elapsedRealtime() - 1),
        )).toString())
        LidAlert.restore(context)
        await { active("lid").isEmpty() }
    }

    @Test fun lidEvidenceFromAPreviousPhoneBootIsNotRestored() {
        post("lid_awake", "Still awake", "active")
        await { active("lid").size == 1 }
        LidAlert.clearTimer()
        val store = CredentialStore(context)
        val record = Json.parseToJsonElement(requireNotNull(store.readPrivate(LID_INCIDENT_KEY))).jsonObject
        store.writePrivate(LID_INCIDENT_KEY, JsonObject(record + ("phoneBootCount" to JsonPrimitive(-1))).toString())
        LidAlert.restore(context)
        await { active("lid").isEmpty() }
    }

    @Test fun criticalHeartbeatDoesNotRepostTheAlarmAndRecoveredStatusIsQuiet() {
        post("thermal", "Critical", "active", state = "critical")
        await { active("critical").size == 1 }
        val first = active("critical").single()
        Assert.assertNotEquals(0, first.notification.flags and Notification.FLAG_INSISTENT)
        Assert.assertEquals(listOf("Sleep now", "Ignore for 5 minutes"), first.notification.actions.map { it.title.toString() })
        post("thermal", "Heartbeat", "updated", state = "critical")
        Assert.assertEquals(first.postTime, active("critical").single().postTime)
        post("thermal", "Recovered", "resolved", state = "fair")
        await { active("critical").singleOrNull()?.notification?.extras?.getString(Notification.EXTRA_TEXT) == "Now at Fair" }
        val recovered = active("critical").single().notification
        Assert.assertEquals("Your Mac has been critically hot", recovered.extras.getString(Notification.EXTRA_TITLE))
        Assert.assertEquals(0, recovered.flags and Notification.FLAG_INSISTENT)
        Assert.assertEquals(listOf("Sleep now"), recovered.actions.map { it.title.toString() })
        Assert.assertEquals(CriticalAlarmStatus.RECOVERED, CriticalHeatAlerts.state.value?.status)
    }

    @Test fun firstFreshCriticalUpdateRingsAndDarkWakeIsNotRecovery() {
        post("thermal", "Initial packet missed", "updated", state = "critical")
        await { (active("critical").singleOrNull()?.notification?.flags?.and(Notification.FLAG_INSISTENT) ?: 0) != 0 }
        fun snapshot(wake: String, age: Long) = buildJsonObject {
            put("capturedAt", now.plusSeconds(age).toString())
            put("mac", buildJsonObject { put("thermalSeverity", "fair"); put("wakeState", wake) })
        }
        ReminderDelivery.snapshot(context, snapshot("dark", 1))
        Assert.assertEquals(CriticalAlarmStatus.CRITICAL, CriticalHeatAlerts.state.value?.status)
        ReminderDelivery.snapshot(context, snapshot("full", 2))
        Assert.assertEquals(CriticalAlarmStatus.RECOVERED, CriticalHeatAlerts.state.value?.status)
    }

    @Test fun confirmedIgnorePersistsFiveMinuteSnoozeAndSuppressesHeartbeats() {
        post("thermal", "Critical", "active", state = "critical")
        await { active("critical").size == 1 }
        val confirmed = requireNotNull(CriticalHeatAlerts.state.value)
        Assert.assertEquals(CriticalAlarmStatus.CRITICAL, confirmed.status)
        val before = Instant.now()
        CriticalHeatAlerts.snooze(context, confirmed)
        await { active("critical").isEmpty() }
        val record = Json.parseToJsonElement(requireNotNull(CredentialStore(context).readPrivate(CRITICAL_INCIDENT_KEY))).jsonObject
        val snoozedUntil = Instant.parse(record.getValue("snoozedUntil").jsonPrimitive.content)
        Assert.assertTrue(snoozedUntil in before.plusSeconds(300)..Instant.now().plusSeconds(300))
        post("thermal", "Fresh but snoozed", "updated", age = 1, state = "critical")
        Assert.assertNull(CriticalHeatAlerts.state.value)
    }

    @Test fun aNewLidIncidentReplacesTheOldAndAFreshOpenSnapshotClearsIt() {
        post("lid_awake", "Old", "active")
        await { active("lid").size == 1 }
        val second = UUID.randomUUID().toString()
        post("lid_awake", "New", "active", age = 1, incidentId = second)
        await { active("lid").size == 1 && active("lid").single().tag.endsWith(second) }
        post("lid_awake", "Retired", "updated", age = 2)
        Assert.assertTrue(active("lid").single().tag.endsWith(second))
        ReminderDelivery.snapshot(context, buildJsonObject {
            put("capturedAt", now.plusSeconds(3).toString())
            put("mac", buildJsonObject { put("lid", "open"); put("wakeState", "full") })
        })
        await { active("lid").isEmpty() }
    }

    @Test fun darkWakeHidesLidCardWithoutEndingTheIncident() {
        post("lid_awake", "Active", "active")
        await { active("lid").size == 1 }
        ReminderDelivery.snapshot(context, buildJsonObject {
            put("capturedAt", now.plusSeconds(1).toString())
            put("mac", buildJsonObject { put("lid", "closed"); put("wakeState", "dark") })
        })
        await { active("lid").isEmpty() }
        LidAlert.restore(context)
        Assert.assertTrue(active("lid").isEmpty())
        post("lid_awake", "Full wake", "updated", age = 2)
        await { active("lid").singleOrNull()?.notification?.extras?.getString(Notification.EXTRA_TITLE) == "Full wake" }
    }

    @Test fun unattendedUsesTheRoutineChannelWithOneExplicitSleepAction() {
        post("unattended_brew", "Unattended brewing")
        await { active("unattended").size == 1 }
        val notification = active("unattended").single().notification
        Assert.assertEquals("reminders", notification.channelId)
        Assert.assertEquals(listOf("Sleep now"), notification.actions.map { it.title.toString() })
        Assert.assertNotEquals(notification.contentIntent, notification.actions.single().actionIntent)
        Assert.assertEquals(0, notification.flags and Notification.FLAG_ONGOING_EVENT)
    }
}

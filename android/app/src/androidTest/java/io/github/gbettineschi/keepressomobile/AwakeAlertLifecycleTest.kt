package io.github.gbettineschi.keepressomobile

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import io.github.gbettineschi.keepressomobile.core.*
import java.time.Instant
import java.util.UUID
import kotlinx.serialization.json.*
import org.junit.*
import org.junit.rules.RuleChain

class AwakeAlertLifecycleTest {
    @get:Rule val rules = RuleChain.outerRule(EmulatorOnlyRule()).around(GrantPermissionRule.grant(Manifest.permission.POST_NOTIFICATIONS))
    private val c get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val manager get() = c.getSystemService(NotificationManager::class.java)
    private val mac = Credential(UUID.randomUUID().toString(), UUID.randomUUID().toString(), "Fixture", ByteArray(32) { 7 })
    private val incident = UUID.randomUUID().toString()
    private val time = Instant.now().truncatedTo(java.time.temporal.ChronoUnit.SECONDS)
    @Before fun setup() { ReminderDelivery.replace(c, mac) }
    @After fun cleanup() { ReminderDelivery.reset(c); manager.cancelAll() }
    private fun cards() = manager.activeNotifications.filter { it.tag?.startsWith("keepresso.lid.${mac.macId}.") == true }
    private fun waitFor(condition: () -> Boolean) {
        val end = SystemClock.elapsedRealtime() + 3_000
        while (!condition() && SystemClock.elapsedRealtime() < end) SystemClock.sleep(30)
        Assert.assertTrue("Expected activity card state", condition())
    }
    private fun post(context: String = "screen_off", age: Long = 0, phase: String = "active"): String {
        val id = UUID.randomUUID().toString()
        val event = buildJsonObject {
            put("id", id); put("kind", "lid_awake"); put("incidentId", incident); put("alertPhase", phase)
            put("createdAt", time.plusSeconds(age).toString()); put("awakeContext", context)
            put("title", if (context == "screen_off") "Your Mac is running with the screen off" else "Your Mac is running with the lid closed")
            put("body", "Kept awake by an Automatic session.")
        }
        ReminderDelivery.post(c, mac, event, Instant.now())
        return id
    }
    private fun expireStored() {
        val store = CredentialStore(c)
        val record = obj(requireNotNull(store.readPrivate(LID_INCIDENT_KEY)))
        store.writePrivate(LID_INCIDENT_KEY, JsonObject(record + ("phoneExpiresAtElapsed" to JsonPrimitive(SystemClock.elapsedRealtime() - 1))).toString())
        LidAlert.clearTimer()
        LidAlert.restore(c)
    }
    private fun snapshot(context: String, wake: String = "full") = buildJsonObject {
        put("capturedAt", time.plusSeconds(2).toString())
        put("mac", buildJsonObject { put("lid", "open"); put("display", "off"); put("wakeState", wake); put("awakeContext", context) })
    }

    @Test fun sameCardBecomesQuietDismissibleHistoryWithExistingSleepAction() {
        post()
        waitFor { cards().size == 1 }
        val before = cards().single()
        expireStored()
        waitFor { cards().singleOrNull()?.notification?.extras?.getString(Notification.EXTRA_TITLE) == "Your Mac was running with the screen off" }
        val after = cards().single()
        Assert.assertEquals(before.key, after.key)
        Assert.assertEquals(0, after.notification.flags and Notification.FLAG_ONGOING_EVENT)
        Assert.assertNotEquals(0, after.notification.flags and Notification.FLAG_ONLY_ALERT_ONCE)
        Assert.assertTrue(after.notification.timeoutAfter.let { it == 0L || it >= 86_400_000L })
        Assert.assertTrue(after.notification.extras.getString(Notification.EXTRA_TEXT)!!.startsWith("Last confirmed at "))
        Assert.assertNotNull(after.notification.deleteIntent)
        Assert.assertEquals(listOf("Sleep now"), after.notification.actions.map { it.title.toString() })
    }
    @Test fun agedInitialDeliveryIsSilentHistoryAndNeverAnAlarm() {
        post(age = -181)
        waitFor { cards().size == 1 }
        val card = cards().single().notification
        Assert.assertEquals("Your Mac was running with the screen off", card.extras.getString(Notification.EXTRA_TITLE))
        Assert.assertEquals(0, card.flags and Notification.FLAG_ONGOING_EVENT)
        Assert.assertNotEquals(0, card.flags and Notification.FLAG_ONLY_ALERT_ONCE)
        Assert.assertEquals(0, card.flags and Notification.FLAG_INSISTENT)
    }
    @Test fun modernUnknownOrScreenOffSnapshotDoesNotResolveAnOpenLidWarning() {
        post()
        ReminderDelivery.snapshot(c, snapshot("screen_off"))
        Assert.assertEquals(1, cards().size)
        ReminderDelivery.snapshot(c, snapshot("unknown"))
        Assert.assertEquals(1, cards().size)
        ReminderDelivery.snapshot(c, snapshot("normal"))
        waitFor { cards().isEmpty() }
        LidAlert.restore(c)
        Assert.assertTrue(cards().isEmpty())
    }
    @Test fun historicalDismissalSurvivesRestoreButFreshEvidenceCanReturnQuietly() {
        val old = post()
        expireStored()
        waitFor { cards().isNotEmpty() }
        LidAlert.dismiss(c, mac.macId, incident, old, historical = true)
        LidAlert.restore(c)
        waitFor { cards().isEmpty() }
        post(age = 1, phase = "updated")
        waitFor { (cards().singleOrNull()?.notification?.flags?.and(Notification.FLAG_ONGOING_EVENT) ?: 0) != 0 }
        Assert.assertNotEquals(0, cards().single().notification.flags and Notification.FLAG_ONLY_ALERT_ONCE)
        LidAlert.reconcile(c, mac.macId, incident, old)
        Assert.assertNotEquals(0, cards().single().notification.flags and Notification.FLAG_ONGOING_EVENT)
    }
    @Test fun darkWakeAndUnpairingPreventOldExpiryRestoration() {
        val id = post()
        ReminderDelivery.snapshot(c, snapshot("unknown", "dark"))
        waitFor { cards().isEmpty() }
        LidAlert.reconcile(c, mac.macId, incident, id)
        LidAlert.restore(c)
        Assert.assertTrue(cards().isEmpty())
        ReminderDelivery.reset(c)
        LidAlert.reconcile(c, mac.macId, incident, id)
        Assert.assertTrue(cards().isEmpty())
    }
    @Test fun delayedButNewerEvidenceCannotResurrectDismissedOrDarkWakeHistory() {
        val old = post(age = -240)
        waitFor { cards().size == 1 }
        LidAlert.dismiss(c, mac.macId, incident, old, historical = true)
        waitFor { cards().isEmpty() }
        val late = post(age = -181, phase = "updated")
        val store = CredentialStore(c)
        Assert.assertEquals(late, obj(requireNotNull(store.readPrivate(LID_INCIDENT_KEY))).string("phoneDismissedEventId"))
        LidAlert.restore(c)
        Assert.assertTrue(cards().isEmpty())
    }
    @Test fun newerButExpiredEvidenceCannotUndoDarkWakeSuppression() {
        post(age = -240)
        ReminderDelivery.snapshot(c, buildJsonObject {
            put("capturedAt", time.minusSeconds(220).toString())
            put("mac", buildJsonObject { put("wakeState", "dark") })
        })
        waitFor { cards().isEmpty() }
        post(age = -181, phase = "updated")
        val record = obj(requireNotNull(CredentialStore(c).readPrivate(LID_INCIDENT_KEY)))
        Assert.assertTrue(Instant.parse(record.string("phoneDarkWakeAt")) >= Instant.parse(record.string("createdAt")))
        LidAlert.restore(c)
        Assert.assertTrue(cards().isEmpty())
    }
    @Test fun historicalTimeUsesOffsetCorrectedPhoneObservation() {
        post()
        val observed = Instant.now().minusSeconds(181)
        val store = CredentialStore(c)
        val record = obj(requireNotNull(store.readPrivate(LID_INCIDENT_KEY)))
        store.writePrivate(LID_INCIDENT_KEY, JsonObject(record + mapOf(
            "createdAt" to JsonPrimitive(observed.plusSeconds(3600).toString()),
            "phoneObservedAt" to JsonPrimitive(observed.toString()),
        )).toString())
        expireStored()
        val formatted = android.text.format.DateFormat.getTimeFormat(c).format(java.util.Date.from(observed))
        waitFor { cards().singleOrNull()?.notification?.extras?.getString(Notification.EXTRA_TEXT) == "Last confirmed at $formatted." }
    }

}

package io.github.gbettineschi.keepressomobile

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.content.ContextWrapper
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import com.google.firebase.messaging.RemoteMessage
import io.github.gbettineschi.keepressomobile.core.RelayCodec
import io.github.gbettineschi.keepressomobile.core.string
import java.time.Instant
import java.util.UUID
import kotlinx.serialization.json.*
import org.junit.*
import org.junit.rules.RuleChain

class ThermalNotificationTest {
    @get:Rule val rules = RuleChain.outerRule(EmulatorOnlyRule())
        .around(GrantPermissionRule.grant(Manifest.permission.POST_NOTIFICATIONS))
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val manager get() = context.getSystemService(NotificationManager::class.java)
    private val mac = Credential("11111111-1111-4111-8111-111111111111",
        "22222222-2222-4222-8222-222222222222", "Fixture", ByteArray(32) { 0x42 })

    @Before fun pairFixture() {
        manager.cancelAll()
        ReminderDelivery.replace(context, mac)
        Companion.mutable.value = UiState()
    }

    @After fun clearFixture() {
        ReminderDelivery.reset(context)
        manager.cancelAll()
    }

    private fun event(severity: String?, title: String, createdAt: Instant = Instant.now(), state: String? = null) = buildJsonObject {
        put("id", UUID.randomUUID().toString())
        put("kind", "thermal")
        put("createdAt", createdAt.toString())
        put("title", title)
        put("body", "Fixture")
        severity?.let { put("thermalSeverity", it) }
        state?.let { put("thermalState", it) }
    }

    private fun post(event: JsonObject) = ReminderDelivery.post(context, mac, event, Instant.now())

    private fun push(event: JsonObject) {
        val id = event.string("id")
        val raw = buildJsonObject { put("type", "event"); put("event", event) }.toString()
        val codec = RelayCodec(mac.macId, mac.deviceId, mac.key)
        val now = Instant.now()
        val envelope = codec.seal(raw, id, id, "s2c", "event", now, now.plusSeconds(300))
        val service = RelayMessagingService()
        ContextWrapper::class.java.getDeclaredMethod("attachBaseContext", Context::class.java)
            .apply { isAccessible = true }.invoke(service, context)
        service.onMessageReceived(RemoteMessage.Builder("fixture")
            .setData(mapOf("relayEnvelope" to envelope)).build())
    }

    private fun active() = manager.activeNotifications.filter { it.notification.extras.getString("keepresso.kind") == "thermal" }
    private fun actions(notification: Notification) = notification.actions.map { it.title.toString() }

    private fun await(condition: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 5_000
        while (!condition() && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(30)
        Assert.assertTrue("Expected notification state", condition())
    }

    private fun warning(title: String) = run {
        await { active().singleOrNull()?.notification?.extras?.getString(Notification.EXTRA_TITLE) == title }
        active().single()
    }

    @Test fun seriousSnoozePersistsAndCriticalBypassesItAcrossRoutes() {
        val serious = event("serious", "Fair", state = "fair")
        post(serious)
        val first = warning("Fair")
        Assert.assertEquals(listOf("Snooze 30 min", "Open"), actions(first.notification))
        push(serious)
        Assert.assertEquals(1, Companion.state.value.activity.count { it.text == "Fair" })
        val beforeSnooze = Instant.now()
        first.notification.actions.first().actionIntent.send()
        await { active().isEmpty() }
        val until = Instant.parse(CredentialStore(context).readPrivate("seriousHeatSnoozedUntil"))
        Assert.assertTrue(until in beforeSnooze.plusSeconds(1_800)..Instant.now().plusSeconds(1_800))

        post(event("serious", "Snoozed"))
        Assert.assertFalse(Companion.state.value.activity.any { it.text == "Snoozed" })
        push(event("critical", "Critical"))
        val critical = warning("Critical")
        Assert.assertEquals(first.key, critical.key)
        Assert.assertEquals(Notifications.URGENT_CHANNEL, critical.notification.channelId)
        Assert.assertEquals(listOf("Open"), actions(critical.notification))
        Assert.assertEquals(0, critical.notification.flags and Notification.FLAG_ONLY_ALERT_ONCE)
        first.notification.actions.first().actionIntent.send()
        warning("Critical")

        post(event("critical", "Critical repeat"))
        Assert.assertEquals(critical.key, warning("Critical repeat").key)
    }

    @Test fun fairWarningPersistsWithTheGuardAndClearsWhenItReleases() {
        val now = Instant.now()
        fun snapshot(state: String, guard: Boolean, age: Long) = buildJsonObject {
            put("capturedAt", now.plusSeconds(age).toString())
            put("mac", buildJsonObject { put("thermalSeverity", state); put("thermalGuardActive", guard) })
        }
        ReminderDelivery.snapshot(context, snapshot("fair", true, 1))
        push(event("serious", "Fair", now, state = "fair"))
        warning("Fair")
        ReminderDelivery.snapshot(context, snapshot("serious", true, 2))
        post(event("serious", "Serious guard", now.plusMillis(500), state = "serious"))
        warning("Serious guard")
        ReminderDelivery.snapshot(context, snapshot("serious", false, 3))
        await { active().isEmpty() }
    }

    @Test fun laterTelemetryClearsOrDowngradesAndRejectsDelayedEvents() {
        val now = Instant.now()
        post(event("critical", "Critical", now))
        warning("Critical")
        push(event("serious", "Delayed serious", now.minusSeconds(1)))
        Assert.assertFalse(Companion.state.value.activity.any { it.text == "Delayed serious" })
        warning("Critical")

        val captured = now.plusSeconds(1)
        ReminderDelivery.snapshot(context, buildJsonObject {
            put("capturedAt", captured.toString())
            put("mac", buildJsonObject { put("thermal", "hot"); put("thermalSeverity", "serious") })
        })
        await { active().isEmpty() }
        push(event("critical", "Delayed critical", now.plusMillis(500)))
        Assert.assertFalse(Companion.state.value.activity.any { it.text == "Delayed critical" })
        post(event("serious", "Current serious", captured))
        warning("Current serious")

        ReminderDelivery.snapshot(context, buildJsonObject {
            put("capturedAt", now.plusSeconds(2).toString())
            put("mac", buildJsonObject { put("thermal", "warm"); put("thermalSeverity", "fair") })
        })
        await { active().isEmpty() }
        post(event(null, "Older Mac warning", now.plusSeconds(2)))
        Assert.assertEquals(listOf("Open"), actions(warning("Older Mac warning").notification))
    }
}

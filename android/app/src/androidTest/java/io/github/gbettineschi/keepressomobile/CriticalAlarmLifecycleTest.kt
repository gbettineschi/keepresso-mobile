package io.github.gbettineschi.keepressomobile

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.media.AudioAttributes
import android.media.AudioManager
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import io.github.gbettineschi.keepressomobile.core.*
import java.time.Instant
import java.util.UUID
import kotlinx.serialization.json.*
import org.junit.*
import org.junit.rules.RuleChain

class CriticalAlarmLifecycleTest {
    @get:Rule val rules = RuleChain.outerRule(EmulatorOnlyRule()).around(GrantPermissionRule.grant(Manifest.permission.POST_NOTIFICATIONS))
    private val c get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val manager get() = c.getSystemService(NotificationManager::class.java)
    private val mac = Credential(UUID.randomUUID().toString(), UUID.randomUUID().toString(), "Fixture", ByteArray(32) { 12 })
    private val incident = UUID.randomUUID().toString()
    private val now = Instant.now()
    @Before fun setup() { ReminderDelivery.replace(c, mac) }
    @After fun cleanup() { ReminderDelivery.reset(c); manager.cancelAll() }
    private fun cards() = manager.activeNotifications.filter { it.tag?.startsWith("keepresso.critical.${mac.macId}.") == true }
    private fun waitFor(condition: () -> Boolean) {
        val end = SystemClock.elapsedRealtime() + 3_000
        while (!condition() && SystemClock.elapsedRealtime() < end) SystemClock.sleep(30)
        Assert.assertTrue("Expected Critical alarm state", condition())
    }
    private fun post(phase: String = "active", state: String = "critical", age: Long = 0, id: String = incident) {
        ReminderDelivery.post(c, mac, buildJsonObject {
            put("id", UUID.randomUUID().toString()); put("kind", "thermal"); put("incidentId", id); put("alertPhase", phase)
            put("thermalSeverity", "critical"); put("thermalState", state)
            put("createdAt", now.plusSeconds(age).toString()); put("title", "Fixture"); put("body", "Fixture")
        }, Instant.now())
    }
    private fun edit(vararg fields: Pair<String, JsonElement>) {
        val store = CredentialStore(c)
        store.writePrivate(CRITICAL_INCIDENT_KEY, JsonObject(obj(requireNotNull(store.readPrivate(CRITICAL_INCIDENT_KEY))) + fields.toMap()).toString())
    }
    @Test fun missingReadingsKeepAlarmAndIgnoreUntilActualRecovery() {
        post(); waitFor { cards().size == 1 }
        val first = cards().single()
        Assert.assertEquals("Your Mac reported Critical heat", first.notification.extras.getString(Notification.EXTRA_TITLE))
        edit("observedAt" to JsonPrimitive(Instant.now().minusSeconds(100).toString()))
        CriticalHeatAlerts.restore(c)
        waitFor { cards().singleOrNull()?.notification?.extras?.getString(Notification.EXTRA_TITLE) == "Your Mac reported Critical heat" }
        Assert.assertEquals(first.postTime, cards().single().postTime)
        val card = cards().single().notification
        Assert.assertNotEquals(0, card.flags and Notification.FLAG_INSISTENT)
        Assert.assertNotEquals(0, card.flags and Notification.FLAG_ONGOING_EVENT)
        Assert.assertEquals(listOf("Sleep now", "Ignore for 5 minutes"), card.actions.map { it.title.toString() })
        Assert.assertTrue(card.timeoutAfter.let { it == 0L || it > 300_000 })
        post("resolved", "fair", 1)
        waitFor { cards().singleOrNull()?.notification?.extras?.getString(Notification.EXTRA_TEXT) == "Now at Fair" }
        Assert.assertEquals(0, cards().single().notification.flags and Notification.FLAG_INSISTENT)
        CriticalHeatAlerts.restore(c)
        Assert.assertEquals(CriticalAlarmStatus.RECOVERED, CriticalHeatAlerts.state.value?.status)
    }
    @Test fun standardNotificationToneUsesAlarmVolumeWithoutChangingIt() {
        val audio = c.getSystemService(AudioManager::class.java)
        val volume = audio.getStreamVolume(AudioManager.STREAM_ALARM)
        post(); waitFor { cards().size == 1 }
        val channel = manager.getNotificationChannel(cards().single().notification.channelId)
        Assert.assertEquals("critical_heat_alarm_v2", channel.id)
        Assert.assertEquals(AudioAttributes.USAGE_ALARM, channel.audioAttributes.usage)
        Assert.assertEquals(android.provider.Settings.System.DEFAULT_NOTIFICATION_URI, channel.sound)
        Assert.assertEquals(volume, audio.getStreamVolume(AudioManager.STREAM_ALARM))
    }
    @Test fun staleCriticalCanBeIgnoredButCannotBeDismissedAsRecovered() {
        post(); edit("observedAt" to JsonPrimitive(Instant.now().minusSeconds(100).toString()))
        CriticalHeatAlerts.restore(c)
        val alert = requireNotNull(CriticalHeatAlerts.state.value)
        CriticalHeatAlerts.dismiss(c, alert)
        Assert.assertNotNull(CriticalHeatAlerts.state.value)
        CriticalHeatAlerts.snooze(c, alert)
        waitFor { cards().isEmpty() }
        CriticalHeatAlerts.restore(c)
        Assert.assertNull(CriticalHeatAlerts.state.value)
    }
    @Test fun elapsedIgnoreSurvivesRollbackAndOldCallbacksCannotInterruptNewIgnore() {
        post(); CriticalHeatAlerts.snooze(c, requireNotNull(CriticalHeatAlerts.state.value))
        val store = CredentialStore(c)
        val first = obj(requireNotNull(store.readPrivate(CRITICAL_INCIDENT_KEY)))
        val token = first.string("snoozeToken")
        edit("snoozedUntil" to JsonPrimitive(Instant.now().minusSeconds(100).toString()))
        CriticalHeatAlerts.restore(c)
        Assert.assertNull(CriticalHeatAlerts.state.value)
        val after = obj(requireNotNull(store.readPrivate(CRITICAL_INCIDENT_KEY)))
        Assert.assertEquals(first["snoozeElapsed"], after["snoozeElapsed"])
        edit("snoozeToken" to JsonPrimitive("new-ignore"), "snoozeElapsed" to JsonPrimitive(SystemClock.elapsedRealtime() + 300_000))
        CriticalHeatAlerts.rearm(c, mac.macId, incident, token)
        Assert.assertNull(CriticalHeatAlerts.state.value)
        edit("snoozeElapsed" to JsonPrimitive(SystemClock.elapsedRealtime() - 1), "observedAt" to JsonPrimitive(Instant.now().minusSeconds(100).toString()))
        CriticalHeatAlerts.rearm(c, mac.macId, incident, "new-ignore")
        waitFor { (cards().singleOrNull()?.notification?.flags?.and(Notification.FLAG_INSISTENT) ?: 0) != 0 }
        post("resolved", "nominal", 1)
        CriticalHeatAlerts.rearm(c, mac.macId, incident, "new-ignore")
        Assert.assertEquals(CriticalAlarmStatus.RECOVERED, CriticalHeatAlerts.state.value?.status)
        ReminderDelivery.reset(c)
        CriticalHeatAlerts.rearm(c, mac.macId, incident, "new-ignore")
        Assert.assertNull(CriticalHeatAlerts.state.value)
    }
    @Test fun exactPermissionDenialAndRevocationUseInexactFallback() {
        val used = mutableListOf<String>()
        scheduleCriticalRearm(true, { used += "exact" }, { used += "inexact" })
        scheduleCriticalRearm(false, { used += "wrong" }, { used += "inexact" })
        scheduleCriticalRearm(true, { throw SecurityException("revoked") }, { used += "inexact" })
        Assert.assertEquals(listOf("exact", "inexact", "inexact"), used)
    }
    @Test fun previousBootIgnoreIsBoundedAndCannotExtendOnRepeatedStartup() {
        post(); CriticalHeatAlerts.snooze(c, requireNotNull(CriticalHeatAlerts.state.value))
        edit("snoozeBoot" to JsonPrimitive(-1), "snoozedUntil" to JsonPrimitive(Instant.now().plusSeconds(120).toString()))
        CriticalHeatAlerts.restore(c)
        val store = CredentialStore(c)
        val restored = obj(requireNotNull(store.readPrivate(CRITICAL_INCIDENT_KEY)))
        Assert.assertNull(CriticalHeatAlerts.state.value)
        CriticalHeatAlerts.restore(c)
        Assert.assertEquals(restored["snoozeElapsed"], obj(requireNotNull(store.readPrivate(CRITICAL_INCIDENT_KEY)))["snoozeElapsed"])
        edit("snoozeBoot" to JsonPrimitive(-1), "snoozedUntil" to JsonPrimitive(Instant.now().plusSeconds(3600).toString()))
        CriticalHeatAlerts.restore(c)
        waitFor { (cards().singleOrNull()?.notification?.flags?.and(Notification.FLAG_INSISTENT) ?: 0) != 0 }
    }
    @Test fun newIncidentRetiresOldSnoozeAndExplicitChannelChoiceIsPreserved() {
        post(); CriticalHeatAlerts.snooze(c, requireNotNull(CriticalHeatAlerts.state.value))
        val token = obj(requireNotNull(CredentialStore(c).readPrivate(CRITICAL_INCIDENT_KEY))).string("snoozeToken")
        val next = UUID.randomUUID().toString()
        post(age = 1, id = next)
        CriticalHeatAlerts.rearm(c, mac.macId, incident, token)
        Assert.assertEquals(next, CriticalHeatAlerts.state.value?.incidentId)
        val channel = manager.getNotificationChannel(CriticalWarningSound.CHANNEL)
        val sound = channel.sound
        CriticalWarningSound.ensure(c)
        Assert.assertEquals(sound, manager.getNotificationChannel(CriticalWarningSound.CHANNEL).sound)
    }
    @Test fun channelMigrationHonorsPreviousBlockAndSilentSound() {
        val blocked = android.app.NotificationChannel("old-blocked", "Blocked", NotificationManager.IMPORTANCE_NONE)
        val silent = android.app.NotificationChannel("old-silent", "Silent", NotificationManager.IMPORTANCE_HIGH).apply { setSound(null, null); enableVibration(false) }
        Assert.assertEquals(NotificationManager.IMPORTANCE_NONE, CriticalWarningSound.newChannel(c, blocked, false).importance)
        Assert.assertNull(CriticalWarningSound.newChannel(c, silent, false).sound)
        Assert.assertFalse(CriticalWarningSound.newChannel(c, silent, false).shouldVibrate())
    }
    @Test fun invalidationHoldsBothAlertLocksUntilCredentialsAreGone() {
        post()
        val started = java.util.concurrent.CountDownLatch(2)
        val finished = java.util.concurrent.CountDownLatch(2)
        val executor = java.util.concurrent.Executors.newFixedThreadPool(2)
        try {
            CriticalHeatAlerts.invalidatePairing(c, mac.macId) {
                listOf<() -> Unit>({ CriticalHeatAlerts.restore(c) }, { LidAlert.restore(c) }).forEach { callback ->
                    executor.execute { started.countDown(); try { callback() } finally { finished.countDown() } }
                }
                Assert.assertTrue(started.await(1, java.util.concurrent.TimeUnit.SECONDS))
                val ranTooEarly = finished.await(150, java.util.concurrent.TimeUnit.MILLISECONDS)
                CredentialStore(c).clear()
                Assert.assertFalse("Receiver callbacks must wait until pairing invalidation has completed", ranTooEarly)
            }
            Assert.assertTrue(finished.await(3, java.util.concurrent.TimeUnit.SECONDS))
            waitFor { cards().isEmpty() }
            Assert.assertNull(CriticalHeatAlerts.state.value)
        } finally { executor.shutdownNow() }
    }

    @Test fun androidStillOwnsTheActualSoundAfterFreshnessExpires() {
        fun soundOwner(): String {
            val descriptor = InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand("dumpsys notification --noredact")
            return android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).bufferedReader().use { input ->
                input.lineSequence().firstOrNull { it.contains("mSoundNotificationKey=") }.orEmpty()
            }
        }
        post()
        waitFor { soundOwner().contains(mac.macId) }
        edit("observedAt" to JsonPrimitive(Instant.now().minusSeconds(100).toString()))
        CriticalHeatAlerts.restore(c)
        waitFor { cards().singleOrNull()?.notification?.extras?.getString(Notification.EXTRA_TITLE) == "Your Mac reported Critical heat" }
        SystemClock.sleep(100) // Let NotificationAttentionHelper apply the update, not just enqueue it.
        Assert.assertTrue("A posted INSISTENT flag alone does not prove Android is still playing the warning", soundOwner().contains(mac.macId))
    }

}

package io.github.gbettineschi.keepressomobile

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.github.gbettineschi.keepressomobile.core.CriticalAlarmStatus
import java.time.Instant

internal object AlertNotifications {
    private const val LID_CHANNEL = "lid_awake_status_v1"
    private const val STATUS_CHANNEL = "critical_heat_status_v1"
    private const val ALERT_ID = 3

    private fun canNotify(c: Context) = Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(c, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun manager(c: Context) = c.getSystemService(NotificationManager::class.java)
    private fun lidTag(mac: String, incident: String) = "keepresso.lid.$mac.$incident"
    private fun criticalTag(mac: String, incident: String) = "keepresso.critical.$mac.$incident"
    private fun unattendedTag(mac: String, event: String) = "keepresso.unattended.$mac.$event"

    private fun intent(c: Context, action: String, mac: String, key: String): PendingIntent {
        val launch = Intent(c, MacAlertActivity::class.java).setAction(action)
            .setData(Uri.fromParts("keepresso-alert", "$mac/$key", null))
            .putExtra("macId", mac).putExtra("incidentId", key)
        return PendingIntent.getActivity(c, 0, launch, PendingIntent.FLAG_IMMUTABLE)
    }

    private fun builder(c: Context, channel: String, title: String, body: String) =
        NotificationCompat.Builder(c, channel)
            .setSmallIcon(R.drawable.keepresso_menu_brewing)
            .setContentTitle(title.take(120)).setContentText(body.take(1000))
            .setStyle(NotificationCompat.BigTextStyle().bigText(body.take(1000)))
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)

    private fun dashboard(c: Context, key: String) = PendingIntent.getActivity(
        c, key.hashCode(), Intent(c, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE,
    )

    fun lid(c: Context, mac: String, incident: String, title: String, body: String, observed: Instant, silent: Boolean, validForMillis: Long, eventId: String, historical: Boolean = false) {
        if (!canNotify(c)) return
        val manager = manager(c)
        manager.createNotificationChannel(NotificationChannel(LID_CHANNEL, "Mac running without a visible screen", NotificationManager.IMPORTANCE_DEFAULT))
        val tag = lidTag(mac, incident)
        val sleep = intent(c, MacAlertActivity.ACTION_SLEEP, mac, incident)
        val notification = builder(c, LID_CHANNEL, title, body).setOngoing(!historical).setAutoCancel(historical).setShowWhen(true).setWhen(observed.toEpochMilli())
            .setTimeoutAfter(if (historical) 0 else validForMillis)
            .setSilent(silent || historical).setOnlyAlertOnce(silent || historical)
            .setContentIntent(if (historical) AwakeAlertReceiver.openHistory(c, mac, incident, eventId) else dashboard(c, incident))
            .setDeleteIntent(AwakeAlertReceiver.deleteIntent(c, mac, incident, eventId, historical))
            .addAction(0, "Sleep now", sleep)
        manager.notify(tag, ALERT_ID, notification.build())
    }

    fun unattended(c: Context, mac: String, event: String, title: String, body: String) {
        if (!canNotify(c)) return
        val tag = unattendedTag(mac, event)
        val sleep = intent(c, MacAlertActivity.ACTION_SLEEP, mac, event)
        val notification = builder(c, "reminders", title, body).setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_REMINDER).addAction(0, "Sleep now", sleep)
            .setContentIntent(dashboard(c, event))
        manager(c).notify(tag, ALERT_ID, notification.build())
    }

    fun hasCriticalStatus(c: Context, mac: String, incident: String) = manager(c).activeNotifications.any { it.tag == criticalTag(mac, incident) }
    fun hasCriticalAlarm(c: Context, mac: String, incident: String) = manager(c).activeNotifications.any {
        it.tag == criticalTag(mac, incident) && it.notification.channelId == CriticalWarningSound.CHANNEL && it.notification.flags and Notification.FLAG_INSISTENT != 0
    }

    fun critical(c: Context, alert: CriticalAlert, ring: Boolean) {
        if (!canNotify(c)) return
        val manager = manager(c)
        val tag = criticalTag(alert.macId, alert.incidentId)
        val open = intent(c, MacAlertActivity.ACTION_ALARM, alert.macId, alert.incidentId)
        if (!ring) manager.createNotificationChannel(NotificationChannel(STATUS_CHANNEL, "Critical heat status", NotificationManager.IMPORTANCE_LOW))
        else CriticalWarningSound.ensure(c)
        val unresolved = alert.status == CriticalAlarmStatus.CRITICAL || alert.status == CriticalAlarmStatus.STALE
        val b = builder(c, if (ring) CriticalWarningSound.CHANNEL else STATUS_CHANNEL,
            if (ring) "Your Mac reported Critical heat" else alert.title,
            if (ring) "Last reported thermal state: Critical." else alert.body)
            .setContentIntent(open)
            .addAction(0, "Sleep now", intent(c, MacAlertActivity.ACTION_SLEEP, alert.macId, alert.incidentId))
            .setCategory(if (ring) NotificationCompat.CATEGORY_ALARM else NotificationCompat.CATEGORY_STATUS)
            .setOngoing(unresolved)
            .setPriority(if (ring) NotificationCompat.PRIORITY_MAX else NotificationCompat.PRIORITY_LOW)
        if (unresolved) b.addAction(0, "Ignore for 5 minutes",
            intent(c, MacAlertActivity.ACTION_IGNORE, alert.macId, alert.incidentId))
        if (ring) {
            // Android owns this loop across process loss. No freshness-only silent updates.
            if (Build.VERSION.SDK_INT < 34 || manager.canUseFullScreenIntent()) b.setFullScreenIntent(open, true)
        } else b.setSilent(true).setOnlyAlertOnce(true)
        manager.notify(tag, ALERT_ID, b.build().also { if (ring) it.flags = it.flags or Notification.FLAG_INSISTENT })
    }

    fun cancelLid(c: Context, mac: String, incident: String) = manager(c).cancel(lidTag(mac, incident), ALERT_ID)
    fun cancelCritical(c: Context, mac: String, incident: String) = manager(c).cancel(criticalTag(mac, incident), ALERT_ID)
    fun clear(c: Context, mac: String) {
        val manager = manager(c)
        manager.activeNotifications.filter { notification ->
            listOf("lid", "critical", "unattended").any { notification.tag?.startsWith("keepresso.$it.$mac.") == true }
        }.forEach { manager.cancel(it.tag, it.id) }
    }
}

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

    fun lid(c: Context, mac: String, incident: String, title: String, body: String, observed: Instant, silent: Boolean) {
        if (!canNotify(c)) return
        val manager = manager(c)
        manager.createNotificationChannel(NotificationChannel(LID_CHANNEL, "Lid closed while awake", NotificationManager.IMPORTANCE_DEFAULT))
        val tag = lidTag(mac, incident)
        val sleep = intent(c, MacAlertActivity.ACTION_SLEEP, mac, incident)
        val notification = builder(c, LID_CHANNEL, title, body).setOngoing(true).setShowWhen(true).setWhen(observed.toEpochMilli())
            .setSilent(silent).setOnlyAlertOnce(silent).setContentIntent(dashboard(c, incident))
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

    fun critical(c: Context, alert: CriticalAlert, ring: Boolean) {
        if (!canNotify(c)) return
        val manager = manager(c)
        val tag = criticalTag(alert.macId, alert.incidentId)
        val open = intent(c, MacAlertActivity.ACTION_ALARM, alert.macId, alert.incidentId)
        if (!ring) manager.createNotificationChannel(NotificationChannel(STATUS_CHANNEL, "Critical heat status", NotificationManager.IMPORTANCE_LOW))
        else Notifications.channels(c)
        val b = builder(c, if (ring) Notifications.URGENT_CHANNEL else STATUS_CHANNEL, alert.title, alert.body)
            .setContentIntent(open)
            .addAction(0, "Sleep now", intent(c, MacAlertActivity.ACTION_SLEEP, alert.macId, alert.incidentId))
            .setCategory(if (ring) NotificationCompat.CATEGORY_ALARM else NotificationCompat.CATEGORY_STATUS)
            .setOngoing(alert.status == CriticalAlarmStatus.CRITICAL)
            .setPriority(if (ring) NotificationCompat.PRIORITY_MAX else NotificationCompat.PRIORITY_LOW)
        if (alert.status == CriticalAlarmStatus.CRITICAL) b.addAction(0, "Ignore for 5 minutes",
            intent(c, MacAlertActivity.ACTION_IGNORE, alert.macId, alert.incidentId))
        if (ring) {
            // NotificationManager owns looping and the cap also applies if the process is killed.
            b.setTimeoutAfter(5 * 60_000L)
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

package io.github.gbettineschi.keepressomobile

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.media.AudioAttributes
import android.provider.Settings
import androidx.core.app.NotificationCompat

internal object CriticalWarningSound {
    const val CHANNEL = "critical_heat_alarm_v2"
    fun ensure(c: Context) {
        val manager = c.getSystemService(NotificationManager::class.java)
        // Returning an existing channel preserves explicit sound, importance and DND choices.
        if (manager.getNotificationChannel(CHANNEL) != null) return
        manager.createNotificationChannel(newChannel(c, manager.getNotificationChannel(Notifications.URGENT_CHANNEL), manager.isNotificationPolicyAccessGranted))
    }
    internal fun newChannel(c: Context, previous: NotificationChannel?, policyAccess: Boolean): NotificationChannel {
        return NotificationChannel(CHANNEL, "Critical Mac heat alarm", (previous?.importance ?: NotificationManager.IMPORTANCE_HIGH)).apply {
            description = "Critical heat until confirmed recovery or Ignore for 5 minutes"
            setSound(if (previous != null && previous.sound == null) null else Settings.System.DEFAULT_NOTIFICATION_URI,
                AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
            vibrationPattern = longArrayOf(0, 180, 120, 180); enableVibration(previous?.shouldVibrate() ?: true)
            if (policyAccess && previous?.canBypassDnd() == true) setBypassDnd(true)
        }
    }
    fun preview(c: Context) {
        ensure(c)
        // One pattern, no unresolved incident and no FLAG_INSISTENT/full-screen intent.
        c.getSystemService(NotificationManager::class.java).notify(42002, NotificationCompat.Builder(c, CHANNEL)
            .setSmallIcon(R.drawable.keepresso_menu_brewing).setContentTitle("Keepresso warning sound")
            .setContentText("One standard notification sound.").setAutoCancel(true).setTimeoutAfter(5_000).build())
    }
}

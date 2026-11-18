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
        val channel = NotificationChannel(CHANNEL, "Critical Mac heat alarm", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Critical heat until confirmed recovery or Ignore for 5 minutes"
            setSound(Settings.System.DEFAULT_NOTIFICATION_URI,
                AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
            enableVibration(true); vibrationPattern = longArrayOf(0, 180, 120, 180)
            if (manager.isNotificationPolicyAccessGranted && manager.getNotificationChannel(Notifications.URGENT_CHANNEL)?.canBypassDnd() == true)
                setBypassDnd(true)
        }
        manager.createNotificationChannel(channel)
    }
    fun preview(c: Context) {
        ensure(c)
        // One pattern, no unresolved incident and no FLAG_INSISTENT/full-screen intent.
        c.getSystemService(NotificationManager::class.java).notify(42002, NotificationCompat.Builder(c, CHANNEL)
            .setSmallIcon(R.drawable.keepresso_menu_brewing).setContentTitle("Keepresso warning sound")
            .setContentText("One standard notification sound.").setAutoCancel(true).setTimeoutAfter(5_000).build())
    }
}

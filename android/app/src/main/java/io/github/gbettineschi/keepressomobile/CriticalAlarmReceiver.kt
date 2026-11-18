package io.github.gbettineschi.keepressomobile

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.util.Log

internal fun scheduleCriticalRearm(exactAllowed: Boolean, exact: () -> Unit, inexact: () -> Unit) {
    if (exactAllowed) try { exact(); return } catch (_: SecurityException) { /* Special access can be revoked concurrently. */ }
    inexact()
}

/** The callback contains identifiers only; saved pairing and current Ignore version authorize it. */
class CriticalAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        runCatching {
            when (intent.action) {
                Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED,
                AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED -> CriticalHeatAlerts.restore(context)
                REARM -> CriticalHeatAlerts.rearm(context, intent.getStringExtra("macId") ?: return,
                    intent.getStringExtra("incidentId") ?: return, intent.getStringExtra("snoozeToken") ?: return)
            }
        }.onFailure { Log.w("KeepressoAlerts", "Saved Critical alarm could not be reconciled", it) }
    }
    companion object {
        private const val REARM = "io.github.gbettineschi.keepressomobile.REARM_CRITICAL"
        fun exactAllowed(c: Context) = Build.VERSION.SDK_INT < 31 || c.getSystemService(AlarmManager::class.java).canScheduleExactAlarms()
        private fun intent(c: Context, mac: String, incident: String, token: String) =
            Intent(c, CriticalAlarmReceiver::class.java).setAction(REARM)
                .setData(Uri.fromParts("keepresso-critical", "$mac/$incident/$token", null))
                .putExtra("macId", mac).putExtra("incidentId", incident).putExtra("snoozeToken", token)
        fun schedule(c: Context, mac: String, incident: String, token: String, deadline: Long) {
            val manager = c.getSystemService(AlarmManager::class.java)
            val pi = PendingIntent.getBroadcast(c, 0, intent(c, mac, incident, token), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            scheduleCriticalRearm(exactAllowed(c),
                { manager.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, deadline, pi) },
                { manager.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, deadline, pi) })
        }
        fun cancel(c: Context, mac: String, incident: String, token: String?) {
            if (token == null) return
            val pi = PendingIntent.getBroadcast(c, 0, intent(c, mac, incident, token), PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE) ?: return
            c.getSystemService(AlarmManager::class.java).cancel(pi); pi.cancel()
        }
    }
}

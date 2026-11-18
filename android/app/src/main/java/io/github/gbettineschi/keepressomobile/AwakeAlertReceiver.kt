package io.github.gbettineschi.keepressomobile

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log

/** Only reconciles saved authenticated evidence; cannot send a Mac command. */
class AwakeAlertReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        runCatching {
            if (intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
                LidAlert.restore(context)
                return@runCatching
            }
            val mac = intent.getStringExtra("macId") ?: return
            val incident = intent.getStringExtra("incidentId") ?: return
            val event = intent.getStringExtra("eventId") ?: return
            when (intent.action) {
                EXPIRE -> LidAlert.reconcile(context, mac, incident, event)
                DISMISS_LIVE -> LidAlert.dismiss(context, mac, incident, event, historical = false)
                DISMISS_HISTORY -> LidAlert.dismiss(context, mac, incident, event, historical = true)
            }
        }.onFailure { Log.w("KeepressoAlerts", "Saved activity warning could not be reconciled", it) }
    }

    companion object {
        private const val EXPIRE = "io.github.gbettineschi.keepressomobile.EXPIRE_AWAKE"
        private const val DISMISS_LIVE = "io.github.gbettineschi.keepressomobile.DISMISS_AWAKE_LIVE"
        private const val DISMISS_HISTORY = "io.github.gbettineschi.keepressomobile.DISMISS_AWAKE_HISTORY"
        const val OPEN_HISTORY = "io.github.gbettineschi.keepressomobile.OPEN_AWAKE_HISTORY"

        private fun intent(c: Context, action: String, mac: String, incident: String, event: String) =
            Intent(c, AwakeAlertReceiver::class.java).setAction(action)
                .setData(Uri.fromParts("keepresso-awake", "$mac/$incident/$event", null))
                .putExtra("macId", mac).putExtra("incidentId", incident).putExtra("eventId", event)

        fun schedule(c: Context, mac: String, incident: String, event: String, deadline: Long) {
            val pending = PendingIntent.getBroadcast(c, 0, intent(c, EXPIRE, mac, incident, event), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            c.getSystemService(AlarmManager::class.java).setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, deadline, pending)
        }
        fun cancel(c: Context, mac: String, incident: String, event: String) {
            val pending = PendingIntent.getBroadcast(c, 0, intent(c, EXPIRE, mac, incident, event), PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE) ?: return
            c.getSystemService(AlarmManager::class.java).cancel(pending)
            pending.cancel()
        }
        fun deleteIntent(c: Context, mac: String, incident: String, event: String, historical: Boolean): PendingIntent =
            PendingIntent.getBroadcast(c, 0, intent(c, if (historical) DISMISS_HISTORY else DISMISS_LIVE, mac, incident, event), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        fun openHistory(c: Context, mac: String, incident: String, event: String): PendingIntent = PendingIntent.getActivity(
            c, 0, Intent(c, MainActivity::class.java).setAction(OPEN_HISTORY)
                .setData(Uri.fromParts("keepresso-awake-history", "$mac/$incident/$event", null))
                .putExtra("macId", mac).putExtra("incidentId", incident).putExtra("eventId", event),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}

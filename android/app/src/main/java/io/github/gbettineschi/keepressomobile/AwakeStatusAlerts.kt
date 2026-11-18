package io.github.gbettineschi.keepressomobile

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import io.github.gbettineschi.keepressomobile.core.*
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.Date
import kotlinx.serialization.json.*

private const val RETIRED = "phoneRetiredIncidents"
private const val OBSERVED = "phoneObservedAt"
private const val HIDDEN = "phoneDarkWakeAt"
private const val DEADLINE = "phoneExpiresAtElapsed"
private const val BOOT = "phoneBootCount"
private const val DISMISSED = "phoneDismissedEventId"

/** Retains the legacy name/key so an update cannot orphan a paired phone's card. */
internal object LidAlert {
    private val handler = Handler(Looper.getMainLooper())
    private var pending: Runnable? = null

    private fun boot(c: Context) = Settings.Global.getInt(c.contentResolver, Settings.Global.BOOT_COUNT, -1)
    private fun read(store: CredentialStore) = store.readPrivate(LID_INCIDENT_KEY)?.let(::obj)
    private fun state(record: JsonObject) = AwakeCardState(
        requireNotNull(AlertIncident.fromEvent(record)), record.string("id"), AwakeWarningContext.fromEvent(record),
        Instant.parse(record.string("createdAt")), record[DEADLINE]?.jsonPrimitive?.longOrNull,
        record[BOOT]?.jsonPrimitive?.intOrNull, record.stringOrNull(DISMISSED), record.stringOrNull(HIDDEN)?.let(Instant::parse),
    )

    @Synchronized fun accept(c: Context, store: CredentialStore, macId: String, event: JsonObject, incident: AlertIncident, serverNow: Instant) {
        val stored = read(store)
        val previous = stored?.let(AlertIncident::fromEvent)
        val retired = (stored?.get(RETIRED) as? JsonArray)?.map { it.jsonPrimitive.content }.orEmpty()
        if (incident.id in retired || (previous != null && !incident.isNewerThan(previous))) return
        val hidden = stored?.stringOrNull(HIDDEN)?.let(Instant::parse)
        if (hidden != null && incident.phase != AlertPhase.RESOLVED && incident.createdAt <= hidden) return
        val retiredIds = if (previous != null && previous.id != incident.id) (retired + previous.id).takeLast(32) else retired
        val observed = Instant.now().minus(Duration.between(incident.createdAt, serverNow).coerceAtLeast(Duration.ZERO))
        val remaining = Duration.between(Instant.now(), observed.plusSeconds(180)).toMillis()
        val record = JsonObject(event + mapOf(
            RETIRED to JsonArray(retiredIds.map(::JsonPrimitive)), OBSERVED to JsonPrimitive(observed.toString()),
            DEADLINE to JsonPrimitive(SystemClock.elapsedRealtime() + remaining), BOOT to JsonPrimitive(boot(c)),
        ) + if (previous?.id == incident.id && stored?.stringOrNull(DISMISSED) != null) mapOf(DISMISSED to stored.getValue(DISMISSED)) else emptyMap())
        store.writePrivate(LID_INCIDENT_KEY, record.toString())
        if (stored != null) cancelSchedule(c, macId, stored)
        if (previous != null && previous.id != incident.id) AlertNotifications.cancelLid(c, macId, previous.id)
        publish(c, macId, record, silent = previous?.id == incident.id || incident.phase != AlertPhase.ACTIVE)
    }

    private fun publish(c: Context, macId: String, record: JsonObject, silent: Boolean) {
        clearTimer()
        cancelSchedule(c, macId, record)
        val value = state(record)
        when (value.presentation(SystemClock.elapsedRealtime(), boot(c))) {
            AwakeCardPresentation.HIDDEN -> AlertNotifications.cancelLid(c, macId, value.incident.id)
            AwakeCardPresentation.HISTORICAL -> {
                val date = Date.from(value.observedAt)
                val zone = ZoneId.systemDefault()
                val time = android.text.format.DateFormat.getTimeFormat(c).format(date)
                val whenText = if (value.observedAt.atZone(zone).toLocalDate() == LocalDate.now(zone)) time
                    else "${android.text.format.DateFormat.getMediumDateFormat(c).format(date)} $time"
                AlertNotifications.lid(c, macId, value.incident.id, value.context.historicalTitle, "Last confirmed at $whenText.",
                    value.observedAt, true, 0, value.eventId, historical = true)
            }
            AwakeCardPresentation.LIVE -> {
                val deadline = requireNotNull(value.expiresAtElapsed)
                val remaining = (deadline - SystemClock.elapsedRealtime()).coerceAtLeast(1)
                AlertNotifications.lid(c, macId, value.incident.id, record.string("title"), record.string("body"),
                    value.observedAt, silent, remaining, value.eventId)
                AwakeAlertReceiver.schedule(c, macId, value.incident.id, value.eventId, deadline)
                val context = c.applicationContext
                val task = Runnable { runCatching { reconcile(context, macId, value.incident.id, value.eventId) } }
                pending = task
                handler.postDelayed(task, remaining)
            }
        }
    }

    private fun cancelSchedule(c: Context, macId: String, record: JsonObject) {
        val incident = AlertIncident.fromEvent(record) ?: return
        AwakeAlertReceiver.cancel(c, macId, incident.id, record.string("id"))
    }

    @Synchronized fun clearTimer() { pending?.let(handler::removeCallbacks); pending = null }
    @Synchronized fun clear(c: Context, macId: String) {
        clearTimer()
        read(CredentialStore(c))?.let { cancelSchedule(c, macId, it) }
    }

    @Synchronized fun restore(c: Context, expectedEvent: String? = null) {
        val store = CredentialStore(c)
        val macId = store.load()?.macId ?: return
        val record = read(store) ?: return
        if (expectedEvent != null && record.string("id") != expectedEvent) return
        publish(c, macId, record, silent = true)
    }

    @Synchronized fun reconcile(c: Context, macId: String, incidentId: String, eventId: String) {
        val store = CredentialStore(c)
        if (store.load()?.macId != macId) return
        val record = read(store) ?: return
        if (record.string("id") != eventId || AlertIncident.fromEvent(record)?.id != incidentId) return
        publish(c, macId, record, silent = true)
    }

    @Synchronized fun dismiss(c: Context, macId: String, incidentId: String, eventId: String, historical: Boolean) {
        val store = CredentialStore(c)
        if (store.load()?.macId != macId) return
        val record = read(store) ?: return
        val value = state(record)
        if (value.eventId != eventId || value.incident.id != incidentId) return
        // Some Android versions invoke deleteIntent for OS timeout too. Only
        // a deletion before the live deadline is unambiguous live dismissal.
        if (!historical && value.presentation(SystemClock.elapsedRealtime(), boot(c)) != AwakeCardPresentation.LIVE) return
        val dismissed = JsonObject(record + (DISMISSED to JsonPrimitive(eventId)))
        store.writePrivate(LID_INCIDENT_KEY, dismissed.toString())
        publish(c, macId, dismissed, silent = true)
    }

    @Synchronized fun snapshot(c: Context, store: CredentialStore, macId: String, snapshot: JsonObject) {
        val mac = snapshot["mac"] as? JsonObject ?: return
        val record = read(store) ?: return
        val value = state(record)
        val captured = Instant.parse(snapshot.string("capturedAt"))
        if (value.incident.phase == AlertPhase.RESOLVED || captured <= value.incident.createdAt) return
        if (mac.stringOrNull("wakeState") == "dark") {
            store.writePrivate(LID_INCIDENT_KEY, JsonObject(record + (HIDDEN to JsonPrimitive(captured.toString()))).toString())
            clearTimer(); cancelSchedule(c, macId, record)
            AlertNotifications.cancelLid(c, macId, value.incident.id)
        } else if (value.context.endedBy(mac)) {
            val resolved = JsonObject(record - HIDDEN + mapOf("createdAt" to JsonPrimitive(captured.toString()), "alertPhase" to JsonPrimitive("resolved")))
            accept(c, store, macId, resolved, AlertIncident(value.incident.id, AlertPhase.RESOLVED, captured), captured)
        }
    }
}

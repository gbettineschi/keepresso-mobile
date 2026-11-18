package io.github.gbettineschi.keepressomobile

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import java.util.UUID
import io.github.gbettineschi.keepressomobile.core.*
import java.time.Duration
import java.time.Instant
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.*

internal const val LID_INCIDENT_KEY = "lidAlertIncident"
internal const val CRITICAL_INCIDENT_KEY = "criticalAlertIncident"
private const val RETIRED_INCIDENTS = "phoneRetiredIncidents"

internal data class CriticalAlert(
    val macId: String,
    val incidentId: String,
    val status: CriticalAlarmStatus,
    val recoveryState: String?,
) {
    val title: String
        get() = when (status) {
            CriticalAlarmStatus.CRITICAL -> "Your Mac is critically hot"
            CriticalAlarmStatus.STALE -> "Your Mac reported Critical heat"
            else -> "Your Mac has been critically hot"
        }
    val body: String
        get() = when {
            status == CriticalAlarmStatus.CRITICAL -> "macOS thermal state is Critical"
            recoveryState != null && recoveryState != "unknown" -> "Now at ${recoveryState.replaceFirstChar(Char::uppercase)}"
            status == CriticalAlarmStatus.STALE -> "Last reported thermal state: Critical."
            else -> "Current thermal state unknown"
        }
}

/** Persist authenticated evidence and snooze state; schedule sound only on a new incident or a consumed snooze. */
internal object CriticalHeatAlerts {
    private val handler = Handler(Looper.getMainLooper())
    private var pending: Runnable? = null
    private val current = MutableStateFlow<CriticalAlert?>(null)
    val state = current.asStateFlow()

    private data class Record(
        val alarm: CriticalAlarmState, val dismissed: Boolean = false, val retired: List<String> = emptyList(),
        val snoozeElapsed: Long? = null, val snoozeBoot: Int? = null, val snoozeToken: String? = null,
    ) {
        fun encode(): String = buildJsonObject {
            put("kind", "thermal")
            put("thermalSeverity", "critical")
            put("incidentId", alarm.incident.id)
            put("alertPhase", alarm.incident.phase.name.lowercase())
            put("createdAt", alarm.incident.createdAt.toString())
            put("observedAt", alarm.observedAt.toString())
            alarm.recoveryState?.let { put("recoveryState", it) }
            alarm.snoozedUntil?.let { put("snoozedUntil", it.toString()) }
            snoozeElapsed?.let { put("snoozeElapsed", it) }
            snoozeBoot?.let { put("snoozeBoot", it) }
            snoozeToken?.let { put("snoozeToken", it) }
            put("dismissed", dismissed)
            put(RETIRED_INCIDENTS, JsonArray(retired.map(::JsonPrimitive)))
        }.toString()
    }

    private fun read(store: CredentialStore): Record? = store.readPrivate(CRITICAL_INCIDENT_KEY)?.let(::obj)?.let {
        Record(CriticalAlarmState(
            // Saved records predate thermalState on wire recoveries and use recoveryState instead.
            AlertIncident(canonicalId(it.string("incidentId")), AlertPhase.valueOf(it.string("alertPhase").uppercase()), Instant.parse(it.string("createdAt"))),
            Instant.parse(it.string("observedAt")),
            it.stringOrNull("recoveryState"),
            it.stringOrNull("snoozedUntil")?.let(Instant::parse),
        ), it.boolOrNull("dismissed") == true, (it[RETIRED_INCIDENTS] as? JsonArray)?.map { id -> id.jsonPrimitive.content }.orEmpty(),
            it["snoozeElapsed"]?.jsonPrimitive?.longOrNull, it["snoozeBoot"]?.jsonPrimitive?.intOrNull, it.stringOrNull("snoozeToken"))
    }

    @Synchronized fun accept(c: Context, store: CredentialStore, macId: String, event: JsonObject, incident: AlertIncident, serverNow: Instant) {
        val previous = read(store)
        if (incident.id in previous?.retired.orEmpty()) return
        if (previous != null && !incident.isNewerThan(previous.alarm.incident)) return
        val same = previous?.alarm?.incident?.id == incident.id
        val resolved = incident.phase == AlertPhase.RESOLVED
        val observed = Instant.now().minus(Duration.between(incident.createdAt, serverNow).coerceAtLeast(Duration.ZERO))
        val record = Record(
            CriticalAlarmState(
                incident, observed,
                if (resolved) event.stringOrNull("thermalState") ?: "unknown" else null,
                if (same && !resolved) previous?.alarm?.snoozedUntil else null,
            ),
            dismissed = (same && previous?.dismissed == true) || (resolved && !same),
            retired = if (!same && previous != null) (previous.retired + previous.alarm.incident.id).takeLast(32) else previous?.retired.orEmpty(),
            snoozeElapsed = if (same && !resolved) previous?.snoozeElapsed else null,
            snoozeBoot = if (same && !resolved) previous?.snoozeBoot else null,
            snoozeToken = if (same && !resolved) previous?.snoozeToken else null,
        )
        store.writePrivate(CRITICAL_INCIDENT_KEY, record.encode())
        previous?.let { cancelSchedule(c, macId, it) }
        if (!same && previous != null) AlertNotifications.cancelCritical(c, macId, previous.alarm.incident.id)
        publish(c, store, macId, record)
    }

    @Synchronized fun snapshot(c: Context, store: CredentialStore, macId: String, snapshot: JsonObject) {
        val previous = read(store) ?: return
        val mac = snapshot["mac"] as? JsonObject ?: return
        if (mac.stringOrNull("wakeState") != "full") return
        val thermal = mac.stringOrNull("thermalSeverity") ?: return
        val captured = Instant.parse(snapshot.string("capturedAt"))
        if (thermal !in setOf("nominal", "fair", "serious") || captured <= previous.alarm.incident.createdAt || previous.alarm.recoveryState != null) return
        val record = previous.copy(alarm = previous.alarm.copy(
            incident = previous.alarm.incident.copy(createdAt = captured, phase = AlertPhase.RESOLVED),
            recoveryState = thermal, snoozedUntil = null,
        ), snoozeElapsed = null, snoozeBoot = null, snoozeToken = null)
        store.writePrivate(CRITICAL_INCIDENT_KEY, record.encode())
        cancelSchedule(c, macId, previous)
        publish(c, store, macId, record)
    }

    @Synchronized fun restore(c: Context) {
        val store = CredentialStore(c)
        val macId = store.load()?.macId ?: return
        read(store)?.let { publish(c, store, macId, it) }
    }

    @Synchronized fun snooze(c: Context, alert: CriticalAlert) {
        val store = CredentialStore(c)
        if (store.load()?.macId != alert.macId) return
        val previous = read(store) ?: return
        val now = Instant.now()
        if (previous.alarm.incident.id != alert.incidentId || !previous.alarm.needsAttention(now)) return
        val record = previous.copy(alarm = previous.alarm.copy(snoozedUntil = now.plusSeconds(300)),
            snoozeElapsed = SystemClock.elapsedRealtime() + 300_000, snoozeBoot = boot(c), snoozeToken = UUID.randomUUID().toString())
        store.writePrivate(CRITICAL_INCIDENT_KEY, record.encode())
        cancelSchedule(c, alert.macId, previous)
        publish(c, store, alert.macId, record)
    }

    @Synchronized fun dismiss(c: Context, alert: CriticalAlert) {
        val store = CredentialStore(c)
        if (store.load()?.macId != alert.macId) return
        val previous = read(store) ?: return
        if (previous.alarm.incident.id != alert.incidentId || previous.alarm.status(Instant.now()) != CriticalAlarmStatus.RECOVERED) return
        val record = previous.copy(dismissed = true)
        store.writePrivate(CRITICAL_INCIDENT_KEY, record.encode())
        publish(c, store, alert.macId, record)
    }

    @Synchronized internal fun invalidatePairing(c: Context, macId: String, mutation: () -> Unit) = LidAlert.withLock {
        // Pair removal/replacement holds both alert monitors through cancellation and storage invalidation.
        clear(c, macId)
        mutation()
    }

    @Synchronized fun clear(c: Context, macId: String) {
        pending?.let(handler::removeCallbacks)
        pending = null
        current.value = null
        read(CredentialStore(c))?.let { cancelSchedule(c, macId, it) }
        LidAlert.clear(c, macId)
        AlertNotifications.clear(c, macId)
    }

    private fun boot(c: Context) = Settings.Global.getInt(c.contentResolver, Settings.Global.BOOT_COUNT, -1)
    private fun cancelSchedule(c: Context, macId: String, record: Record) =
        CriticalAlarmReceiver.cancel(c, macId, record.alarm.incident.id, record.snoozeToken)

    private fun publish(c: Context, store: CredentialStore, macId: String, saved: Record) {
        pending?.let(handler::removeCallbacks); pending = null
        val context = c.applicationContext
        val now = Instant.now()
        val elapsed = SystemClock.elapsedRealtime()
        val currentBoot = boot(c)
        var record = saved
        saved.alarm.snoozedUntil?.let { until ->
            val remaining = CriticalSnoozeDeadline(until, saved.snoozeElapsed, saved.snoozeBoot).remainingMillis(now, elapsed, currentBoot)
            record = if (remaining == 0L) saved.copy(alarm = saved.alarm.copy(snoozedUntil = null),
                snoozeElapsed = null, snoozeBoot = null, snoozeToken = null)
            else saved.copy(alarm = saved.alarm.copy(snoozedUntil = now.plusMillis(remaining)),
                snoozeElapsed = elapsed + remaining, snoozeBoot = currentBoot, snoozeToken = saved.snoozeToken ?: UUID.randomUUID().toString())
        }
        if (record != saved) store.writePrivate(CRITICAL_INCIDENT_KEY, record.encode())
        cancelSchedule(c, macId, saved)
        val alarm = record.alarm
        val incidentId = alarm.incident.id
        val status = alarm.status(now)
        val view = if (!record.dismissed && status != CriticalAlarmStatus.SNOOZED)
            CriticalAlert(macId, incidentId, status, alarm.recoveryState) else null
        val before = current.value
        current.value = view
        if (view == null) {
            AlertNotifications.cancelCritical(context, macId, incidentId)
        } else if (alarm.needsAttention(now)) {
            val alreadyRinging = AlertNotifications.hasCriticalAlarm(context, macId, incidentId)
            // The OS card uses timeless last-reported copy. Never replace an actual playing loop
            // for freshness alone: ONLY_ALERT_ONCE updates can stop sound on some Android versions.
            if (!alreadyRinging) AlertNotifications.critical(context, view, ring = true)
        } else if (before != view || !AlertNotifications.hasCriticalStatus(context, macId, incidentId)) {
            AlertNotifications.cancelCritical(context, macId, incidentId)
            AlertNotifications.critical(context, view, ring = false)
        }

        if (!record.dismissed && alarm.recoveryState == null) {
            val until = alarm.snoozedUntil
            if (until != null) CriticalAlarmReceiver.schedule(context, macId, incidentId, requireNotNull(record.snoozeToken), requireNotNull(record.snoozeElapsed))
            val next = listOfNotNull(alarm.freshUntil, until).filter { it > now }.minOrNull()
            if (next != null) {
                val task = Runnable {
                    runCatching { refresh(context, macId, incidentId) }.onFailure {
                        Log.w("KeepressoAlerts", "Critical evidence refresh failed; retaining the warning", it)
                    }
                }
                pending = task
                handler.postDelayed(task, Duration.between(now, next).toMillis().coerceAtLeast(1))
            }
        }
    }

    @Synchronized fun rearm(c: Context, macId: String, incidentId: String, snoozeToken: String) {
        val store = CredentialStore(c)
        if (store.load()?.macId != macId) return
        val record = read(store) ?: return
        if (record.alarm.incident.id != incidentId || record.snoozeToken != snoozeToken) return
        publish(c, store, macId, record)
    }

    @Synchronized private fun refresh(c: Context, macId: String, incidentId: String) {
        val store = CredentialStore(c)
        if (store.load()?.macId != macId) return
        val record = read(store) ?: return
        if (record.alarm.incident.id == incidentId) publish(c, store, macId, record)
    }
}

package io.github.gbettineschi.keepressomobile

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.github.gbettineschi.keepressomobile.core.*
import java.time.Duration
import java.time.Instant
import java.util.Date
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.*

internal const val LID_INCIDENT_KEY = "lidAlertIncident"
internal const val CRITICAL_INCIDENT_KEY = "criticalAlertIncident"
private const val RETIRED_INCIDENTS = "phoneRetiredIncidents"
private const val OBSERVED_AT = "phoneObservedAt"
private const val LID_HIDDEN_AT = "phoneDarkWakeAt"

internal object LidAlert {
    private val handler = Handler(Looper.getMainLooper())
    private var pending: Runnable? = null

    @Synchronized fun accept(c: Context, store: CredentialStore, macId: String, event: JsonObject, incident: AlertIncident, serverNow: Instant) {
        val stored = store.readPrivate(LID_INCIDENT_KEY)?.let(::obj)
        val previous = stored?.let(AlertIncident::fromEvent)
        val retired = (stored?.get(RETIRED_INCIDENTS) as? JsonArray)?.map { it.jsonPrimitive.content }.orEmpty()
        if (incident.id in retired) return
        if (previous != null && !incident.isNewerThan(previous)) return
        val hidden = stored?.stringOrNull(LID_HIDDEN_AT)?.let(Instant::parse)
        if (hidden != null && incident.phase != AlertPhase.RESOLVED && incident.createdAt <= hidden) return
        val retiredIds = if (previous != null && previous.id != incident.id) (retired + previous.id).takeLast(32) else retired
        val observed = Instant.now().minus(Duration.between(incident.createdAt, serverNow).coerceAtLeast(Duration.ZERO))
        val record = JsonObject(event + mapOf(
            RETIRED_INCIDENTS to JsonArray(retiredIds.map(::JsonPrimitive)),
            OBSERVED_AT to JsonPrimitive(observed.toString()),
        ))
        store.writePrivate(LID_INCIDENT_KEY, record.toString())
        if (previous != null && previous.id != incident.id) AlertNotifications.cancelLid(c, macId, previous.id)
        publish(c, macId, record, incident, silent = previous?.id == incident.id || incident.phase != AlertPhase.ACTIVE)
    }

    private fun publish(c: Context, macId: String, record: JsonObject, incident: AlertIncident, silent: Boolean) {
        clearTimer()
        if (incident.phase == AlertPhase.RESOLVED) {
            AlertNotifications.cancelLid(c, macId, incident.id)
            return
        }
        val observed = record.stringOrNull(OBSERVED_AT)?.let(Instant::parse) ?: return
        val context = c.applicationContext
        val freshFor = Duration.between(Instant.now(), observed.plusSeconds(180)).toMillis()
        val body = record.string("body")
        val text = if (freshFor > 0) body else {
            val time = android.text.format.DateFormat.getTimeFormat(c).format(Date.from(observed))
            "Last confirmed at $time. $body"
        }
        AlertNotifications.lid(c, macId, incident.id, record.string("title"), text, observed, silent || freshFor <= 0)
        if (freshFor > 0) {
            val expected = record.string("id")
            val task = Runnable { runCatching { restore(context, expected) } }
            pending = task
            handler.postDelayed(task, freshFor)
        }
    }

    @Synchronized fun clearTimer() {
        pending?.let(handler::removeCallbacks)
        pending = null
    }

    @Synchronized fun restore(c: Context, expectedEvent: String? = null) {
        val store = CredentialStore(c)
        val macId = store.load()?.macId ?: return
        val record = store.readPrivate(LID_INCIDENT_KEY)?.let(::obj) ?: return
        if (expectedEvent != null && record.string("id") != expectedEvent) return
        if (record.stringOrNull(LID_HIDDEN_AT) != null) return
        val incident = AlertIncident.fromEvent(record) ?: return
        publish(c, macId, record, incident, silent = true)
    }

    @Synchronized fun snapshot(c: Context, store: CredentialStore, macId: String, snapshot: JsonObject) {
        val mac = snapshot["mac"] as? JsonObject ?: return
        val wake = mac.stringOrNull("wakeState")
        val opened = wake == "full" && mac.stringOrNull("lid") == "open"
        if (!opened && wake != "dark") return
        val previous = store.readPrivate(LID_INCIDENT_KEY)?.let(::obj) ?: return
        val incident = AlertIncident.fromEvent(previous) ?: return
        val captured = Instant.parse(snapshot.string("capturedAt"))
        if (incident.phase == AlertPhase.RESOLVED || captured <= incident.createdAt) return
        if (!opened) {
            store.writePrivate(LID_INCIDENT_KEY, JsonObject(previous + (LID_HIDDEN_AT to JsonPrimitive(captured.toString()))).toString())
            clearTimer()
            AlertNotifications.cancelLid(c, macId, incident.id)
            return
        }
        val resolved = JsonObject(previous - LID_HIDDEN_AT + mapOf("createdAt" to JsonPrimitive(captured.toString()), "alertPhase" to JsonPrimitive("resolved")))
        accept(c, store, macId, resolved, AlertIncident(incident.id, AlertPhase.RESOLVED, captured), captured)
    }
}

internal data class CriticalAlert(
    val macId: String,
    val incidentId: String,
    val status: CriticalAlarmStatus,
    val recoveryState: String?,
) {
    val title: String
        get() = if (status == CriticalAlarmStatus.CRITICAL) "Your Mac is critically hot" else "Your Mac has been critically hot"
    val body: String
        get() = when {
            status == CriticalAlarmStatus.CRITICAL -> "macOS thermal state is Critical"
            recoveryState != null && recoveryState != "unknown" -> "Now at ${recoveryState.replaceFirstChar(Char::uppercase)}"
            status == CriticalAlarmStatus.STALE -> "Last reported thermal state: Critical"
            else -> "Current thermal state unknown"
        }
}

/** Persist authenticated evidence and snooze state; schedule sound only on a new incident or a consumed snooze. */
internal object CriticalHeatAlerts {
    private val handler = Handler(Looper.getMainLooper())
    private var pending: Runnable? = null
    private val current = MutableStateFlow<CriticalAlert?>(null)
    val state = current.asStateFlow()

    private data class Record(val alarm: CriticalAlarmState, val dismissed: Boolean = false, val retired: List<String> = emptyList()) {
        fun encode(): String = buildJsonObject {
            put("kind", "thermal")
            put("thermalSeverity", "critical")
            put("incidentId", alarm.incident.id)
            put("alertPhase", alarm.incident.phase.name.lowercase())
            put("createdAt", alarm.incident.createdAt.toString())
            put("observedAt", alarm.observedAt.toString())
            alarm.recoveryState?.let { put("recoveryState", it) }
            alarm.snoozedUntil?.let { put("snoozedUntil", it.toString()) }
            put("dismissed", dismissed)
            put(RETIRED_INCIDENTS, JsonArray(retired.map(::JsonPrimitive)))
        }.toString()
    }

    private fun read(store: CredentialStore): Record? = store.readPrivate(CRITICAL_INCIDENT_KEY)?.let(::obj)?.let {
        Record(CriticalAlarmState(
            requireNotNull(AlertIncident.fromEvent(it)),
            Instant.parse(it.string("observedAt")),
            it.stringOrNull("recoveryState"),
            it.stringOrNull("snoozedUntil")?.let(Instant::parse),
        ), it.boolOrNull("dismissed") == true, (it[RETIRED_INCIDENTS] as? JsonArray)?.map { id -> id.jsonPrimitive.content }.orEmpty())
    }

    @Synchronized fun accept(c: Context, store: CredentialStore, macId: String, event: JsonObject, incident: AlertIncident, serverNow: Instant) {
        val previous = read(store)
        if (incident.id in previous?.retired.orEmpty()) return
        if (previous != null && !incident.isNewerThan(previous.alarm.incident)) return
        val same = previous?.alarm?.incident?.id == incident.id
        val resolved = incident.phase == AlertPhase.RESOLVED
        if (!same && previous != null) AlertNotifications.cancelCritical(c, macId, previous.alarm.incident.id)
        val observed = Instant.now().minus(Duration.between(incident.createdAt, serverNow).coerceAtLeast(Duration.ZERO))
        val record = Record(
            CriticalAlarmState(
                incident, observed,
                if (resolved) event.stringOrNull("thermalState") ?: "unknown" else null,
                if (same && !resolved) previous?.alarm?.snoozedUntil else null,
            ),
            dismissed = (same && previous?.dismissed == true) || (resolved && !same),
            retired = if (!same && previous != null) (previous.retired + previous.alarm.incident.id).takeLast(32) else previous?.retired.orEmpty(),
        )
        store.writePrivate(CRITICAL_INCIDENT_KEY, record.encode())
        publish(c, store, macId, record, ring = !same && !resolved)
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
        ))
        store.writePrivate(CRITICAL_INCIDENT_KEY, record.encode())
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
        if (previous.alarm.incident.id != alert.incidentId || previous.alarm.status(now) != CriticalAlarmStatus.CRITICAL) return
        val record = previous.copy(alarm = previous.alarm.copy(snoozedUntil = now.plusSeconds(300)))
        store.writePrivate(CRITICAL_INCIDENT_KEY, record.encode())
        publish(c, store, alert.macId, record)
    }

    @Synchronized fun dismiss(c: Context, alert: CriticalAlert) {
        val store = CredentialStore(c)
        if (store.load()?.macId != alert.macId) return
        val previous = read(store) ?: return
        if (previous.alarm.incident.id != alert.incidentId || previous.alarm.status(Instant.now()) !in setOf(CriticalAlarmStatus.STALE, CriticalAlarmStatus.RECOVERED)) return
        val record = previous.copy(dismissed = true)
        store.writePrivate(CRITICAL_INCIDENT_KEY, record.encode())
        publish(c, store, alert.macId, record)
    }

    @Synchronized fun clear(c: Context, macId: String) {
        pending?.let(handler::removeCallbacks)
        pending = null
        current.value = null
        LidAlert.clearTimer()
        AlertNotifications.clear(c, macId)
    }

    private fun publish(c: Context, store: CredentialStore, macId: String, record: Record, ring: Boolean = false) {
        pending?.let(handler::removeCallbacks)
        pending = null
        val context = c.applicationContext
        val now = Instant.now()
        val incidentId = record.alarm.incident.id
        val status = record.alarm.status(now)
        val rearm = !record.dismissed && record.alarm.shouldRearm(now)
        val alarm = if (rearm) record.alarm.copy(snoozedUntil = null) else record.alarm
        if (rearm) store.writePrivate(CRITICAL_INCIDENT_KEY, record.copy(alarm = alarm).encode())

        val view = if (!record.dismissed && alarm.snoozedUntil?.isAfter(now) != true)
            CriticalAlert(macId, incidentId, status, alarm.recoveryState) else null
        val before = current.value
        current.value = view
        if (view == null) {
            AlertNotifications.cancelCritical(context, macId, incidentId)
        } else if (status == CriticalAlarmStatus.CRITICAL && (ring || rearm)) {
            AlertNotifications.critical(context, view, ring = true)
        } else if (before != view) {
            if (before?.incidentId == incidentId && before.status == CriticalAlarmStatus.CRITICAL)
                AlertNotifications.cancelCritical(context, macId, incidentId)
            AlertNotifications.critical(context, view, ring = false)
        }

        if (!record.dismissed && alarm.recoveryState == null) {
            val next = listOfNotNull(alarm.freshUntil, alarm.snoozedUntil).filter { it > now }.minOrNull()
            if (next != null) {
                val expected = alarm.incident.id
                val task = Runnable {
                    runCatching { refresh(context, macId, expected) }.onFailure {
                        AlertNotifications.cancelCritical(context, macId, expected)
                    }
                }
                pending = task
                handler.postDelayed(task, Duration.between(now, next).toMillis().coerceAtLeast(1))
            }
        }
    }

    @Synchronized private fun refresh(c: Context, macId: String, incidentId: String) {
        val store = CredentialStore(c)
        if (store.load()?.macId != macId) return
        val record = read(store) ?: return
        if (record.alarm.incident.id == incidentId) publish(c, store, macId, record)
    }
}

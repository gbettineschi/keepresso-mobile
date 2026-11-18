package io.github.gbettineschi.keepressomobile.core

import java.time.Instant
import kotlinx.serialization.json.JsonObject

enum class AlertPhase { ACTIVE, UPDATED, RESOLVED }

data class AlertIncident(val id: String, val phase: AlertPhase, val createdAt: Instant) {
    fun isNewerThan(previous: AlertIncident): Boolean {
        if (id == previous.id && previous.phase == AlertPhase.RESOLVED && phase != AlertPhase.RESOLVED) return false
        return createdAt > previous.createdAt || (id == previous.id && createdAt == previous.createdAt && phase > previous.phase)
    }

    companion object {
        fun fromEvent(event: JsonObject): AlertIncident? {
            if (event.string("kind") == "lid_awake") AwakeWarningContext.fromEvent(event)
            val id = event.stringOrNull("incidentId")
            val phase = event.stringOrNull("alertPhase")
            if (id == null && phase == null) return null
            val kind = event.string("kind")
            require(kind == "lid_awake" || (kind == "thermal" && event.stringOrNull("thermalSeverity") == "critical"))
            if (kind == "thermal") event.stringOrNull("thermalState")?.let {
                require((it == "critical") != (phase == "resolved"))
            }
            if (kind == "thermal" && phase == "resolved")
                require(event.stringOrNull("thermalState") in setOf("nominal", "fair", "serious"))
            return AlertIncident(canonicalId(requireNotNull(id)), when (phase) {
                "active" -> AlertPhase.ACTIVE
                "updated" -> AlertPhase.UPDATED
                "resolved" -> AlertPhase.RESOLVED
                else -> error("Invalid incident phase")
            }, Instant.parse(event.string("createdAt")))
        }
    }
}

enum class CriticalAlarmStatus { CRITICAL, SNOOZED, STALE, RECOVERED }

data class CriticalAlarmState(
    val incident: AlertIncident,
    val observedAt: Instant,
    val recoveryState: String? = null,
    val snoozedUntil: Instant? = null,
) {
    val freshUntil: Instant get() = observedAt.plusSeconds(90)

    fun status(now: Instant): CriticalAlarmStatus = when {
        recoveryState != null -> CriticalAlarmStatus.RECOVERED
        snoozedUntil?.isAfter(now) == true -> CriticalAlarmStatus.SNOOZED
        now >= freshUntil -> CriticalAlarmStatus.STALE
        else -> CriticalAlarmStatus.CRITICAL
    }

    fun needsAttention(now: Instant): Boolean = status(now) in setOf(CriticalAlarmStatus.CRITICAL, CriticalAlarmStatus.STALE)

    fun shouldRearm(now: Instant): Boolean = snoozedUntil?.let { now >= it } == true && needsAttention(now)
}

/** Same-boot timing ignores wall-clock edits. A reboot cannot grant more than five minutes. */
data class CriticalSnoozeDeadline(val wall: Instant, val elapsed: Long?, val boot: Int?) {
    fun remainingMillis(now: Instant, nowElapsed: Long, currentBoot: Int): Long {
        if (currentBoot >= 0 && boot == currentBoot && elapsed != null)
            return (elapsed - nowElapsed).coerceIn(0, 300_000)
        val remaining = java.time.Duration.between(now, wall).toMillis()
        return if (remaining in 1..300_000) remaining else 0
    }
}

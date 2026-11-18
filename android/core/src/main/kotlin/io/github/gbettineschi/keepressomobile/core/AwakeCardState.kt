package io.github.gbettineschi.keepressomobile.core

import java.time.Instant
import kotlinx.serialization.json.JsonObject

enum class AwakeWarningContext(val wire: String, val liveTitle: String, val historicalTitle: String) {
    LID_CLOSED("lid_closed", "Your Mac is running with the lid closed", "Your Mac was running with the lid closed"),
    SCREEN_OFF("screen_off", "Your Mac is running with the screen off", "Your Mac was running with the screen off");

    fun endedBy(mac: JsonObject): Boolean = when (mac.stringOrNull("awakeContext")) {
        "normal" -> mac.stringOrNull("wakeState") == "full"
        null -> when (this) {
            LID_CLOSED -> mac.stringOrNull("lid") == "open"
            SCREEN_OFF -> mac.stringOrNull("lid") == "open" && mac.stringOrNull("display") == "on" && mac.stringOrNull("wakeState") == "full"
        }
        else -> false
    }
    companion object {
        fun fromEvent(event: JsonObject): AwakeWarningContext = when (event.stringOrNull("awakeContext")) {
            null, "lid_closed" -> LID_CLOSED
            "screen_off" -> SCREEN_OFF
            else -> error("Invalid awake context")
        }
    }
}

enum class AwakeCardPresentation { LIVE, HISTORICAL, HIDDEN }

data class AwakeCardState(
    val incident: AlertIncident,
    val eventId: String,
    val context: AwakeWarningContext,
    val observedAt: Instant,
    val expiresAtElapsed: Long?,
    val bootCount: Int?,
    val dismissedEventId: String? = null,
    val darkWakeAt: Instant? = null,
) {
    fun presentation(nowElapsed: Long, currentBoot: Int): AwakeCardPresentation = when {
        incident.phase == AlertPhase.RESOLVED || dismissedEventId == eventId -> AwakeCardPresentation.HIDDEN
        darkWakeAt != null && incident.createdAt <= darkWakeAt -> AwakeCardPresentation.HIDDEN
        currentBoot >= 0 && bootCount == currentBoot && expiresAtElapsed != null && nowElapsed < expiresAtElapsed -> AwakeCardPresentation.LIVE
        else -> AwakeCardPresentation.HISTORICAL
    }
}

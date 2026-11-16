package io.github.gbettineschi.keepressomobile.core

import java.time.Instant
import kotlinx.serialization.json.*

const val TRIGGER_CHECK_TIMEOUT_SECONDS = 25L
fun triggerCheckTimedOut(sent: Instant, now: Instant): Boolean = !now.isBefore(sent.plusSeconds(TRIGGER_CHECK_TIMEOUT_SECONDS))

/** Historical manual assessment is independent of the live telemetry capture clock.
 * Polls may seed history once and add context; only a matching explicit response replaces it.
 */
data class TriggerHistory(
    val assessment: JsonObject? = null,
    val outdated: Boolean = false,
    val checkError: String? = null,
) {
    fun telemetry(triggers: JsonObject?): TriggerHistory {
        if (triggers == null) return this
        val contextChanged = triggers.boolOrNull("outdated") == true || triggers.stringOrNull("state") == "stale"
        if (assessment != null) return copy(outdated = outdated || contextChanged)
        return copy(
            assessment = triggers.takeIf { it.isHistoricalAssessment() },
            outdated = outdated || contextChanged,
            checkError = checkError ?: triggers.stringOrNull("checkError") ?: if (triggers.stringOrNull("state") == "error") "Couldn't check triggers" else null,
        )
    }

    fun completed(triggers: JsonObject?): TriggerHistory =
        if (triggers != null && triggers.isHistoricalAssessment() && triggers.stringOrNull("state") in setOf("ready", "unknown") && triggers.boolOrNull("checking") != true)
            TriggerHistory(triggers, outdated = triggers.boolOrNull("outdated") == true)
        else failed("Couldn't check triggers")

    fun failed(message: String): TriggerHistory = copy(checkError = message)

    private fun JsonObject.isHistoricalAssessment(): Boolean =
        stringOrNull("checkedAt") != null && this["rules"] is JsonArray && stringOrNull("state") in setOf("ready", "unknown", "stale", "error")
}

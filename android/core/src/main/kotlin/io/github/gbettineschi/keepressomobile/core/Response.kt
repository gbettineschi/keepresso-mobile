package io.github.gbettineschi.keepressomobile.core
import java.time.Instant
import kotlinx.serialization.json.*

enum class SleepOutcome(val wire: String, val label: String) {
    GOING_TO_SLEEP("going_to_sleep", "Going to sleep"),
    COULD_NOT_SLEEP("could_not_sleep", "Couldn’t sleep"),
    COULD_NOT_REQUEST_SLEEP("could_not_request_sleep", "Couldn’t request sleep");
}

data class Response(val id: String, val status: String, val message: String?, val snapshot: JsonObject?, val sleepOutcome: SleepOutcome? = null) {
    fun sleepResult(): SleepOutcome = sleepOutcome ?: SleepOutcome.COULD_NOT_REQUEST_SLEEP

    companion object {
        fun parse(record: String, serverNow: Instant): Response {
            val r = obj(record); require(r.string("type") == "response")
            val id = canonicalId(r.string("id")); val status = r.string("status"); require(status in setOf("ok", "error", "uncertain"))
            val message = r.stringOrNull("message"); require(message == null || message.toByteArray().size <= 4096)
            val snapshot = r["snapshot"]?.takeUnless { it == JsonNull }?.jsonObject
            snapshot?.let { DashboardState().update(it.toString(), 0, serverNow) }
            val sleepOutcome = r.stringOrNull("sleepOutcome")?.let { wire -> requireNotNull(SleepOutcome.entries.firstOrNull { it.wire == wire }) }
            return Response(id, status, message, snapshot, sleepOutcome)
        }
    }
}

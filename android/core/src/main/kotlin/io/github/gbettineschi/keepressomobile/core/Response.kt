package io.github.gbettineschi.keepressomobile.core
import java.time.Instant
import kotlinx.serialization.json.*

data class Response(val id: String, val status: String, val message: String?, val snapshot: JsonObject?) {
    companion object {
        fun parse(record: String, serverNow: Instant): Response {
            val r = obj(record); require(r.string("type") == "response")
            val id = canonicalId(r.string("id")); val status = r.string("status"); require(status in setOf("ok", "error", "uncertain"))
            val message = r.stringOrNull("message"); require(message == null || message.toByteArray().size <= 4096)
            val snapshot = r["snapshot"]?.takeUnless { it == JsonNull }?.jsonObject
            snapshot?.let { DashboardState().update(it.toString(), 0, serverNow) }
            return Response(id, status, message, snapshot)
        }
    }
}

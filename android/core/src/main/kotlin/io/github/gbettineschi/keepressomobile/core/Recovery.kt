package io.github.gbettineschi.keepressomobile.core

import java.security.MessageDigest
import java.time.Instant
import kotlinx.serialization.json.*

fun bodyDigest(body: String): String = encode64(MessageDigest.getInstance("SHA-256").digest(body.toByteArray(Charsets.UTF_8)))
data class MutationIntent(val id: String, val body: String, val digest: String, val status: String)
/** Store must commit synchronously; a failed persistence step forbids transmission. */
class MutationJournal(private val load: () -> String?, private val save: (String) -> Unit) {
    private val entries = linkedMapOf<String, MutationIntent>()
    init {
        load()?.let { text ->
            val values = wireJson.parseToJsonElement(text).jsonArray; require(values.size <= 32)
            values.forEach { value -> val r = value.jsonObject; val id = canonicalId(r.string("id")); val body = r.string("body"); require(obj(body).string("id") == id && body.toByteArray().size <= 48000); val status = r.string("status"); require(status in setOf("reserved", "uncertain", "ok", "error")); require(!entries.containsKey(id)); entries[id] = MutationIntent(id, body, bodyDigest(body), if (status == "reserved") "uncertain" else status) }
        }
    }
    private fun persist() = save(buildJsonArray { entries.values.forEach { r -> add(buildJsonObject { put("id", r.id); put("body", r.body); put("status", r.status) }) } }.toString())
    @Synchronized fun reserve(body: String): MutationIntent {
        val r = obj(body); val id = canonicalId(r.string("id")); require(r.string("action") !in setOf("status", "refresh_triggers", "operation_status")); require(id !in entries)
        if (entries.size == 32) { val completed = entries.values.firstOrNull { it.status in setOf("ok", "error") } ?: error("Too many unresolved commands"); entries.remove(completed.id) }
        val intent = MutationIntent(id, body, bodyDigest(body), "reserved"); entries[id] = intent; persist(); return intent
    }
    @Synchronized fun transmitting(id: String) { val r = entries.getValue(id); require(r.status == "reserved"); entries[id] = r.copy(status = "uncertain"); persist() }
    @Synchronized fun reconcile(id: String, status: String) { require(status in setOf("ok", "error", "uncertain", "not_found")); val r = entries.getValue(id); entries[id] = r.copy(status = if (status == "not_found") "uncertain" else status); persist() }
    @Synchronized fun unresolved(): List<MutationIntent> = entries.values.filter { it.status in setOf("reserved", "uncertain") }
}
class RequestRoute {
    private var started = false
    fun select(nearby: Boolean, relay: Boolean, internet: Boolean = false): String { check(!started); return when { nearby -> "nearby"; internet -> "iroh"; relay -> "relay"; else -> error("Mac unreachable") } }
    fun begin() { check(!started); started = true }
}

/** Claim is durable before either BLE or FCM may post the notification. */
class EventClaims(private val load: () -> String?, private val save: (String) -> Unit) {
    @Synchronized fun claim(macId: String, event: JsonObject, now: Instant, snapshot: JsonObject?): Boolean {
        canonicalId(macId); val id = canonicalId(event.string("id")); val kind = event.string("kind")
        require(kind in setOf("hourly", "session_ended_awake", "battery", "thermal", "sleep_failed", "lid_awake", "unattended_brew"))
        val created = Instant.parse(event.string("createdAt")); require(created <= now.plusSeconds(10))
        val thermal = if (kind == "thermal") ThermalWarning.fromEvent(event) else null
        val incident = AlertIncident.fromEvent(event)
        require(event.string("title").toByteArray().size <= 480 && event.string("body").toByteArray().size <= 4096)
        val key = "$macId/$id"
        val claims = load()?.let { obj(it).mapValues { (_, v) -> v.jsonPrimitive.long } }?.filterValues { it > now.epochSecond }?.toMutableMap() ?: linkedMapOf()
        val expiresAt = created.plusSeconds(if (thermal?.level == ThermalWarningLevel.CRITICAL && incident?.phase != AlertPhase.RESOLVED) 60 else 300)
        if (now >= expiresAt || claims.containsKey(key)) return false
        if (claims.size >= 256) return false
        claims[key] = expiresAt.epochSecond
        save(buildJsonObject { claims.forEach { (k, v) -> put(k, v) } }.toString())
        if (incident?.phase == AlertPhase.RESOLVED) return true
        if (thermal != null) {
            if (snapshot == null) return true
            if (incident != null && Instant.parse(snapshot.string("capturedAt")) > created) {
                when ((snapshot["mac"] as? JsonObject)?.stringOrNull("wakeState")) {
                    "dark" -> return false
                    "full" -> return !thermal.isSupersededBy(snapshot)
                    else -> return true
                }
            }
            return !thermal.isSupersededBy(snapshot)
        }
        if (snapshot != null && Instant.parse(snapshot.string("capturedAt")) > created) {
            val k = snapshot["keepresso"] as? JsonObject; val m = snapshot["mac"] as? JsonObject
            if (kind == "hourly" && k?.boolOrNull("isActive") == false) return false
            if (kind in setOf("session_ended_awake", "sleep_failed") && k?.boolOrNull("isActive") == true) return false
            if (kind == "lid_awake" && m?.stringOrNull("lid") == "open") return false
            if (kind == "lid_awake" && m?.stringOrNull("wakeState") == "dark") return false
            if (kind == "unattended_brew" && k?.boolOrNull("isActive") == false) return false
            if (kind == "battery" && m?.get("batteryPercent")?.jsonPrimitive?.doubleOrNull?.let { it >= 30 } == true && k?.stringOrNull("safetyPause") == "none") return false
        }
        return true
    }
}

/** One body and one chosen route survive any ambiguous transport failure. */
class CommandSubmission(val body: String, nearby: Boolean, relay: Boolean, internet: Boolean = false) {
    val id = canonicalId(obj(body).string("id"))
    val action = obj(body).string("action")
    val mutation = action !in setOf("status", "refresh_triggers", "operation_status")
    val route = RequestRoute().select(nearby, relay, internet)
    private var started = false
    @Synchronized fun transmit(journal: MutationJournal, send: (String) -> Unit) {
        check(!started); started = true
        if (mutation) { journal.reserve(body); journal.transmitting(id) }
        send(body)
    }
}

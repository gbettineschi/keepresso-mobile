package io.github.gbettineschi.keepressomobile.core

import java.net.URI
import java.net.URLDecoder
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.security.SecureRandom
import java.time.Instant
import java.util.Base64
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlinx.serialization.json.*

val wireJson = Json { isLenient = false; ignoreUnknownKeys = false }
fun obj(text: String): JsonObject = wireJson.parseToJsonElement(text).jsonObject
fun JsonObject.string(key: String): String = getValue(key).jsonPrimitive.also { require(it.isString) }.content
fun JsonObject.stringOrNull(key: String): String? = this[key]?.takeUnless { it == JsonNull }?.jsonPrimitive?.also { require(it.isString) }?.content
fun JsonObject.boolOrNull(key: String): Boolean? = this[key]?.takeUnless { it == JsonNull }?.jsonPrimitive?.also { require(!it.isString) }?.booleanOrNull.also { require(this[key] == null || this[key] == JsonNull || it != null) }
fun canonicalId(value: String): String = value.also { require(UUID.fromString(it).toString() == it) }
fun decode64(value: String, size: Int? = null): ByteArray = Base64.getDecoder().decode(value).also { require(Base64.getEncoder().encodeToString(it) == value); require(size == null || it.size == size) }
fun encode64(value: ByteArray): String = Base64.getEncoder().encodeToString(value)
fun randomNonce(): String = encode64(ByteArray(32).also { SecureRandom().nextBytes(it) })

object Crypto {
    private fun hmac(key: ByteArray, bytes: ByteArray): ByteArray = Mac.getInstance("HmacSHA256").run { init(SecretKeySpec(key, "HmacSHA256")); doFinal(bytes) }
    private fun sha(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes)
    private fun derive(key: ByteArray, salt: ByteArray, info: String) = hmac(hmac(salt, key), info.toByteArray(Charsets.UTF_8) + byteArrayOf(1))
    fun deviceKey(token: ByteArray, macId: String, deviceId: String): ByteArray {
        require(token.size == 32); canonicalId(macId); canonicalId(deviceId)
        return derive(token, sha("$macId\n$deviceId".toByteArray()), "keepresso-mobile/v1/device-key")
    }
    fun proof(key: ByteArray, text: String): String = encode64(hmac(key, text.toByteArray(Charsets.UTF_8)))
    fun verify(key: ByteArray, text: String, proof: String): Boolean = MessageDigest.isEqual(decode64(Crypto.proof(key, text), 32), decode64(proof, 32))
    fun directionKey(key: ByteArray, transcript: String, direction: String): ByteArray {
        require(direction in setOf("c2s", "s2c")); require(key.size == 32)
        return derive(key, sha(transcript.toByteArray()), "keepresso-mobile/v1/$direction")
    }
    fun transcript(macId: String, deviceId: String, clientNonce: String, serverNonce: String): String {
        canonicalId(macId); canonicalId(deviceId); decode64(clientNonce, 32); decode64(serverNonce, 32)
        return "keepresso-mobile/v1\n$macId\n$deviceId\n$clientNonce\n$serverNonce"
    }
    fun pairTranscript(macId: String, deviceId: String, nonce: String, name: String): String {
        canonicalId(macId); canonicalId(deviceId); decode64(nonce, 32)
        require(name.isNotBlank() && name.toByteArray().size <= 80)
        return "keepresso-mobile/pair/v1\n$macId\n$deviceId\n$nonce\n${encode64(name.toByteArray())}"
    }
}

class SecureChannel(private val outbound: ByteArray, private val inbound: ByteArray) {
    private var send = 0L; private var receive = 0L; private var closed = false
    init { require(outbound.size == 32 && inbound.size == 32) }
    private fun crypt(mode: Int, key: ByteArray, seq: Long, bytes: ByteArray): ByteArray = Cipher.getInstance("AES/GCM/NoPadding").run {
        init(mode, SecretKeySpec(key, "AES"), GCMParameterSpec(128, ByteBuffer.allocate(12).putInt(0).putLong(seq).array()))
        updateAAD("keepresso-mobile/v1".toByteArray()); doFinal(bytes)
    }
    @Synchronized fun seal(plaintext: String): String {
        require(!closed && send <= Int.MAX_VALUE); require(plaintext.toByteArray().size <= 48000)
        val encrypted = crypt(Cipher.ENCRYPT_MODE, outbound, send, plaintext.toByteArray())
        return buildJsonObject { put("type", "sealed"); put("sequence", send); put("ciphertext", encode64(encrypted)) }.toString().also { send++ }
    }
    @Synchronized fun open(record: String): String {
        try {
            require(!closed && receive <= Int.MAX_VALUE)
            val r = obj(record); require(r.keys == setOf("type", "sequence", "ciphertext") && r.string("type") == "sealed")
            val seq = r.getValue("sequence").jsonPrimitive; require(!seq.isString && seq.longOrNull == receive)
            val bytes = decode64(r.string("ciphertext")); require(bytes.size in 16..65536)
            val plain = crypt(Cipher.DECRYPT_MODE, inbound, receive, bytes)
            val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(plain)).toString()
            obj(text); receive++; return text
        } catch (e: Exception) { closed = true; throw IllegalArgumentException("Authenticated session closed", e) }
    }
}

class Framer {
    private var buffer = ByteArray(0); private var began: Long? = null; private var failed = false
    fun feed(bytes: ByteArray, nowMillis: Long): List<String> {
        try {
            require(!failed); require(began == null || nowMillis - began!! <= 10000)
            require(buffer.size + bytes.size <= 131080)
            if (buffer.isEmpty() && bytes.isNotEmpty()) began = nowMillis
            buffer += bytes; val out = mutableListOf<String>()
            while (buffer.size >= 4) {
                val n = ByteBuffer.wrap(buffer, 0, 4).int; require(n in 1..65536)
                if (buffer.size < n + 4) break
                val decoder = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                out += decoder.decode(ByteBuffer.wrap(buffer, 4, n)).toString()
                buffer = buffer.copyOfRange(n + 4, buffer.size); began = if (buffer.isEmpty()) null else nowMillis
            }
            return out
        } catch (e: Exception) { failed = true; buffer = ByteArray(0); throw IllegalArgumentException("Invalid or expired frame", e) }
    }
    companion object { fun encode(record: String): ByteArray { val b = record.toByteArray(); require(b.size in 1..65536); return ByteBuffer.allocate(b.size + 4).putInt(b.size).put(b).array() } }
}

data class Invitation(val macId: String, val token: ByteArray, val name: String, val expires: Long) {
    companion object {
        fun parse(uri: String, nowSeconds: Long): Invitation {
            require(uri.length <= 2048); val u = URI(uri)
            require(u.scheme == "keespresso" && u.host == "pair" && u.rawFragment == null && u.rawUserInfo == null && u.port == -1 && u.path.isEmpty())
            val params = mutableMapOf<String, String>()
            u.rawQuery.split('&').forEach { val pair = it.split('=', limit = 2); require(pair.size == 2); val k = URLDecoder.decode(pair[0], "UTF-8"); require(!params.containsKey(k)); params[k] = URLDecoder.decode(pair[1], "UTF-8") }
            require(params.keys == setOf("v", "mac", "token", "expires", "name") && params["v"] == "1")
            val expires = params.getValue("expires").toLong(); require(expires > 0 && expires - nowSeconds in -300..600)
            val name = params.getValue("name"); require(name.isNotBlank() && name.toByteArray().size <= 80)
            return Invitation(canonicalId(params.getValue("mac")), decode64(params.getValue("token"), 32), name, expires)
        }
    }
}

data class ReminderSettings(val enabled: Boolean, val intervalSeconds: Int, val endedAwakeDelaySeconds: Int) {
    fun json(): JsonObject { require(intervalSeconds in setOf(3600, 7200)); require(endedAwakeDelaySeconds in setOf(120, 300, 600)); return buildJsonObject { put("enabled", enabled); put("intervalSeconds", intervalSeconds); put("endedAwakeDelaySeconds", endedAwakeDelaySeconds) } }
}
object Requests {
    val actions = setOf("status", "refresh_triggers", "start_manual", "stop_manual", "pause_triggers", "resume_triggers", "sleep_now", "snooze_reminders", "resume_reminders", "ack_reminder", "set_reminder_settings", "operation_status")
    fun create(action: String, now: Instant, durationMinutes: Int? = null, settings: ReminderSettings? = null, operationId: String? = null, digest: String? = null): String {
        val r = buildJsonObject { put("type", "request"); put("id", UUID.randomUUID().toString()); put("action", action); put("issuedAt", now.toString()); put("expiresAt", now.plusSeconds(30).toString()); durationMinutes?.let { put("durationMinutes", it) }; if (action == "snooze_reminders") put("durationSeconds", 21600); settings?.let { put("reminderSettings", it.json()) }; operationId?.let { put("operationId", it) }; digest?.let { put("bodyDigest", it) } }.toString()
        validate(r, now); return r
    }
    fun operationStatus(operationId: String, digest: String, now: Instant): String {
        canonicalId(operationId); decode64(digest, 32)
        val base = obj(create("operation_status", now, operationId = operationId, digest = digest))
        return base.toString()
    }
    fun validate(json: String, now: Instant) {
        val r = obj(json); require(r.string("type") == "request"); canonicalId(r.string("id")); val a = r.string("action"); require(a in actions)
        val issued = Instant.parse(r.string("issuedAt")); val expires = Instant.parse(r.string("expiresAt"))
        require(expires > now && expires > issued && expires <= issued.plusSeconds(30) && issued <= now.plusSeconds(10))
        if (a == "operation_status") { require(r.keys == setOf("type", "id", "action", "issuedAt", "expiresAt", "operationId", "bodyDigest")); canonicalId(r.string("operationId")); decode64(r.string("bodyDigest"), 32) }
        if (a == "start_manual") { val v = r.getValue("durationMinutes").jsonPrimitive; require(!v.isString && v.intOrNull?.let { it in 15..10080 && it % 15 == 0 } == true) }
        if (a == "snooze_reminders") require(r.getValue("durationSeconds").jsonPrimitive.intOrNull == 21600)
        if (a == "set_reminder_settings") { val s = r.getValue("reminderSettings").jsonObject; ReminderSettings(s.boolOrNull("enabled") ?: error("Missing enabled"), s.getValue("intervalSeconds").jsonPrimitive.int, s.getValue("endedAwakeDelaySeconds").jsonPrimitive.int).json() }
    }
}

class DashboardState {
    var connected: Boolean = false
    var snapshot: JsonObject? = null; private set
    private var received: Long? = null
    fun update(snapshot: String, nowMillis: Long, serverNow: Instant? = null) {

        val s = obj(snapshot); Instant.parse(s.string("capturedAt"))
        s["keepresso"]?.jsonObject?.let { k -> listOf("appRunning", "isActive", "triggersEnabled", "triggersPaused").forEach { k.boolOrNull(it) } }
        s["capabilities"]?.jsonObject?.values?.forEach { require(it is JsonPrimitive && !it.isString && it.booleanOrNull != null) }
        validateSnapshot(s)
        val ageMillis = serverNow?.let { java.time.Duration.between(Instant.parse(s.string("capturedAt")), it).toMillis() } ?: 0L
        require(ageMillis >= -10000)
        this.snapshot = s; received = nowMillis - ageMillis.coerceAtLeast(0)
    }
    fun reachable(nowMillis: Long): Boolean = connected && received?.let { nowMillis - it in 0..15000 } == true
    fun active(): Boolean? = snapshot?.get("keepresso")?.jsonObject?.boolOrNull("isActive")
}

/** Missing and null readings stay unknown; a wrong type invalidates the snapshot. */
fun validateSnapshot(s: JsonObject) {
    fun JsonObject.enums(key: String, values: Set<String>) { stringOrNull(key)?.let { require(it in values) } }
    fun JsonObject.numeric(key: String, range: ClosedFloatingPointRange<Double>? = null) {
        this[key]?.takeUnless { it == JsonNull }?.let { value -> val p = value.jsonPrimitive; require(!p.isString); val n = p.doubleOrNull; require(n != null && n.isFinite() && (range == null || n in range)) }
    }
    fun JsonObject.timestamp(key: String) { stringOrNull(key)?.let { Instant.parse(it) } }
    s.stringOrNull("macName")
    s["mac"]?.takeUnless { it == JsonNull }?.jsonObject?.let {
        it.enums("lock", setOf("locked", "unlocked", "unknown")); it.enums("display", setOf("on", "dimmed", "off", "unknown")); it.enums("lid", setOf("open", "closed", "unknown")); it.enums("powerSource", setOf("battery", "ac", "unknown")); it.enums("thermal", setOf("normal", "warm", "hot", "unknown"))
        it.numeric("batteryPercent", 0.0..100.0); it.numeric("temperatureC"); it.stringOrNull("temperatureSensor")
    }
    s["keepresso"]?.takeUnless { it == JsonNull }?.jsonObject?.let {
        listOf("appRunning", "isActive", "triggersEnabled", "triggersPaused").forEach(it::boolOrNull)
        it.enums("sessionKind", setOf("manual", "automatic", "lease", "unknown")); it.enums("safetyPause", setOf("battery", "thermal", "none", "unknown")); it.timestamp("endsAt"); it.stringOrNull("version")
    }
    s["triggers"]?.takeUnless { it == JsonNull }?.jsonObject?.let { t ->
        t.enums("state", setOf("not_checked", "checking", "ready", "unknown", "stale", "error")); t.timestamp("checkedAt"); t.boolOrNull("combined"); t.stringOrNull("message")
        t["rules"]?.takeUnless { it == JsonNull }?.jsonArray?.let { rules ->
            require(rules.size <= 128)
            rules.forEach { value -> val r = value.jsonObject; r.stringOrNull("id"); r.stringOrNull("label"); r.boolOrNull("satisfied"); r.boolOrNull("inGrace"); r.numeric("graceRemaining")
                r["details"]?.takeUnless { it == JsonNull }?.jsonArray?.let { details -> require(details.size <= 128); details.forEach { d -> d.jsonObject.let { it.stringOrNull("label"); it.boolOrNull("active"); it.stringOrNull("agent") } } }
            }
        }
    }
    s["reminders"]?.takeUnless { it == JsonNull }?.jsonObject?.let { r ->
        r.boolOrNull("enabled"); r.timestamp("snoozedUntil")
        r.numeric("intervalSeconds"); r["intervalSeconds"]?.takeUnless { it == JsonNull }?.let { require(it.jsonPrimitive.intOrNull in setOf(3600, 7200)) }
        r.numeric("endedAwakeDelaySeconds"); r["endedAwakeDelaySeconds"]?.takeUnless { it == JsonNull }?.let { require(it.jsonPrimitive.intOrNull in setOf(120, 300, 600)) }
    }
}

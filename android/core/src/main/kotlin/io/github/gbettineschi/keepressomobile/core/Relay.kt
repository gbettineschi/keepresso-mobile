package io.github.gbettineschi.keepressomobile.core

import java.net.URI
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.security.SecureRandom
import java.time.Instant
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlinx.serialization.json.*
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.MediaType.Companion.toMediaType
import okio.BufferedSink
import java.util.concurrent.TimeUnit

/** A relay URL is configuration, never a second pairing authority. */
class RelayEndpoint(base: String) {
    val url: URI
    init {
        val u = URI(base)
        require(u.scheme == "https" && !u.host.isNullOrBlank() && u.rawUserInfo == null && u.rawQuery == null && u.rawFragment == null && u.path in setOf("", "/"))
        require(u.port == -1 || u.port in 1..65535)
        url = URI(u.scheme, null, u.host, u.port, "/api/relay", null, null)
    }
}

data class OpenRelay(val id: String, val epoch: String, val kind: String, val createdAt: Instant, val expiresAt: Instant, val plaintext: String)
class RelayCodec(private val macId: String, private val deviceId: String, private val deviceKey: ByteArray) {
    init { canonicalId(macId); canonicalId(deviceId); require(deviceKey.size == 32) }
    private fun hmac(key: ByteArray, bytes: ByteArray): ByteArray = Mac.getInstance("HmacSHA256").run { init(SecretKeySpec(key, "HmacSHA256")); doFinal(bytes) }
    fun key(direction: String): ByteArray {
        require(direction in setOf("c2s", "s2c", "phone-access"))
        val salt = MessageDigest.getInstance("SHA-256").digest("$macId\n$deviceId".toByteArray(Charsets.UTF_8))
        return hmac(hmac(salt, deviceKey), "keepresso-mobile/relay/v1/$direction".toByteArray(Charsets.UTF_8) + byteArrayOf(1))
    }
    fun bearer(): String = encode64(key("phone-access"))
    private fun aad(id: String, epoch: String, direction: String, kind: String, created: Long, expires: Long): ByteArray = "keepresso-mobile/relay/v1\n$macId\n$deviceId\n$id\n$epoch\n$direction\n$kind\n$created\n$expires".toByteArray(Charsets.UTF_8)
    private fun lifetime(kind: String): Long = when (kind) { "command" -> 30; "response" -> 120; "state" -> 15; "event" -> 300; else -> error("Unknown envelope kind") }
    private fun metadata(id: String, epoch: String, direction: String, kind: String, created: Long, expires: Long) {
        canonicalId(id); canonicalId(epoch); require(direction in setOf("c2s", "s2c")); require(created > 0 && expires > created && expires - created <= lifetime(kind))
        require((direction == "c2s") == (kind == "command"))
    }
    fun seal(plaintext: String, id: String, epoch: String, direction: String, kind: String, createdAt: Instant, expiresAt: Instant, nonce: ByteArray = ByteArray(12).also { SecureRandom().nextBytes(it) }): String {
        val created = createdAt.epochSecond; val expires = expiresAt.epochSecond
        metadata(id, epoch, direction, kind, created, expires); require(nonce.size == 12 && plaintext.toByteArray().size <= 48000)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").run { init(Cipher.ENCRYPT_MODE, SecretKeySpec(key(direction), "AES"), GCMParameterSpec(128, nonce)); updateAAD(aad(id, epoch, direction, kind, created, expires)); doFinal(plaintext.toByteArray(Charsets.UTF_8)) }
        return buildJsonObject { put("version", 1); put("macId", macId); put("deviceId", deviceId); put("id", id); put("epoch", epoch); put("direction", direction); put("kind", kind); put("createdAt", created); put("expiresAt", expires); put("nonce", encode64(nonce)); put("ciphertext", encode64(cipher)) }.toString().also { require(it.toByteArray().size <= 65536) }
    }
    fun open(encoded: String, now: Instant, direction: String, kinds: Set<String>, epoch: String? = null): OpenRelay {
        require(encoded.toByteArray().size in 1..65536)
        val r = obj(encoded)
        require(r.keys == setOf("version", "macId", "deviceId", "id", "epoch", "direction", "kind", "createdAt", "expiresAt", "nonce", "ciphertext"))
        fun integer(name: String): Long { val p = r.getValue(name).jsonPrimitive; require(!p.isString); return requireNotNull(p.longOrNull) }
        require(integer("version") == 1L && r.string("macId") == macId && r.string("deviceId") == deviceId)
        val id = r.string("id"); val e = r.string("epoch"); val d = r.string("direction"); val kind = r.string("kind"); val created = integer("createdAt"); val expires = integer("expiresAt")
        metadata(id, e, d, kind, created, expires)
        require(d == direction && kind in kinds && (epoch == null || epoch == e))
        require(created <= now.epochSecond + 10 && expires > now.epochSecond)
        val nonce = decode64(r.string("nonce"), 12); val ciphertext = decode64(r.string("ciphertext")); require(ciphertext.size in 16..48016)
        val plain = Cipher.getInstance("AES/GCM/NoPadding").run { init(Cipher.DECRYPT_MODE, SecretKeySpec(key(d), "AES"), GCMParameterSpec(128, nonce)); updateAAD(aad(id, e, d, kind, created, expires)); doFinal(ciphertext) }
        val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(plain)).toString(); obj(text)
        return OpenRelay(id, e, kind, Instant.ofEpochSecond(created), Instant.ofEpochSecond(expires), text)
    }
}

/** No redirect or automatic upload retry, including after a timeout. */
class RelayHttp internal constructor(private val endpoint: RelayEndpoint, private val macId: String, private val deviceId: String, private val bearer: String, private val authTicket: String, client: OkHttpClient) {
    constructor(endpoint: RelayEndpoint, macId: String, deviceId: String, bearer: String, authTicket: String) : this(endpoint, macId, deviceId, bearer, authTicket, defaultClient)
    companion object { private val defaultClient = OkHttpClient() }
    // One-shot bodies additionally prevent HTTP status/authentication follow-up resubmissions.
    private val client = client.newBuilder().retryOnConnectionFailure(false).followRedirects(false).followSslRedirects(false).callTimeout(15, TimeUnit.SECONDS).connectTimeout(5, TimeUnit.SECONDS).readTimeout(5, TimeUnit.SECONDS).writeTimeout(5, TimeUnit.SECONDS).cache(null).build()
    init { canonicalId(macId); canonicalId(deviceId); decode64(bearer, 32); decode64(authTicket, 32) }
    fun call(op: String, envelope: String? = null, token: String? = null): JsonObject {
        require(op in setOf("poll", "send", "push"))
        val bytes = buildJsonObject { put("op", op); put("macId", macId); put("deviceId", deviceId); envelope?.let { put("envelope", obj(it)) }; token?.let { require(it.length in 1..4096); put("token", it) } }.toString().toByteArray(Charsets.UTF_8)
        require(bytes.size <= 262144)
        val body = object : RequestBody() {
            override fun contentType() = "application/json".toMediaType()
            override fun contentLength() = bytes.size.toLong()
            override fun isOneShot() = true
            override fun writeTo(sink: BufferedSink) { sink.write(bytes) }
        }
        val request = Request.Builder().url(endpoint.url.toString()).header("Authorization", "Bearer $bearer.$authTicket").header("Cache-Control", "no-store").post(body).build()
        client.newCall(request).execute().use { response ->
            require(response.code in 200..299) { "Relay request unavailable (${response.code})" }
            val received = requireNotNull(response.body).byteStream().use { input ->
                val out = java.io.ByteArrayOutputStream(); val buffer = ByteArray(8192)
                while (true) { val n = input.read(buffer); if (n == -1) break; require(out.size() + n <= 262144); out.write(buffer, 0, n) }; out.toByteArray()
            }
            return obj(Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(received)).toString())
        }
    }
}

/** State receipt cannot renew capturedAt or authenticate a status round trip. */
class RelayFreshness {
    var epoch: String? = null; private set
    private var revision = -1L
    private var latestCreated: Instant? = null
    private var captured: Instant? = null
    private var authenticatedAt: Instant? = null
    private var expected: Pair<String, Instant>? = null
    fun state(e: String, rev: Long, created: Instant, snapshot: JsonObject, now: Instant): Boolean {
        canonicalId(e); require(rev >= 0); validateSnapshot(snapshot)
        val capture = Instant.parse(snapshot.string("capturedAt")); require(capture <= now.plusSeconds(10))
        if (latestCreated?.let { created < it } == true || (e == epoch && rev <= revision)) return false
        val maintain = e == epoch && reachable(now)
        if (e != epoch) { authenticatedAt = null; expected = null; revision = -1 }
        epoch = e; revision = rev; latestCreated = created; captured = capture
        if (maintain) authenticatedAt = now
        else if (authenticatedAt?.let { now > it.plusSeconds(15) } == true) authenticatedAt = null
        return true
    }
    fun expectStatus(id: String, now: Instant) { canonicalId(id); require(epoch != null); expected = id to now }
    fun status(id: String, e: String, snapshot: JsonObject, now: Instant): Boolean {
        val pending = expected ?: return false
        if (pending.first != id || e != epoch || now < pending.second || now > pending.second.plusSeconds(30)) return false
        validateSnapshot(snapshot); val capture = Instant.parse(snapshot.string("capturedAt"))
        if (capture < pending.second.minusSeconds(1) || capture > now.plusSeconds(10) || now > capture.plusSeconds(15)) return false
        captured = capture; authenticatedAt = now; expected = null; return true
    }
    fun reachable(now: Instant): Boolean = authenticatedAt?.let { now >= it && now <= it.plusSeconds(15) } == true && captured?.let { now >= it.minusSeconds(10) && now <= it.plusSeconds(15) } == true
    fun disconnect() { authenticatedAt = null; expected = null }
}

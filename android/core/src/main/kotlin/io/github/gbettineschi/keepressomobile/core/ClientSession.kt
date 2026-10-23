package io.github.gbettineschi.keepressomobile.core

import java.time.Duration
import java.time.Instant
import kotlinx.serialization.json.*

class ClientSession(val macId: String, val deviceId: String, private val key: ByteArray, private val nonce: String = randomNonce()) {
    private enum class Phase { NEW, HELLO, AUTHENTICATING, READY, CLOSED }
    private var phase = Phase.NEW
    private var channel: SecureChannel? = null
    private var offset = Duration.ZERO
    var lastRequestId: String? = null; private set
    val ready: Boolean get() = phase == Phase.READY
    init { canonicalId(macId); canonicalId(deviceId); require(key.size == 32); decode64(nonce, 32) }
    fun hello(): String {
        require(phase == Phase.NEW); phase = Phase.HELLO
        return buildJsonObject { put("type", "hello"); put("version", 1); put("macId", macId); put("deviceId", deviceId); put("clientNonce", nonce) }.toString()
    }
    fun challenge(record: String): String {
        try {
            require(phase == Phase.HELLO); val r = obj(record); require(r.string("type") == "challenge")
            val transcript = Crypto.transcript(macId, deviceId, nonce, r.string("serverNonce"))
            require(Crypto.verify(key, "server\n$transcript", r.string("proof")))
            channel = SecureChannel(Crypto.directionKey(key, transcript, "c2s"), Crypto.directionKey(key, transcript, "s2c")); phase = Phase.AUTHENTICATING
            return buildJsonObject { put("type", "authenticate"); put("proof", Crypto.proof(key, "client\n$transcript")) }.toString()
        } catch (e: Exception) { phase = Phase.CLOSED; throw IllegalArgumentException("Server authentication failed", e) }
    }
    fun receive(record: String, localTime: Instant): String {
        try {
            require(phase == Phase.AUTHENTICATING || ready)
            val text = requireNotNull(channel).open(record); val r = obj(text)
            if (!ready) {
                require(r.string("type") == "ready" && r.string("macId") == macId && r.string("deviceId") == deviceId)
                offset = Duration.between(localTime, Instant.parse(r.string("serverTime"))); phase = Phase.READY
            } else require(r.string("type") in setOf("response", "event"))
            return text
        } catch (e: Exception) { phase = Phase.CLOSED; throw IllegalArgumentException("Session closed", e) }
    }
    fun request(action: String, localTime: Instant, duration: Int? = null, settings: ReminderSettings? = null): String {
        require(ready); val text = Requests.create(action, localTime.plus(offset), duration, settings)
        lastRequestId = obj(text).string("id"); return requireNotNull(channel).seal(text)
    }
}

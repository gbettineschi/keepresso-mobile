package io.github.gbettineschi.keepressomobile.core

import java.io.File
import java.time.Instant
import java.util.Base64
import kotlin.test.*
import kotlinx.serialization.json.*

class ProtocolTest {
    private val v = Json.parseToJsonElement(File(System.getProperty("vectors")).readText()).jsonObject
    private fun s(key: String) = v.getValue(key).jsonPrimitive.content
    private fun b(key: String) = Base64.getDecoder().decode(s(key))
    @Test fun independentlyGeneratedDeviceKey() { assertContentEquals(b("deviceKey"), Crypto.deviceKey(b("token"), s("macId"), s("deviceId"))) }
    @Test fun serverAndPairProofsMatchIndependentVectors() {
        assertEquals(s("serverProof"), Crypto.proof(b("deviceKey"), "server\n" + s("transcript")))
        assertEquals(s("pairProof"), Crypto.proof(b("token"), s("pairTranscript")))
    }
    @Test fun directionKeysMatchIndependentVectors() { for (d in listOf("c2s", "s2c")) assertContentEquals(b(d), Crypto.directionKey(b("deviceKey"), s("transcript"), d)) }
    @Test fun encryptedRequestMatchesIndependentVector() { assertEquals(s("ciphertext"), Json.parseToJsonElement(SecureChannel(b("c2s"), b("s2c")).seal(s("plaintext"))).jsonObject.getValue("ciphertext").jsonPrimitive.content) }
    @Test fun replayClosesSession() {
        val server = SecureChannel(b("s2c"), b("c2s")); val record = """{"type":"sealed","sequence":0,"ciphertext":"${s("ciphertext")}"}"""
        assertEquals(s("plaintext"), server.open(record)); assertFailsWith<IllegalArgumentException> { server.open(record) }; assertFailsWith<IllegalArgumentException> { server.open(record.replace("\"sequence\":0", "\"sequence\":1")) }
    }
    @Test fun tamperedTagClosesSession() {
        val c = b("ciphertext"); c[c.lastIndex] = (c.last().toInt() xor 1).toByte()
        val receiver = SecureChannel(b("s2c"), b("c2s"))
        assertFailsWith<IllegalArgumentException> { receiver.open("""{"type":"sealed","sequence":0,"ciphertext":"${Base64.getEncoder().encodeToString(c)}"}""") }
        assertFailsWith<IllegalArgumentException> { receiver.open(SecureChannel(b("c2s"), b("s2c")).seal("{}")) }
    }
    @Test fun wrongHandshakeNonceDoesNotDecrypt() {
        val wrong = Crypto.directionKey(b("deviceKey"), s("transcript") + "x", "c2s")
        assertFailsWith<IllegalArgumentException> { SecureChannel(b("s2c"), wrong).open(SecureChannel(b("c2s"), b("s2c")).seal("{}")) }
    }
    @Test fun arbitraryFragmentationIncludingPrefix() {
        val bytes = Framer.encode("{\"type\":\"hello\"}") + Framer.encode("{}")
        val f = Framer(); val records = bytes.flatMap { f.feed(byteArrayOf(it), 0) }
        assertEquals(listOf("{\"type\":\"hello\"}", "{}"), records)
    }
    @Test fun rejectsOversizeBeforeAllocation() { assertFailsWith<IllegalArgumentException> { Framer().feed(byteArrayOf(0, 1, 0, 1), 0) } }
    @Test fun rejectsExpiredPartialFrame() { val f = Framer(); f.feed(byteArrayOf(0, 0), 0); assertFailsWith<IllegalArgumentException> { f.feed(byteArrayOf(0, 2), 10001) } }
    @Test fun pairInvitationRejectsExpiredAndDuplicateFields() {
        val uri = "keespresso://pair?v=1&mac=${s("macId")}&token=${java.net.URLEncoder.encode(s("token"), "UTF-8")}&expires=1300&name=MacBook"
        assertEquals("MacBook", Invitation.parse(uri, 1000).name)
        assertFailsWith<IllegalArgumentException> { Invitation.parse(uri, 1300) }; assertFailsWith<IllegalArgumentException> { Invitation.parse(uri + "&v=1", 1000) }
    }
    @Test fun requestFreshnessAndDurationBounds() {
        val now = Instant.parse("2026-10-23T12:00:00Z")
        Requests.validate(Requests.create("start_manual", now, 15), now)
        assertFailsWith<IllegalArgumentException> { Requests.validate(s("plaintext"), now.plusSeconds(31)) }
        assertFailsWith<IllegalArgumentException> { Requests.create("start_manual", now, 16) }
        assertFailsWith<IllegalArgumentException> { Requests.create("shell", now) }
    }
    @Test fun unknownNeverBecomesInactiveAndStaleDisablesControls() {
        val state = DashboardState(); state.connected = true
        state.update("""{"capturedAt":"2026-10-23T12:00:00Z","keepresso":{"isActive":null}}""", 100)
        assertNull(state.active()); assertTrue(state.reachable(101)); assertFalse(state.reachable(15101))
        state.connected = false; assertFalse(state.reachable(101)); assertNull(state.active())
    }
    @Test fun wrongPeerChangesDeviceKey() { assertFalse(Crypto.deviceKey(b("token"), s("deviceId"), s("macId")).contentEquals(b("deviceKey"))) }
}

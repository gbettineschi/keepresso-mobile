package io.github.gbettineschi.keepressomobile.core
import java.io.File
import java.time.Instant
import kotlin.test.*
import kotlinx.serialization.json.*
class SessionTest {
    private val v = obj(File(System.getProperty("vectors")).readText())
    private fun s(k: String) = v.string(k)
    private fun b(k: String) = decode64(s(k))
    @Test fun verifiesServerBeforeClientProof() {
        val c = ClientSession(s("macId"), s("deviceId"), b("deviceKey"), s("clientNonce"))
        c.hello(); val auth = obj(c.challenge("""{"type":"challenge","serverNonce":"${s("serverNonce")}","proof":"${s("serverProof")}"}"""))
        assertEquals(s("clientProof"), auth.string("proof"))
    }
    @Test fun refusesUnverifiedServer() {
        val c = ClientSession(s("macId"), s("deviceId"), b("deviceKey"), s("clientNonce")); c.hello()
        assertFailsWith<IllegalArgumentException> { c.challenge("""{"type":"challenge","serverNonce":"${s("serverNonce")}","proof":"${s("clientProof")}"}""") }
        assertFalse(c.ready)
    }
    @Test fun usesServerClockForFreshRequests() {
        val c = ClientSession(s("macId"), s("deviceId"), b("deviceKey"), s("clientNonce")); c.hello()
        c.challenge("""{"type":"challenge","serverNonce":"${s("serverNonce")}","proof":"${s("serverProof")}"}""")
        val server = SecureChannel(b("s2c"), b("c2s")); val local = Instant.parse("2026-10-23T10:00:00Z")
        c.receive(server.seal("""{"type":"ready","macId":"${s("macId")}","deviceId":"${s("deviceId")}","serverTime":"2026-10-23T12:00:00Z"}"""), local)
        val request = server.open(c.request("status", local.plusSeconds(5)))
        assertTrue(c.ready); assertEquals("2026-10-23T12:00:05Z", obj(request).string("issuedAt"))
    }
    @Test fun neverSendsBeforeReady() { assertFailsWith<IllegalArgumentException> { ClientSession(s("macId"), s("deviceId"), b("deviceKey")).request("sleep_now", Instant.now()) } }
}

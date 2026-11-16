package io.github.gbettineschi.keepressomobile.core

import java.io.File
import java.time.Instant
import kotlin.test.*
import kotlinx.serialization.json.*

class InternetConfigTest {
    private val endpoint = encode64(ByteArray(32) { 0x42 })
    private val firebase = FirebaseClientConfiguration("keepresso-test", "1:123456:android:abcdef", "public-fixture-api-key", "123456")
    @Test fun publicConfigurationRoundTripsWithoutPairingMaterial() {
        val config = InternetConfiguration(endpointId = endpoint, firebase = firebase)
        assertEquals(config, InternetConfiguration.decode(config.encoded()))
        val r = obj(config.encoded())
        assertEquals("internet_config", r.string("type")); assertNull(r["key"]); assertNull(r["token"])
    }
    @Test fun rejectsMalformedAddressVersionAndFirebaseOptions() {
        for (invalid in listOf("", " $endpoint", endpoint + "=", encode64(ByteArray(31)))) {
            assertFails { InternetConfiguration(endpointId = invalid) }
        }
        val valid = InternetConfiguration(endpointId = endpoint).encoded()
        assertFails { InternetConfiguration.decode(valid.replace("\"version\":1", "\"version\":2")) }
        assertFails { InternetConfiguration.decode(valid.replace("\"version\":1", "\"version\":true")) }
        assertFails { FirebaseClientConfiguration("keepresso-test", "1:999:android:abcdef", "public-fixture-api-key", "123456") }
        assertFails { InternetConfiguration.decode("""{"type":"internet_config","version":1,"endpointId":"$endpoint","firebase":{"projectId":"keepresso-test"}}""") }
    }
    @Test fun registrationAcknowledgementCannotApplyToAnotherTokenOrProject() {
        val registration = PushRegistration("keepresso-test", "current-fixture-token", 2)
        val ack = PushRegistrationAck(registration.projectId, registration.revision, registration.tokenHash)
        assertTrue(ack.matches(registration))
        assertFalse(ack.matches(PushRegistration("keepresso-test", "new-fixture-token", 3)))
        assertFalse(ack.matches(PushRegistration("other-project", "current-fixture-token", 2)))
        assertEquals(registration, PushRegistration.decode(registration.encoded()))
        assertFails { PushRegistration("keepresso-test", "invalid\ntoken", 2) }
        assertFails { PushRegistration("keepresso-test", "fixture", 0) }
    }
    @Test fun acceptsConfigurationAndRegistrationAckOnlyAfterAuthentication() {
        val v = obj(File(System.getProperty("vectors")).readText())
        fun s(key: String) = v.string(key)
        val c = ClientSession(s("macId"), s("deviceId"), decode64(s("deviceKey")), s("clientNonce"))
        val server = SecureChannel(decode64(s("s2c")), decode64(s("c2s")))
        val now = Instant.parse("2026-10-30T10:00:00Z")
        c.hello(); c.challenge("""{"type":"challenge","serverNonce":"${s("serverNonce")}","proof":"${s("serverProof")}"}""")
        c.receive(server.seal("""{"type":"ready","macId":"${s("macId")}","deviceId":"${s("deviceId")}","serverTime":"$now"}"""), now)
        val config = InternetConfiguration(endpointId = endpoint).encoded()
        assertEquals(config, c.receive(server.seal(config), now))
        val registration = PushRegistration("keepresso-test", "fixture-token", 1)
        assertEquals(registration, PushRegistration.decode(server.open(c.registerPush(registration))))
        val ack = PushRegistrationAck(registration.projectId, registration.revision, registration.tokenHash).encoded()
        assertEquals(ack, c.receive(server.seal(ack), now))
        assertFails { ClientSession(s("macId"), s("deviceId"), decode64(s("deviceKey"))).registerPush(registration) }
    }
}

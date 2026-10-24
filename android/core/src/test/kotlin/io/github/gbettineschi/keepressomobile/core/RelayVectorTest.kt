package io.github.gbettineschi.keepressomobile.core

import java.io.File
import java.time.Instant
import kotlin.test.*
import kotlinx.serialization.json.*

class RelayVectorTest {
    private val v = obj(File(System.getProperty("relayVectors")).readText())
    private val codec = RelayCodec(v.string("macId"), v.string("deviceId"), decode64(v.string("deviceKey"), 32))
    @Test fun independentNodeHkdfKeysBearerAndAesEnvelopeMatch() {
        assertContentEquals(decode64(v.string("c2s")), codec.key("c2s"))
        assertContentEquals(decode64(v.string("s2c")), codec.key("s2c"))
        assertEquals(v.string("phoneBearer"), codec.bearer())
        val e = v.getValue("envelope").jsonObject
        val sealed = codec.seal(v.string("plaintext"), e.string("id"), e.string("epoch"), "c2s", "command", Instant.ofEpochSecond(e.getValue("createdAt").jsonPrimitive.long), Instant.ofEpochSecond(e.getValue("expiresAt").jsonPrimitive.long), decode64(e.string("nonce")))
        assertEquals(e, obj(sealed))
        assertEquals(v.string("plaintext"), codec.open(e.toString(), Instant.ofEpochSecond(e.getValue("createdAt").jsonPrimitive.long), "c2s", setOf("command"), e.string("epoch")).plaintext)
    }
}

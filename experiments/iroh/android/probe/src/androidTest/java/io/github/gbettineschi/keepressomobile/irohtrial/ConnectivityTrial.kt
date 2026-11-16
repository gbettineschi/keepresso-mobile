package io.github.gbettineschi.keepressomobile.irohtrial

import android.os.Build
import android.os.Bundle
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import computer.iroh.*
import io.github.gbettineschi.keepressomobile.core.ClientSession
import java.nio.ByteBuffer
import java.time.Instant
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

private const val MAC = "11111111-1111-4111-8111-111111111111"
private const val DEVICE = "22222222-2222-4222-8222-222222222222"
private val KEY = ByteArray(32) { 0x42 }
private val ALPN = "keepresso-mobile/iroh-trial/1".toByteArray()

private class RelayFixturePreset : Preset {
    override fun apply(builder: EndpointBuilder) {
        builder.applyMinimal()
        builder.bindAddr("[::1]:0")
    }
}

@RunWith(AndroidJUnit4::class)
class ConnectivityTrial {
    private val args get() = InstrumentationRegistry.getArguments()
    private val relay get() = args.getString("mode") == "relay"
    private val internet get() = args.getString("mode") != "direct"

    @Before fun explicitlyAuthorizedDevice() {
        val virtual = Build.FINGERPRINT.contains("generic") || Build.MODEL.contains("sdk_gphone")
        check(virtual || args.getString("allowPhysical") == "true") {
            "Physical trials require the runner's explicit --physical-device flag and serial"
        }
        IrohAndroid.installAndroidContext(InstrumentationRegistry.getInstrumentation().targetContext)
    }

    private suspend fun <T> link(transportSeed: Byte = 0x63, block: suspend (Connection, BiStream) -> T): T {
        val endpoint = Endpoint.bind(EndpointOptions(
            preset = if (relay) RelayFixturePreset() else (if (internet) presetN0() else presetMinimal()), secretKey = ByteArray(32) { transportSeed },
            bindAddr = if (relay) "127.0.0.1:0" else "0.0.0.0:0",
            relayMode = if (internet) RelayMode.defaultMode() else RelayMode.disabled()))
        try {
            val ticket = EndpointTicket.fromString(requireNotNull(args.getString("ticket")))
            val connection = withTimeout(20_000) { endpoint.connect(ticket.endpointAddr(), ALPN) }
            assertEquals(ticket.endpointAddr().id(), connection.remoteId())
            try { return block(connection, connection.openBi()) }
            finally { connection.close(0L, "trial complete".toByteArray()) }
        } finally { endpoint.shutdown() }
    }

    private suspend fun send(bi: BiStream, record: String) {
        val bytes = record.toByteArray()
        check(bytes.isNotEmpty() && bytes.size <= 65536)
        bi.send().writeAll(ByteBuffer.allocate(4).putInt(bytes.size).array() + bytes)
    }

    private suspend fun receive(bi: BiStream): String {
        val length = ByteBuffer.wrap(bi.recv().readExact(4u)).int
        check(length in 1..65536)
        return bi.recv().readExact(length.toUInt()).decodeToString(throwOnInvalidSequence = true)
    }

    private suspend fun authenticate(bi: BiStream, key: ByteArray = KEY, device: String = DEVICE): ClientSession {
        val session = ClientSession(MAC, device, key)
        send(bi, session.hello())
        send(bi, session.challenge(receive(bi)))
        val ready = session.receive(receive(bi), Instant.now())
        assertEquals("ready", Json.parseToJsonElement(ready).jsonObject["type"]!!.jsonPrimitive.content)
        assertTrue(session.ready)
        return session
    }

    private suspend fun expectClosed(bi: BiStream) {
        try {
            withTimeout(5_000) { receive(bi) }
            fail("Malformed or unauthorized session returned a record")
        } catch (e: TimeoutCancellationException) { throw e }
        catch (_: Exception) { /* Remote closed before any private record. */ }
    }

    @Test fun encryptedStatusAndPath() = runBlocking {
        withTimeout(60_000) {
            link { connection, bi ->
                val session = authenticate(bi)
                val samples = mutableListOf<Long>()
                repeat(30) {
                    val start = System.nanoTime()
                    send(bi, session.request("status", Instant.now()))
                    val reply = Json.parseToJsonElement(session.receive(receive(bi), Instant.now())).jsonObject
                    assertEquals("ok", reply["status"]!!.jsonPrimitive.content)
                    assertEquals(session.lastRequestId, reply["id"]!!.jsonPrimitive.content)
                    assertEquals("Synthetic iroh trial", reply["message"]!!.jsonPrimitive.content)
                    samples += (System.nanoTime() - start) / 1_000_000
                }
                val selected = connection.paths().filter { it.isSelected }
                assertTrue("No selected path was observable", selected.isNotEmpty())
                val sorted = samples.sorted()
                val path = selected.map { if (it.isRelay) "relay" else if (it.isIp) "ip" else "other" }.distinct().sorted().joinToString("+")
                val context = InstrumentationRegistry.getInstrumentation().targetContext
                val manager = context.getSystemService(ConnectivityManager::class.java)
                val caps = manager.getNetworkCapabilities(manager.activeNetwork)
                val network = when {
                    caps == null -> "none"
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                    else -> "other"
                }
                val metrics = "IROH_TRIAL mode=${args.getString("mode")} samples=${samples.size} medianMs=${sorted[sorted.size/2]} maxMs=${sorted.last()} path=$path network=$network"
                InstrumentationRegistry.getInstrumentation().sendStatus(2, Bundle().apply { putString("stream", metrics) })
                assertTrue("Unexpected transport path", selected.all { if (relay) it.isRelay else if (internet) it.isIp || it.isRelay else it.isIp })
            }
        }
    }

    @Test fun reconnectKeepsAuthorization() = runBlocking {
        withTimeout(90_000) { repeat(20) {
            link { _, bi ->
                val session = authenticate(bi)
                send(bi, session.request("status", Instant.now()))
                assertEquals("ok", Json.parseToJsonElement(session.receive(receive(bi), Instant.now())).jsonObject["status"]!!.jsonPrimitive.content)
            }
        } }
    }

    @Test fun idleConnectionDoesNotBlockReconnection() = runBlocking {
        withTimeout(12_000) { link(0x64) { _, idle ->
            authenticate(idle)
            // A previous transport can linger after a phone changes routes.
            // A new authorized transport must not wait for its idle timeout.
            withTimeout(4_000) { link { _, fresh ->
                val session = authenticate(fresh)
                send(fresh, session.request("status", Instant.now()))
                assertEquals("ok", Json.parseToJsonElement(session.receive(receive(fresh), Instant.now())).jsonObject["status"]!!.jsonPrimitive.content)
            } }
        } }
    }

    @Test fun unknownDeviceRejected() = runBlocking {
        withTimeout(30_000) { link { _, bi ->
            send(bi, ClientSession(MAC, "33333333-3333-4333-8333-333333333333", KEY).hello())
            expectClosed(bi)
        } }
    }

    @Test fun wrongKeyRejected() = runBlocking {
        withTimeout(30_000) { link { _, bi ->
            val session = ClientSession(MAC, DEVICE, ByteArray(32) { 0x43 })
            send(bi, session.hello())
            val challenge = receive(bi)
            try { session.challenge(challenge); fail("Accepted a server proof for the wrong key") }
            catch (_: IllegalArgumentException) { assertFalse(session.ready) }
        } }
    }

    @Test fun replayedRecordClosesSession() = runBlocking {
        withTimeout(30_000) { link { _, bi ->
            val session = authenticate(bi)
            val record = session.request("status", Instant.now())
            send(bi, record)
            session.receive(receive(bi), Instant.now())
            send(bi, record)
            expectClosed(bi)
        } }
    }

    @Test fun oversizedFrameRejected() = runBlocking {
        withTimeout(30_000) { link { _, bi ->
            bi.send().writeAll(ByteBuffer.allocate(4).putInt(65537).array())
            expectClosed(bi)
        } }
    }

    @Test fun expiredRequestRejected() = runBlocking {
        withTimeout(30_000) { link { _, bi ->
            val session = authenticate(bi)
            send(bi, session.request("status", Instant.now().minusSeconds(120)))
            expectClosed(bi)
        } }
    }

    @Test fun mutationsNeverReachMac() = runBlocking {
        withTimeout(30_000) { link { _, bi ->
            val session = authenticate(bi)
            send(bi, session.request("sleep_now", Instant.now()))
            val reply = Json.parseToJsonElement(session.receive(receive(bi), Instant.now())).jsonObject
            assertEquals("error", reply["status"]!!.jsonPrimitive.content)
            assertEquals("Read-only trial", reply["message"]!!.jsonPrimitive.content)
        } }
    }
}

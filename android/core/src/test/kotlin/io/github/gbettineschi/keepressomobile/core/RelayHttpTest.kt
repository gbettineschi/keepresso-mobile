package io.github.gbettineschi.keepressomobile.core

import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import java.util.concurrent.TimeUnit
import kotlin.test.*

class RelayHttpTest {
    private fun exchange(code: Int, policy: SocketPolicy? = null, test: (RelayHttp, MockWebServer) -> Unit) {
        val certificate = HeldCertificate.Builder().commonName("localhost").addSubjectAlternativeName("localhost").build()
        val serverTls = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val clientTls = HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        MockWebServer().use { server ->
            server.useHttps(serverTls.sslSocketFactory(), false)
            server.enqueue(MockResponse().setResponseCode(code).setHeader("Location", "https://another.invalid/api/relay").setBody("{\"accepted\":true}").also { if (policy != null) it.setSocketPolicy(policy) })
            server.start()
            val client = OkHttpClient.Builder().sslSocketFactory(clientTls.sslSocketFactory(), clientTls.trustManager).build()
            val http = RelayHttp(RelayEndpoint(server.url("/").toString()), "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222", encode64(ByteArray(32)), encode64(ByteArray(32) { 1 }), client)
            test(http, server)
        }
    }
    @Test fun crossOriginRedirectIsRejectedAndBearerRemainsAtOriginalOrigin() = exchange(307) { http, server ->
        assertFails { http.call("poll") }
        val request = assertNotNull(server.takeRequest(1, TimeUnit.SECONDS))
        assertEquals("Bearer AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=.AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=", request.getHeader("Authorization"))
        assertEquals("/api/relay", request.path)
        assertNull(server.takeRequest(200, TimeUnit.MILLISECONDS))
    }
    @Test fun disconnectAfterUploadNeverResubmitsCommand() = exchange(200, SocketPolicy.DISCONNECT_AFTER_REQUEST) { http, server ->
        assertFails { http.call("send", envelope = "{}") }
        assertNotNull(server.takeRequest(1, TimeUnit.SECONDS))
        assertNull(server.takeRequest(300, TimeUnit.MILLISECONDS))
    }
    @Test fun retryableHttpStatusNeverResubmitsCommand() = exchange(408) { http, server ->
        assertFails { http.call("send", envelope = "{}") }
        assertNotNull(server.takeRequest(1, TimeUnit.SECONDS))
        assertNull(server.takeRequest(200, TimeUnit.MILLISECONDS))
    }
}

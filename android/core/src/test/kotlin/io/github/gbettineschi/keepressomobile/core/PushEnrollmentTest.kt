package io.github.gbettineschi.keepressomobile.core

import kotlin.test.*

class PushEnrollmentTest {
    private val config = PushRelayConfig("https://relay.invalid", "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222", encode64(ByteArray(32)), encode64(ByteArray(32) { 1 }))
    @Test fun configurationImmediatelyRegistersExistingTokenWithoutWaitingForInternetPollOrBluetoothDisconnect() {
        var marker: String? = null; var token: String? = "existing-token"; val delivered = mutableListOf<String>(); var callback: ((String) -> Unit)? = null
        val registration = PushEnrollment({ config }, { token }, { token = it }, { marker }, { marker = it }, { target, value -> assertEquals(config, target); delivered += value })
        registration.configurationReceived { callback = it }
        assertEquals(listOf("existing-token"), delivered)
        assertNotNull(callback).invoke("existing-token")
        assertEquals(listOf("existing-token"), delivered)
    }
    @Test fun rotatedTokenIsCommittedBeforeAuthenticatedRegistrationWithoutNearbyService() {
        var stored: String? = null; var marker: String? = null; var registered: String? = null
        val registration = PushEnrollment({ config }, { stored }, { stored = it }, { marker }, { marker = it }, { _, value -> assertEquals(value, stored); registered = value })
        registration.tokenChanged("rotated-token")
        assertEquals("rotated-token", registered)
        assertNotNull(marker)
    }
    @Test fun absentConfigurationNeverRequestsOrUploadsTokenButRotationStillPersists() {
        var stored: String? = null
        val registration = PushEnrollment({ null }, { stored }, { stored = it }, { null }, {}, { _, _ -> fail("no authorized relay configured") })
        registration.configurationReceived { fail("must validate relay before requesting Firebase token") }
        registration.tokenChanged("rotated-token")
        assertEquals("rotated-token", stored)
    }
    @Test fun disabledConfigurationDuringTokenRequestCannotRegisterStaleRelay() {
        var current: PushRelayConfig? = config; var callback: ((String) -> Unit)? = null; var stored: String? = null
        val registration = PushEnrollment({ current }, { stored }, { stored = it }, { null }, {}, { _, _ -> fail("configuration was disabled") })
        registration.configurationReceived { callback = it }
        current = null
        assertNotNull(callback).invoke("token")
        assertEquals("token", stored)
    }
    @Test fun failedAtomicTokenSavePreventsUploadingIt() {
        val registration = PushEnrollment({ config }, { null }, { error("disk failed") }, { null }, {}, { _, _ -> fail("token was not durably saved") })
        assertFails { registration.tokenChanged("token") }
    }
    @Test fun rotationDuringGetTokenCannotBeOverwrittenByOlderCallback() {
        var stored: String? = null; var marker: String? = null; var callback: ((String) -> Unit)? = null; val uploads = mutableListOf<String>()
        val registration = PushEnrollment({ config }, { stored }, { stored = it }, { marker }, { marker = it }, { _, value -> uploads += value })
        registration.configurationReceived { callback = it }
        registration.tokenChanged("new-token")
        assertNotNull(callback).invoke("old-token")
        assertEquals("new-token", stored)
        assertEquals(listOf("new-token"), uploads)
    }
    @Test fun changedAuthenticationTicketRegistersExistingTokenAgain() {
        var current = config; var marker: String? = null; var calls = 0
        val registration = PushEnrollment({ current }, { "token" }, {}, { marker }, { marker = it }, { _, _ -> calls++ })
        registration.configurationReceived {}
        registration.configurationReceived {}
        assertEquals(1, calls)
        current = config.copy(authTicket = encode64(ByteArray(32) { 2 }))
        registration.configurationReceived {}
        assertEquals(2, calls)
    }
}

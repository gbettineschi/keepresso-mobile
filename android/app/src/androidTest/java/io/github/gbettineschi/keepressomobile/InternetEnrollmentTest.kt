package io.github.gbettineschi.keepressomobile

import androidx.test.platform.app.InstrumentationRegistry
import io.github.gbettineschi.keepressomobile.core.*
import org.junit.*

class InternetEnrollmentTest {
    @get:Rule val emulatorOnly=EmulatorOnlyRule()
    @Test fun metadataRoundTripKeepsLegacyPairAndRejectsMalformedReplacement() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val credentials=CredentialStore(context)
        val fixture=Credential("11111111-1111-4111-8111-111111111111","22222222-2222-4222-8222-222222222222","Fixture Mac",ByteArray(32){0x42},"https://legacy.example",encode64(ByteArray(32){2}))
        credentials.clearPrivateState();credentials.save(fixture)
        val endpoint=InternetCredentialStore.endpointSecret(credentials)
        val metadata=InternetCredentialStore(credentials,fixture)
        val config=InternetConfiguration(encode64(ByteArray(32){3}))
        metadata.acceptAuthenticated(config.encoded())
        Assert.assertEquals(config,InternetCredentialStore(CredentialStore(context),fixture).configuration)
        Assert.assertTrue("Malformed config must be rejected",runCatching{metadata.acceptAuthenticated("{}")}.isFailure)
        Assert.assertEquals(config,metadata.configuration)
        val retained=requireNotNull(credentials.load())
        Assert.assertEquals(fixture.macId,retained.macId)
        Assert.assertEquals(fixture.deviceId,retained.deviceId)
        Assert.assertArrayEquals(fixture.key,retained.key)
        Assert.assertArrayEquals(endpoint,InternetCredentialStore.endpointSecret(CredentialStore(context)))
        Assert.assertEquals(fixture.relayAuthTicket,retained.relayAuthTicket)
    }
}

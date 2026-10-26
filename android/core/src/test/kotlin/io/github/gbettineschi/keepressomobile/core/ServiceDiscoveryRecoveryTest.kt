package io.github.gbettineschi.keepressomobile.core
import kotlin.test.*
class ServiceDiscoveryRecoveryTest {
    @Test fun staleServiceCacheCanBeRefreshedOnlyOncePerConnection(){
        val recovery=ServiceDiscoveryRecovery();var calls=0
        assertTrue(recovery.tryRefresh{calls++;true})
        assertFalse(recovery.tryRefresh{calls++;true})
        assertEquals(1,calls)
        assertTrue(ServiceDiscoveryRecovery().tryRefresh{true})
    }
    @Test fun unavailableOrRestrictedPlatformMethodFailsClosedWithoutLooping(){
        val recovery=ServiceDiscoveryRecovery();var calls=0
        assertFalse(recovery.tryRefresh{calls++;throw SecurityException("Synthetic restriction")})
        assertFalse(recovery.tryRefresh{calls++;true});assertEquals(1,calls)
        assertFalse(ServiceDiscoveryRecovery().tryRefresh{false})
    }
}

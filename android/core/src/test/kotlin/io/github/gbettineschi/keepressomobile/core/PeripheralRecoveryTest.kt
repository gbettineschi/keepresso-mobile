package io.github.gbettineschi.keepressomobile.core

import kotlin.test.*

class PeripheralRecoveryTest {
    private val idle = PeripheralRecovery.State()

    @Test fun startupFailureBacksOffAndRepeatedSignalsCoalesce() {
        val recovery = PeripheralRecovery()
        assertEquals(1000L, recovery.nextAttemptAt(1000, idle))
        recovery.failed(1000)
        repeat(5) { assertEquals(16000L, recovery.nextAttemptAt(1001L + it, idle)) }
        recovery.failed(16000)
        assertEquals(46000L, recovery.nextAttemptAt(16001, idle))
        recovery.failed(46000)
        assertEquals(106000L, recovery.nextAttemptAt(46001, idle))
        recovery.failed(106000)
        assertEquals(166000L, recovery.nextAttemptAt(106001, idle))
    }

    @Test fun radioOffWaitsIndefinitelyAndReturnRecoversWithoutForeground() {
        val recovery = PeripheralRecovery()
        recovery.failed(0)
        for (now in listOf(1L, 15000L, 60000L, 300000L)) {
            assertNull(recovery.nextAttemptAt(now, idle.copy(radioOn = false)))
        }
        assertEquals(300001L, recovery.nextAttemptAt(300001, idle))
    }

    @Test fun disablingNearbyRemovingPairingDenyingPermissionOrDestroyingCancelsRecovery() {
        val blocked = listOf(idle.copy(enabled = false), idle.copy(nearbyEnabled = false), idle.copy(paired = false), idle.copy(permission = false))
        for (state in blocked) {
            val recovery = PeripheralRecovery()
            recovery.failed(0)
            assertNull(recovery.nextAttemptAt(20000, state))
            assertNull(recovery.nextAttemptAt(200000, state))
            assertEquals(200001L, recovery.nextAttemptAt(200001, idle))
        }
    }

    @Test fun publishingServerOrSessionSuppressesAnyRetry() {
        val recovery = PeripheralRecovery()
        recovery.failed(0)
        assertNull(recovery.nextAttemptAt(15000, idle.copy(serverRunning = true)))
        assertNull(recovery.nextAttemptAt(60000, idle.copy(sessionActive = true)))
        assertEquals(60001L, recovery.nextAttemptAt(60001, idle))
    }

    @Test fun stableAdvertisingResetsBackoffAndTrueDisconnectCanRecover() {
        val recovery = PeripheralRecovery()
        recovery.failed(0); recovery.failed(15000); recovery.failed(45000)
        recovery.stable()
        assertNull(recovery.nextAttemptAt(50000, idle.copy(serverRunning = true, sessionActive = true)))
        assertEquals(50001L, recovery.nextAttemptAt(50001, idle))
        recovery.failed(50001)
        assertEquals(65001L, recovery.nextAttemptAt(50002, idle))
    }
}

package io.github.gbettineschi.keepressomobile.core

import kotlin.test.*
import org.junit.Test

class NearbyRecoveryIssueTest {
    @Test fun intentionalAuthorizationStopRemainsActionableUntilReconnectReenablesNearby() {
        val stopped = PeripheralRecovery.State(nearbyEnabled=false)
        assertEquals(NearbyRecoveryIssue.AUTHORIZATION_STOPPED,nearbyRecoveryIssue(stopped))
        assertEquals(NearbyRecoveryIssue.AUTHORIZATION_STOPPED,nearbyRecoveryIssue(stopped.copy(serverRunning=false,sessionActive=false)))
        assertNull(nearbyRecoveryIssue(stopped.copy(nearbyEnabled=true)))
    }
    @Test fun permissionGateRequiresUserActionEvenWithoutAnActiveServer() {
        assertEquals(NearbyRecoveryIssue.PERMISSION_REQUIRED,nearbyRecoveryIssue(PeripheralRecovery.State(permission=false)))
        assertNull(nearbyRecoveryIssue(PeripheralRecovery.State(permission=true)))
    }
    @Test fun radioGateIsActionableButOrdinaryConnectionRecoveryIsQuiet() {
        assertEquals(NearbyRecoveryIssue.BLUETOOTH_DISABLED,nearbyRecoveryIssue(PeripheralRecovery.State(radioOn=false)))
        assertNull(nearbyRecoveryIssue(PeripheralRecovery.State(serverRunning=false,sessionActive=false)))
        assertNull(nearbyRecoveryIssue(PeripheralRecovery.State(serverRunning=true,sessionActive=false)))
        assertNull(nearbyRecoveryIssue(PeripheralRecovery.State(serverRunning=true,sessionActive=true)))
    }
    @Test fun unpairedOrDisabledServiceDoesNotCreatePairedGuidance() {
        assertNull(nearbyRecoveryIssue(PeripheralRecovery.State(paired=false,permission=false)))
        assertNull(nearbyRecoveryIssue(PeripheralRecovery.State(enabled=false,nearbyEnabled=false)))
    }
}

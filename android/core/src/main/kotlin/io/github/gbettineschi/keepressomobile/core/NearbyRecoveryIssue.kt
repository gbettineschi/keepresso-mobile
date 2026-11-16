package io.github.gbettineschi.keepressomobile.core

/** Stable user-action gates, independent of transient route diagnostics. */
enum class NearbyRecoveryIssue(val compactMessage: String, val message: String) {
    PERMISSION_REQUIRED("Allow Nearby Devices in Settings.", "Nearby Devices permission is required. Tap Permissions."),
    AUTHORIZATION_STOPPED("Check Mac, then Reconnect in Settings.", "Nearby authorization stopped. Check your Mac, then tap Reconnect."),
    BLUETOOTH_DISABLED("Turn on Bluetooth for nearby access.", "Bluetooth is off. Turn it on to connect nearby.")
}

fun nearbyRecoveryIssue(state: PeripheralRecovery.State): NearbyRecoveryIssue? = when {
    !state.enabled || !state.paired -> null
    !state.permission -> NearbyRecoveryIssue.PERMISSION_REQUIRED
    !state.nearbyEnabled -> NearbyRecoveryIssue.AUTHORIZATION_STOPPED
    !state.radioOn -> NearbyRecoveryIssue.BLUETOOTH_DISABLED
    else -> null
}

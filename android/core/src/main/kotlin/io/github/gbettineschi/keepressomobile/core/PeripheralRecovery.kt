package io.github.gbettineschi.keepressomobile.core

/** Recovery scheduling only; never grants session authority or retains command intent. */
class PeripheralRecovery {
    data class State(
        val enabled: Boolean = true,
        val nearbyEnabled: Boolean = true,
        val paired: Boolean = true,
        val permission: Boolean = true,
        val radioOn: Boolean = true,
        val serverRunning: Boolean = false,
        val sessionActive: Boolean = false
    )
    private var nextAllowedAt = 0L
    private var delay = 15000L

    fun nextAttemptAt(now: Long, state: State): Long? {
        if (!state.enabled || !state.nearbyEnabled || !state.paired || !state.permission || !state.radioOn) {
            stable()
            return null
        }
        if (state.serverRunning || state.sessionActive) return null
        return maxOf(now, nextAllowedAt)
    }

    /** A failed startup or real disconnect delays another attempt, capped at one per minute. */
    fun failed(now: Long) {
        nextAllowedAt = now + delay
        delay = (delay * 2).coerceAtMost(60000L)
    }

    fun stable() { nextAllowedAt = 0; delay = 15000L }
}

package io.github.gbettineschi.keepressomobile.core

/** A stale advertised service gets one cache recovery, never an unbounded retry. */
class ServiceDiscoveryRecovery {
    private var attempted=false
    fun tryRefresh(refresh:()->Boolean):Boolean {
        if(attempted)return false
        attempted=true
        return runCatching(refresh).getOrDefault(false)
    }
}

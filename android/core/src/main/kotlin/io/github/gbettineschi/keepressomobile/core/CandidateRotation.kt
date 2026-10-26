package io.github.gbettineschi.keepressomobile.core
/** Discovery routing only, never evidence of identity or authorization. */
class CandidateRotation {
    private val cooldowns = linkedMapOf<String, Long>()
    fun allowed(address: String, nowMillis: Long): Boolean { cooldowns.entries.removeAll { it.value <= nowMillis }; return address !in cooldowns }
    fun failed(address: String, nowMillis: Long) { cooldowns.remove(address); cooldowns[address] = nowMillis + 60000; while (cooldowns.size > 16) cooldowns.remove(cooldowns.keys.first()) }
    fun clear() { cooldowns.clear() }
}

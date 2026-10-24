package io.github.gbettineschi.keepressomobile.core
import kotlin.test.*
class CandidateRotationTest {
    @Test fun failedPeerDoesNotStarveOtherNearbyMac() { val c = CandidateRotation(); c.failed("wrong-mac", 0); assertFalse(c.allowed("wrong-mac", 100)); assertTrue(c.allowed("intended-mac", 100)); assertTrue(c.allowed("wrong-mac", 60001)) }
    @Test fun explicitReconnectClearsCooldownAndCacheIsBounded() { val c = CandidateRotation(); repeat(17) { c.failed("mac-$it", 0) }; assertTrue(c.allowed("mac-0", 1)); assertFalse(c.allowed("mac-16", 1)); c.clear(); assertTrue(c.allowed("mac-16", 1)) }
}

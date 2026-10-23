package io.github.gbettineschi.keepressomobile.core
import kotlin.test.*
class DeliveryTest {
    @Test fun disconnectMarksMutationsUncertainWithoutReplay() { val d = Delivery(); d.sent("a", true); assertEquals(mapOf("a" to "uncertain"), d.disconnect()); assertTrue(d.disconnect().isEmpty()) }
    @Test fun acknowledgedMutationDoesNotBecomeUncertain() { val d = Delivery(); d.sent("a", true); d.acknowledge("a", "ok"); assertTrue(d.disconnect().isEmpty()) }
    @Test fun refusesPollOverlappingTriggerRefresh() { val d = Delivery(); d.sent("refresh", false); assertFailsWith<IllegalArgumentException> { d.sent("poll", false) }; d.acknowledge("refresh", "ok"); d.sent("poll", false); assertEquals(mapOf("poll" to "disconnected"), d.disconnect()) }
    @Test fun serializesAndFragmentsGattWrites() { val q = WriteQueue(); q.enqueue(byteArrayOf(1,2,3,4,5), 2); assertContentEquals(byteArrayOf(1,2), q.next()); assertNull(q.next()); q.complete(); assertContentEquals(byteArrayOf(3,4), q.next()); q.clear(); assertNull(q.next()) }
}

package io.github.gbettineschi.keepressomobile.core
import kotlin.test.*
class DeliveryTest {
    @Test fun disconnectMarksMutationsUncertainWithoutReplay() { val d = Delivery(); d.sent("a", true); d.sent("b", false); assertEquals(mapOf("a" to "uncertain", "b" to "disconnected"), d.disconnect()); assertTrue(d.disconnect().isEmpty()) }
    @Test fun acknowledgedMutationDoesNotBecomeUncertain() { val d = Delivery(); d.sent("a", true); d.acknowledge("a", "ok"); assertTrue(d.disconnect().isEmpty()) }
    @Test fun serializesAndFragmentsGattWrites() { val q = WriteQueue(); q.enqueue(byteArrayOf(1,2,3,4,5), 2); assertContentEquals(byteArrayOf(1,2), q.next()); assertNull(q.next()); q.complete(); assertContentEquals(byteArrayOf(3,4), q.next()); q.clear(); assertNull(q.next()) }
}

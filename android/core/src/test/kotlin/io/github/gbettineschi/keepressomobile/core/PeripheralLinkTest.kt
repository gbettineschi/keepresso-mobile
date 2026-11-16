package io.github.gbettineschi.keepressomobile.core

import kotlin.test.*
import org.junit.Test

class PeripheralLinkTest {
    @Test fun cleanupReportsOnlySubscribedPeerLossOnce() {
        val link = PeripheralLink()
        assertFalse(link.reset())
        assertTrue(link.connect(link.generation, "noise"))
        assertFalse(link.reset())
        assertTrue(link.subscribe(link.generation, "mac"))
        assertTrue(link.reset())
        assertFalse(link.reset())
    }
    @Test fun subscriptionIsDeliveredOnceAndOnlyForCurrentCentral() {
        val link = PeripheralLink(); val epoch = link.generation
        assertTrue(link.connect(epoch, "noise"))
        assertTrue(link.connect(epoch, "other"))
        assertFalse(link.owns(epoch, "noise"))
        assertFalse(link.owns(epoch, "other"))
        assertTrue(link.subscribe(epoch, "mac"))
        assertFalse(link.subscribe(epoch, "other"))
        assertFalse(link.subscribe(epoch, "mac"))
        assertTrue(link.accepts(epoch, "mac"))
        link.reset(); link.connect(link.generation, "mac")
        assertFalse(link.subscribe(epoch, "mac"))
        assertFalse(link.accepts(epoch, "mac"))
    }
    @Test fun genericConnectionsDoNotAllowInputOrClaimPeerBeforeSubscription() {
        val link = PeripheralLink(); val epoch = link.generation
        link.connect(epoch, "headphones"); link.connect(epoch, "watch")
        assertFalse(link.owns(epoch, "headphones"))
        assertFalse(link.accepts(epoch, "watch"))
        assertTrue(link.receive(epoch, "headphones", Framer.encode("noise"), 0).isEmpty())
        assertFalse(link.complete(epoch, "headphones"))
        assertFailsWith<IllegalArgumentException> { link.enqueue("hello") }
        assertTrue(link.subscribe(epoch, "mac"))
        assertTrue(link.accepts(epoch, "mac"))
    }
    @Test fun subscriptionDoesNotRequireGenericConnectionCallback() {
        val link = PeripheralLink(); val epoch = link.generation
        assertTrue(link.subscribe(epoch, "mac"))
        assertTrue(link.owns(epoch, "mac"))
        assertFalse(link.subscribe(epoch, "other"))
        assertFalse(link.subscribe(epoch, "mac"))
        assertTrue(link.accepts(epoch, "mac"))
        assertTrue(link.receive(epoch, "other", Framer.encode("noise"), 0).isEmpty())
    }
    @Test fun selectedPeerUsesItsPreSubscriptionMtuDespiteConnectionNoise() {
        val link = PeripheralLink(); val epoch = link.generation
        link.connect(epoch, "headphones"); link.mtu(epoch, "headphones", 23)
        link.mtu(epoch, "mac", 517); link.connect(epoch, "watch"); link.mtu(epoch, "watch", 53)
        assertTrue(link.subscribe(epoch, "mac"))
        link.mtu(epoch, "watch", 23)
        link.enqueue("a".repeat(1000))
        assertEquals(512, assertNotNull(link.next()).size)
        assertFalse(link.complete(epoch, "watch")); assertNull(link.next())
        assertTrue(link.complete(epoch, "mac"))
    }
    @Test fun unclaimedMtuCacheEvictsOldPeersAndKeepsRecentNegotiation() {
        val link = PeripheralLink(); val epoch = link.generation
        link.mtu(epoch, "old", 517)
        repeat(100) { link.mtu(epoch, "noise-$it", 53) }
        assertTrue(link.subscribe(epoch, "old"))
        link.enqueue("a".repeat(1000))
        assertEquals(20, assertNotNull(link.next()).size)
        link.reset()
        val fresh = link.generation
        repeat(100) { link.mtu(fresh, "noise-$it", 53) }
        link.mtu(fresh, "mac", 103)
        assertTrue(link.subscribe(fresh, "mac"))
        link.enqueue("a".repeat(1000))
        assertEquals(100, assertNotNull(link.next()).size)
    }
    @Test fun preSubscriptionMtuClampsBothExtremes() {
        for ((mtu, expected) in listOf(Int.MIN_VALUE to 20, Int.MAX_VALUE to 512)) {
            val link = PeripheralLink(); val epoch = link.generation
            link.mtu(epoch, "mac", mtu); assertTrue(link.subscribe(epoch, "mac"))
            link.enqueue("a".repeat(1000))
            assertEquals(expected, assertNotNull(link.next()).size)
        }
    }
    @Test fun resetDropsPreSubscriptionMtuAndStaleCallbacksCannotSelectOrChangeMtu() {
        val link = PeripheralLink(); val old = link.generation
        link.mtu(old, "mac", 517); assertFalse(link.reset())
        val epoch = link.generation
        assertFalse(link.connect(old, "noise"))
        assertFalse(link.subscribe(old, "noise"))
        link.mtu(old, "mac", 517)
        assertTrue(link.subscribe(epoch, "mac"))
        link.enqueue("a".repeat(1000))
        assertEquals(20, assertNotNull(link.next()).size)
        assertFalse(link.complete(old, "mac"))
        assertTrue(link.receive(old, "mac", Framer.encode("old"), 0).isEmpty())
    }
    @Test fun unrelatedDisconnectDoesNotLoseSelectedPeerOrQueuedBytes() {
        val link = PeripheralLink(); val epoch = link.generation
        link.connect(epoch, "watch"); assertFalse(link.disconnect(epoch, "watch"))
        assertTrue(link.subscribe(epoch, "mac")); link.enqueue("hello")
        assertNotNull(link.next())
        assertFalse(link.disconnect(epoch, "watch"))
        assertTrue(link.accepts(epoch, "mac"))
        assertTrue(link.complete(epoch, "mac"))
        assertTrue(link.disconnect(epoch, "mac"))
        assertTrue(link.reset()); assertFalse(link.reset())
    }
    @Test fun unclaimedDisconnectDropsMtuButStaleDisconnectCannotEraseCurrentMtu() {
        val link = PeripheralLink(); val epoch = link.generation
        link.mtu(epoch, "mac", 517)
        assertFalse(link.disconnect(epoch, "mac"))
        assertTrue(link.subscribe(epoch, "mac")); link.enqueue("a".repeat(1000))
        assertEquals(20, assertNotNull(link.next()).size)
        link.reset()
        val fresh = link.generation
        link.mtu(fresh, "mac", 103)
        assertFalse(link.disconnect(epoch, "mac"))
        assertTrue(link.subscribe(fresh, "mac")); link.enqueue("a".repeat(1000))
        assertEquals(100, assertNotNull(link.next()).size)
        assertFalse(link.disconnect(epoch, "mac")); assertTrue(link.accepts(fresh, "mac"))
    }
    @Test fun subscriptionEligibilityDoesNotClaimPeerAndRejectsCompetitorsAfterSelection() {
        val link = PeripheralLink(); val epoch = link.generation
        assertTrue(link.canSubscribe(epoch, "watch")); assertFalse(link.owns(epoch, "watch"))
        assertTrue(link.canSubscribe(epoch, "mac")); assertTrue(link.subscribe(epoch, "mac"))
        assertFalse(link.canSubscribe(epoch, "watch")); assertTrue(link.canSubscribe(epoch, "mac"))
        link.reset()
        assertFalse(link.canSubscribe(epoch, "mac"))
    }
    @Test fun notifyChunksAreSerializedAndBoundedByNegotiatedMtu() {
        val link = PeripheralLink(); val epoch = link.generation
        link.connect(epoch, "mac"); link.subscribe(epoch, "mac"); link.mtu(epoch, "mac", 23)
        link.enqueue("a".repeat(50))
        val first = assertNotNull(link.next())
        assertEquals(20, first.size)
        first.fill(0)
        assertNull(link.next())
        assertTrue(link.complete(epoch, "mac"))
        assertContentEquals(ByteArray(20) { 97 }, assertNotNull(link.next()))
        assertFalse(link.complete(epoch, "other")); assertNull(link.next())
        assertTrue(link.complete(epoch, "mac"))
        assertEquals(14, assertNotNull(link.next()).size)
        assertTrue(link.complete(epoch, "mac")); assertFalse(link.complete(epoch, "mac"))
        assertNull(link.next())
    }
    @Test fun mtuReductionAppliesToAlreadyQueuedRecords() {
        val link = PeripheralLink(); val epoch = link.generation
        link.connect(epoch, "mac"); link.subscribe(epoch, "mac"); link.mtu(epoch, "mac", 517)
        link.enqueue("a".repeat(1000))
        assertEquals(512, assertNotNull(link.next()).size)
        link.complete(epoch, "mac"); link.mtu(epoch, "mac", 23)
        assertEquals(20, assertNotNull(link.next()).size)
    }
    @Test fun mtuCannotExceed512AndWrongPeerCannotChangeIt() {
        val link = PeripheralLink(); val epoch = link.generation
        link.connect(epoch, "mac"); link.subscribe(epoch, "mac")
        link.mtu(epoch, "mac", 517); link.mtu(epoch, "other", 23)
        link.enqueue("a".repeat(1000))
        assertEquals(512, assertNotNull(link.next()).size)
    }
    @Test fun notifyReassemblesV1FramingAndWritesIgnoreOtherPeers() {
        val link = PeripheralLink(); val epoch = link.generation
        link.connect(epoch, "mac"); link.subscribe(epoch, "mac")
        val text = "{\"type\":\"hello\",\"unicode\":\"☕\"}"
        link.enqueue(text)
        val receiver = Framer(); val received = mutableListOf<String>()
        while (true) { val chunk = link.next() ?: break; received += receiver.feed(chunk, 0); link.complete(epoch, "mac") }
        assertEquals(listOf(text), received)
        val frame = Framer.encode(text)
        assertTrue(link.receive(epoch, "other", frame, 0).isEmpty())
        assertTrue(link.receive(epoch, "mac", frame.copyOfRange(0, 2), 0).isEmpty())
        assertEquals(listOf(text), link.receive(epoch, "mac", frame.copyOfRange(2, frame.size), 1))
    }
    @Test fun queueLimitIncludesInFlightAndResetDropsAllOldData() {
        val link = PeripheralLink(); val epoch = link.generation
        link.connect(epoch, "mac"); link.subscribe(epoch, "mac")
        link.enqueue("a".repeat(65536)); assertNotNull(link.next()); link.enqueue("b".repeat(65536))
        assertFailsWith<IllegalArgumentException> { link.enqueue("x") }
        link.reset(); link.connect(link.generation, "mac"); link.subscribe(link.generation, "mac")
        assertFalse(link.complete(epoch, "mac")); assertNull(link.next())
        assertTrue(link.receive(epoch, "mac", Framer.encode("old"), 0).isEmpty())
    }
    @Test fun partialWriteExpiresAndNoSendBeforeSubscription() {
        val link = PeripheralLink(); val epoch = link.generation
        link.connect(epoch, "mac")
        assertFailsWith<IllegalArgumentException> { link.enqueue("hello") }
        link.subscribe(epoch, "mac"); link.receive(epoch, "mac", byteArrayOf(0), 0)
        assertFailsWith<IllegalArgumentException> { link.receive(epoch, "mac", byteArrayOf(), 10001) }
    }
}

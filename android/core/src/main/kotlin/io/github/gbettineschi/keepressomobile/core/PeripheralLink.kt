package io.github.gbettineschi.keepressomobile.core

/** Main-loop confined physical link state. Discovery/subscription never authorize commands. */
class PeripheralLink {
    var generation = 0; private set
    private var peer: String? = null
    private var subscribed = false
    private var chunkSize = 20
    private val unclaimedChunkSizes = linkedMapOf<String, Int>()
    private val frames = java.util.ArrayDeque<ByteArray>()
    private var frameOffset = 0
    private var framer = Framer()
    private var inFlightBytes = 0
    private var pendingBytes = 0

    /** Returns true exactly once for a real peer being discarded, never for server-only cleanup. */
    fun reset(): Boolean {
        val hadPeer = peer != null
        generation++; peer = null; subscribed = false; chunkSize = 20
        unclaimedChunkSizes.clear()
        frames.clear(); frameOffset = 0; framer = Framer(); inFlightBytes = 0; pendingBytes = 0
        return hadPeer
    }
    fun owns(epoch: Int, candidate: String): Boolean = epoch == generation && peer == candidate
    // Android shares physical GATT connections with other apps. This callback
    // observes a link, never intent to use this service or command authority.
    fun connect(epoch: Int, candidate: String): Boolean = canSubscribe(epoch, candidate)
    fun canSubscribe(epoch: Int, candidate: String): Boolean =
        epoch == generation && (peer == null || peer == candidate)
    fun subscribe(epoch: Int, candidate: String): Boolean {
        if (!canSubscribe(epoch, candidate) || subscribed) return false
        peer = candidate; subscribed = true
        chunkSize = unclaimedChunkSizes[candidate] ?: 20
        unclaimedChunkSizes.clear()
        return true
    }
    /** Only the selected logical peer's disconnect is a loss of our session. */
    fun disconnect(epoch: Int, candidate: String): Boolean {
        if (epoch != generation) return false
        unclaimedChunkSizes.remove(candidate)
        return owns(epoch, candidate)
    }
    fun accepts(epoch: Int, candidate: String): Boolean = owns(epoch, candidate) && subscribed
    fun mtu(epoch: Int, candidate: String, mtu: Int) {
        if (epoch != generation) return
        val size = (mtu.toLong() - 3).coerceIn(20L, 512L).toInt()
        if (peer != null) {
            if (owns(epoch, candidate)) chunkSize = size
            return
        }
        // MTU can arrive before the CCCD write. Retain recent peers without an
        // unbounded registry of unrelated system-wide Bluetooth clients.
        unclaimedChunkSizes.remove(candidate)
        unclaimedChunkSizes[candidate] = size
        if (unclaimedChunkSizes.size > 16) unclaimedChunkSizes.remove(unclaimedChunkSizes.keys.first())
    }
    fun enqueue(text: String) {
        require(subscribed)
        val frame = Framer.encode(text)
        require(pendingBytes + frame.size <= 131080)
        frames.add(frame); pendingBytes += frame.size
    }
    fun next(): ByteArray? {
        if (inFlightBytes != 0) return null
        val frame = frames.peek() ?: return null
        val end = minOf(frameOffset + chunkSize, frame.size)
        val chunk = frame.copyOfRange(frameOffset, end)
        frameOffset = end
        if (end == frame.size) { frames.remove(); frameOffset = 0 }
        inFlightBytes = chunk.size
        return chunk
    }
    fun complete(epoch: Int, candidate: String): Boolean {
        if (!accepts(epoch, candidate) || inFlightBytes == 0) return false
        pendingBytes -= inFlightBytes; inFlightBytes = 0; return true
    }
    fun receive(epoch: Int, candidate: String, bytes: ByteArray, now: Long): List<String> =
        if (accepts(epoch, candidate)) framer.feed(bytes, now) else emptyList()
}

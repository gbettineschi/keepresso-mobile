package io.github.gbettineschi.keepressomobile.core

class Delivery {
    private val pending = linkedMapOf<String, Boolean>()
    fun sent(id: String, mutation: Boolean) { require(pending.size < 32 && !pending.containsKey(id)); pending[id] = mutation }
    fun acknowledge(id: String, status: String) { require(status in setOf("ok", "error", "uncertain")); require(pending.remove(id) != null) }
    fun disconnect(): Map<String, String> = pending.mapValues { if (it.value) "uncertain" else "disconnected" }.also { pending.clear() }
}
class WriteQueue {
    private val chunks = java.util.ArrayDeque<ByteArray>()
    private var busy = false
    private var bytes = 0
    fun enqueue(record: ByteArray, chunkSize: Int) {
        require(chunkSize in 1..512 && record.size in 1..65540 && bytes + record.size <= 131080)
        record.asList().chunked(chunkSize).forEach { chunks.add(it.toByteArray()) }; bytes += record.size
    }
    fun next(): ByteArray? { if (busy) return null; val next = chunks.poll() ?: return null; bytes -= next.size; busy = true; return next }
    fun complete() { require(busy); busy = false }
    fun clear() { chunks.clear(); bytes = 0; busy = false }
}

package io.github.gbettineschi.keepressomobile.core
import java.time.Instant
/** Local filtering only; this never stores a future command for the Mac. */
class LocalSnooze(private val read: (String) -> Long?, private val write: (String, Long?) -> Unit) {
    fun snooze(macId: String, now: Instant) { write(macId, now.plusSeconds(21600).epochSecond) }
    fun acknowledge(macId: String, action: String, status: String) { if (action == "resume_reminders" && status == "ok") reset(macId) }
    fun suppressed(macId: String, kind: String, now: Instant): Boolean = kind == "hourly" && (read(macId) ?: 0) > now.epochSecond
    fun reset(macId: String) { write(macId, null) }
}

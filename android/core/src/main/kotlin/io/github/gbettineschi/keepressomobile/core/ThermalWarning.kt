package io.github.gbettineschi.keepressomobile.core

import java.time.Instant
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject

internal val nativeThermalStates = setOf("nominal", "fair", "serious", "critical", "unknown")

enum class ThermalWarningLevel(val wireValue: String?) {
    SERIOUS("serious"), LEGACY(null), CRITICAL("critical");

    companion object {
        fun fromWire(value: String?): ThermalWarningLevel =
            requireNotNull(entries.firstOrNull { it.wireValue == value }) { "Invalid heat warning severity" }
    }
}

data class ThermalWarning(val createdAt: Instant, val level: ThermalWarningLevel) {
    fun isNewerThan(other: ThermalWarning): Boolean =
        createdAt > other.createdAt || (createdAt == other.createdAt && level > other.level)

    fun isSupersededBy(snapshot: JsonObject): Boolean {
        if (Instant.parse(snapshot.string("capturedAt")) <= createdAt) return false
        val mac = snapshot["mac"]?.takeUnless { it == JsonNull }?.jsonObject ?: return false
        val guardActive = mac.boolOrNull("thermalGuardActive")
        val state = mac.stringOrNull("thermalSeverity") ?: when (mac.stringOrNull("thermal")) {
            "normal" -> "nominal"
            "warm" -> "fair"
            else -> null
        }
        return when (state) {
            "critical" -> level == ThermalWarningLevel.SERIOUS
            "nominal", "fair", "serious" -> when {
                level == ThermalWarningLevel.CRITICAL -> true
                guardActive != null -> !guardActive
                else -> state != "serious"
            }
            else -> level == ThermalWarningLevel.SERIOUS && guardActive == false
        }
    }

    companion object {
        fun fromEvent(event: JsonObject): ThermalWarning {
            event.stringOrNull("thermalState")?.let { require(it in nativeThermalStates) }
            return ThermalWarning(
                Instant.parse(event.string("createdAt")),
                ThermalWarningLevel.fromWire(event.stringOrNull("thermalSeverity")),
            )
        }
    }
}

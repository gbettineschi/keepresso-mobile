package io.github.gbettineschi.keepressomobile
import android.os.Build
import org.junit.Assume
import org.junit.rules.ExternalResource
/** Runs before permission/activity rules, so device-wide runs cannot grant phone permissions. */
class EmulatorOnlyRule:ExternalResource(){override fun before(){Assume.assumeTrue("Requires the isolated emulator",Build.HARDWARE=="ranchu")}}

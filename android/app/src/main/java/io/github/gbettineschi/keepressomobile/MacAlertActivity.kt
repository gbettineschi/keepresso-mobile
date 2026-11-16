package io.github.gbettineschi.keepressomobile

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import io.github.gbettineschi.keepressomobile.core.CriticalAlarmStatus
import io.github.gbettineschi.keepressomobile.core.SleepOutcome
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withTimeoutOrNull

class SleepAttempt {
    private val result = MutableStateFlow<SleepOutcome?>(null)
    val outcome = result.asStateFlow()
    fun finish(value: SleepOutcome) { result.value = value }
}

internal fun finishSleep(attempt: SleepAttempt?, value: SleepOutcome) {
    attempt?.finish(value)
    Companion.update { it.copy(result = value.label) }
}

/** A foreground gesture may prepare a read-only route. It creates a command only when that route is fresh. */
private suspend fun requestSleepFromAlert(context: Context, lifecycle: Lifecycle, macId: String): SleepAttempt {
    val attempt = SleepAttempt()
    if (!lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED) ||
        runCatching { CredentialStore(context).load()?.macId }.getOrNull() != macId) {
        finishSleep(attempt, SleepOutcome.COULD_NOT_REQUEST_SLEEP)
        return attempt
    }
    var preparing: NearbyService? = null
    val submitted = try {
        if (Companion.service == null) {
            val intent = Intent(context, NearbyService::class.java)
                .setAction("foreground").putExtra("foreground", true).putExtra("preparingSleep", true)
            runCatching {
                if (NearbyPermissions.required().all { ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED })
                    ContextCompat.startForegroundService(context, intent)
                else context.startService(intent)
            }
        }
        withTimeoutOrNull(7_000) {
            var resumed = false
            while (lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) {
                val visible = lifecycle.currentState == Lifecycle.State.RESUMED
                if (resumed && !visible) break
                resumed = resumed || visible
                val service = Companion.service
                if (service != null) {
                    preparing = service
                    service.prepareSleepRoute()
                    if (visible && service.canRequestSleep(macId)) {
                        service.send("sleep_now", sleepAttempt = attempt)
                        return@withTimeoutOrNull true
                    }
                }
                delay(100)
            }
            false
        } == true
    } finally {
        preparing?.preparingSleep = false
    }
    if (!submitted) finishSleep(attempt, SleepOutcome.COULD_NOT_REQUEST_SLEEP)
    return attempt
}

@Composable
private fun sleepFeedback(macId: String, requested: Boolean, completedPreparation: () -> Unit): Pair<Boolean, SleepOutcome?> {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var attempt by remember(macId) { mutableStateOf<SleepAttempt?>(null) }
    LaunchedEffect(macId, requested) {
        if (requested) {
            attempt = requestSleepFromAlert(context, lifecycle, macId)
            completedPreparation()
        }
    }
    val outcome = attempt?.outcome?.collectAsState()?.value
    return (requested || (attempt != null && outcome == null)) to outcome
}

@Composable
internal fun SleepResultDialog(macId: String, initialRequest: Boolean = true, onClose: () -> Unit) {
    var requested by remember { mutableStateOf(initialRequest) }
    val (busy, outcome) = sleepFeedback(macId, requested) { requested = false }
    AlertDialog(
        onDismissRequest = onClose,
        title = { Text(if (busy) "Requesting sleep…" else (outcome ?: SleepOutcome.COULD_NOT_REQUEST_SLEEP).label) },
        confirmButton = { TextButton(onClick = onClose) { Text(if (busy) "Close" else "Dismiss") } },
    )
}

@Composable
internal fun CriticalHeatDialog(alert: CriticalAlert, confirmIgnoreOnOpen: Boolean = false, onClose: () -> Unit) {
    val context = LocalContext.current
    var confirmIgnore by remember(alert.incidentId) { mutableStateOf(confirmIgnoreOnOpen) }
    var requested by remember(alert.incidentId) { mutableStateOf(false) }
    val (busy, outcome) = sleepFeedback(alert.macId, requested) { requested = false }
    val critical = alert.status == CriticalAlarmStatus.CRITICAL
    val dismiss = { CriticalHeatAlerts.dismiss(context, alert); onClose() }
    AlertDialog(
        onDismissRequest = { if (!critical) dismiss() },
        properties = DialogProperties(dismissOnBackPress = !critical, dismissOnClickOutside = !critical),
        title = { Text(alert.title) },
        text = { Text(listOfNotNull(alert.body, if (busy) "Requesting sleep…" else outcome?.label).joinToString("\n\n")) },
        confirmButton = {
            TextButton(onClick = { requested = true }, enabled = !busy && outcome != SleepOutcome.GOING_TO_SLEEP) { Text("Sleep now") }
        },
        dismissButton = {
            if (critical) TextButton(onClick = { confirmIgnore = true }) { Text("Ignore for 5 minutes") }
            else TextButton(onClick = dismiss) { Text("Dismiss") }
        },
    )
    if (critical && confirmIgnore) AlertDialog(
        onDismissRequest = { confirmIgnore = false },
        title = { Text("Silence the alarm?") },
        text = { Text("Your Mac is still critically hot. Silence the alarm for five minutes?") },
        confirmButton = { TextButton(onClick = { CriticalHeatAlerts.snooze(context, alert); onClose() }) { Text("Ignore for 5 minutes") } },
        dismissButton = { TextButton(onClick = { confirmIgnore = false }) { Text("Cancel") } },
    )
}

/** Only immutable notification PendingIntents may enter this activity. */
class MacAlertActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val macId = intent.getStringExtra("macId") ?: return finish()
        val key = intent.getStringExtra("incidentId") ?: return finish()
        if (intent.action == ACTION_ALARM || intent.action == ACTION_IGNORE) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            runCatching { CriticalHeatAlerts.restore(this) }
        }
        setContent {
            MaterialTheme {
                if (intent.action == ACTION_ALARM || intent.action == ACTION_IGNORE) {
                    val alert by CriticalHeatAlerts.state.collectAsState()
                    val match = alert?.takeIf { it.macId == macId && it.incidentId == key }
                    if (match != null) CriticalHeatDialog(match, confirmIgnoreOnOpen = intent.action == ACTION_IGNORE) { finish() }
                    else LaunchedEffect(Unit) { finish() }
                } else if (intent.action == ACTION_SLEEP) {
                    SleepResultDialog(macId, initialRequest = savedInstanceState == null) { finish() }
                } else LaunchedEffect(Unit) { finish() }
            }
        }
    }

    override fun onStop() {
        val dashboard = io.github.gbettineschi.keepressomobile.Companion
        if (!isChangingConfigurations && !dashboard.dashboardVisible) dashboard.service?.foreground(false)
        super.onStop()
    }

    companion object {
        const val ACTION_ALARM = "io.github.gbettineschi.keepressomobile.SHOW_CRITICAL"
        const val ACTION_IGNORE = "io.github.gbettineschi.keepressomobile.CONFIRM_IGNORE_CRITICAL"
        const val ACTION_SLEEP = "io.github.gbettineschi.keepressomobile.REQUEST_SLEEP"
    }
}

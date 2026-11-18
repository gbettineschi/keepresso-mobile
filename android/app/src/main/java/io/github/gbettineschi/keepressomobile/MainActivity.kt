package io.github.gbettineschi.keepressomobile

import android.Manifest
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.sp
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import android.provider.Settings
import kotlin.math.roundToInt
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import io.github.gbettineschi.keepressomobile.core.*
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlinx.coroutines.delay
import kotlinx.serialization.json.*

// Configuration changes retain the short-lived QR secret in memory only.
// Deliberately do not use saved state: process death requires a fresh scan.
class PairingPermissionState : ViewModel() { var invitation: String? = null }

class MainActivity : ComponentActivity() {
    private var foregroundVisit by mutableIntStateOf(0)
    private val pendingPairing by lazy { ViewModelProvider(this)[PairingPermissionState::class.java] }
    private val permissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        if (requiredBluetooth().all { result[it] == true || ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED }) {
            val invitation=pendingPairing.invitation;pendingPairing.invitation=null
            startNearby(if(invitation!=null) "pair" else null,invitation)
            if(invitation==null && Companion.state.value.pairedName==null) Companion.update { it.copy(result="Nearby access enabled. Scan the Mac's pairing QR to continue.") }
            else if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) Companion.update { it.copy(result = "Notifications are disabled in Android Settings. Foreground status still works; reminders need notification permission.") }
        }
        else { startNearby();Companion.update { it.copy(result = "Nearby access denied. Tap Enable nearby access to continue pairing. Configured internet access still works while this app is open.") } }
    }
    private val scanner = registerForActivityResult(ScanContract()) { result -> result.contents?.let(::pair) }
    private fun requiredBluetooth(): Array<String> = NearbyPermissions.required()
    private fun startNearby(action: String? = null, invitation: String? = null) {
        val nearbyAllowed = requiredBluetooth().all { ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED }
        if (action == "pair" && !nearbyAllowed) { Companion.update { it.copy(result = "Enable nearby access before pairing") }; return }
        val intent = Intent(this, NearbyService::class.java).setAction(action).putExtra("invitation", invitation).putExtra("foreground", true)
        if (nearbyAllowed) ContextCompat.startForegroundService(this, intent) else startService(intent)
    }
    private fun pair(text: String) {
        if(runCatching{Invitation.parse(text,Instant.now().epochSecond)}.isFailure){pendingPairing.invitation=null;Companion.update{it.copy(result="Invalid or expired pairing invitation")};return}
        Companion.update{it.copy(result=null,connection="Starting secure pairing…")}
        if(requiredBluetooth().any{ContextCompat.checkSelfPermission(this,it)!=PackageManager.PERMISSION_GRANTED}){
            pendingPairing.invitation=text;permissions.launch(requiredBluetooth())
        }else{pendingPairing.invitation=null;startNearby("pair",text)}
    }
    private fun acknowledgeAwakeHistory(value: Intent) {
        if (value.action != AwakeAlertReceiver.OPEN_HISTORY) return
        val mac = value.getStringExtra("macId") ?: return
        val incident = value.getStringExtra("incidentId") ?: return
        val event = value.getStringExtra("eventId") ?: return
        runCatching { LidAlert.dismiss(this, mac, incident, event, historical = true) }
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        acknowledgeAwakeHistory(intent)
    }
    override fun onStart() {
        super.onStart()
        Companion.dashboardVisible = true
        acknowledgeAwakeHistory(intent)
        runCatching { CriticalHeatAlerts.restore(this) }
        runCatching { LidAlert.restore(this) }
        foregroundVisit++
        if (Companion.service != null) Companion.service?.foreground(true)
        else if (runCatching { CredentialStore(this).load() }.getOrNull() != null) startNearby("foreground")
    }
    override fun onStop() {
        Companion.dashboardVisible = false
        if (!isChangingConfigurations) Companion.service?.foreground(false)
        super.onStop()
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val restored = runCatching { CredentialStore(this).load() }.getOrNull()
        restored?.let { saved ->
            Companion.update { it.copy(pairedName = saved.name, macId = saved.macId, localSnoozedUntil = PhoneReminders.until(this, saved.macId)) }
        }
        setContent {
            val dark = isSystemInDarkTheme()
            val accent = if (dark) Color(0xFFD98F52) else Color(0xFFA64B23)
            val colors = if (dark) darkColorScheme(primary = accent, background = Color(0xFF211B17), surface = Color(0xFF302720), onPrimary = Color(0xFF2D1B10), secondaryContainer = Color(0xFF493126)) else lightColorScheme(primary = accent, background = Color(0xFFF6F3EF), surface = Color.White, onPrimary = Color.White, secondaryContainer = Color(0xFFF5E7DF))
            MaterialTheme(colorScheme = colors) {
                KeepressoApp(foregroundVisit, onEnable = { val p = requiredBluetooth().toMutableList(); if (Build.VERSION.SDK_INT >= 33) p += Manifest.permission.POST_NOTIFICATIONS; permissions.launch(p.toTypedArray()) }, onConnect = { startNearby() }, onScan = { scanner.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE).setPrompt("Scan the pairing QR on your Mac").setBeepEnabled(false)) }, onPair = ::pair, onReset = { startNearby("reset") })
            }
        }
    }
}

private fun JsonObject?.section(key: String): JsonObject? = this?.get(key)?.takeUnless { it == JsonNull }?.jsonObject
private fun JsonObject?.text(key: String): String? = this?.stringOrNull(key)
private fun JsonObject?.flag(key: String): Boolean? = this?.boolOrNull(key)
private fun JsonObject?.number(key: String): Double? = this?.get(key)?.takeUnless { it == JsonNull }?.jsonPrimitive?.doubleOrNull
private fun readable(value: String?): String = value?.takeUnless { it == "unknown" }?.replaceFirstChar { it.uppercase() } ?: "Unknown"
private fun time(value: Instant?): String {
    if (value == null) return "Never"
    val sameDay = value.atZone(ZoneId.systemDefault()).toLocalDate() == Instant.now().atZone(ZoneId.systemDefault()).toLocalDate()
    return DateTimeFormatter.ofPattern(if (sameDay) "HH:mm:ss" else "dd MMM, HH:mm").withZone(ZoneId.systemDefault()).format(value)
}
private fun triggerTime(value: Instant): String {
    val sameDay = value.atZone(ZoneId.systemDefault()).toLocalDate() == Instant.now().atZone(ZoneId.systemDefault()).toLocalDate()
    return DateTimeFormatter.ofPattern(if (sameDay) "HH:mm" else "dd MMM HH:mm").withZone(ZoneId.systemDefault()).format(value)
}
private fun parsed(value: String?): Instant? = value?.let { runCatching { Instant.parse(it) }.getOrNull() }
private fun duration(minutes: Long): String = if (minutes >= 60) "${minutes / 60}h ${minutes % 60}m" else "${minutes}m"

internal enum class MacConnectionStatus(val label: String) {
    AWAKE("Awake"), UPDATING("Updating…"), UNREACHABLE("Unreachable")
}

@Composable private fun KeepressoApp(foregroundVisit: Int, onEnable: () -> Unit, onConnect: () -> Unit, onScan: () -> Unit, onPair: (String) -> Unit, onReset: () -> Unit) {
    val state by Companion.state.collectAsState()
    var now by remember { mutableStateOf(Instant.now()) }
    LaunchedEffect(Unit) { while (true) { now = Instant.now(); delay(1000) } }
    var tab by remember { mutableIntStateOf(0) }
    var confirmation by remember { mutableStateOf<String?>(null) }
    var sleepRequested by remember { mutableStateOf(false) }
    var outcomeDetails by remember { mutableStateOf<String?>(null) }
    val commandMessages = remember { SnackbarHostState() }
    val criticalAlert by CriticalHeatAlerts.state.collectAsState()
    val feedback = state.result?.takeIf { message ->
        state.pairedName != null && message != "Sending…" && SleepOutcome.entries.none { it.label == message }
    }
    LaunchedEffect(state.macId, feedback) {
        if (feedback != null) {
            val summary = if (feedback.contains("uncertain", ignoreCase = true)) {
                "Command outcome uncertain. Never retried automatically."
            } else feedback
            val selected = commandMessages.showSnackbar(
                message = summary,
                actionLabel = "Details",
                withDismissAction = true,
                duration = SnackbarDuration.Long,
            )
            if (selected == SnackbarResult.ActionPerformed) outcomeDetails = feedback
        }
    }
    // The one-second display clock may predate a response received this frame.
    val reachable = state.reachable(Instant.now())
    // Internet status pauses in the background, so reopening gets a new wait.
    val lossGraceElapsed = remember(state.macId, state.pairedName, reachable, foregroundVisit) { mutableStateOf(false) }
    if (state.pairedName != null && !reachable) {
        LaunchedEffect(lossGraceElapsed) {
            delay(6_000)
            lossGraceElapsed.value = true
        }
    }
    val connectionStatus = when {
        reachable -> MacConnectionStatus.AWAKE
        !lossGraceElapsed.value -> MacConnectionStatus.UPDATING
        else -> MacConnectionStatus.UNREACHABLE
    }
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(commandMessages) },
        bottomBar = {
            NavigationBar { listOf("Status" to Icons.Default.LaptopMac, "Activity" to Icons.AutoMirrored.Filled.List, "Settings" to Icons.Default.Settings).forEachIndexed { i, (name, icon) -> NavigationBarItem(selected = tab == i, onClick = { tab = i }, icon = { Icon(icon, contentDescription = name) }, label = { Text(name) }) } }
        },
    ) { insets ->
        Column(Modifier.padding(insets).fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(Modifier.fillMaxWidth().padding(top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Image(painterResource(R.drawable.keepresso_installed_icon), null, Modifier.size(32.dp))
                Spacer(Modifier.width(10.dp)); Text("Keepresso Mobile", style = MaterialTheme.typography.titleLarge.copy(fontSize=20.sp),modifier=Modifier.weight(1f),maxLines=1)
                IconButton(onClick = { Companion.service?.send("status") }, enabled = state.authenticated) { Icon(Icons.Default.Refresh, "Refresh Mac status") }
            }
            if (state.pairedName == null) Pairing(state,onEnable, onScan, onPair)
            when (tab) {
                0 -> if(state.pairedName!=null) StatusScreen(state, now, connectionStatus) { confirmation = it }
                1 -> {
                    Text("Activity", style = MaterialTheme.typography.headlineMedium)
                    if (state.activity.isEmpty()) Text("No activity yet", style = MaterialTheme.typography.bodyMedium)
                    state.activity.forEach { Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(14.dp)) { Text(time(it.time), style = MaterialTheme.typography.labelSmall); Text(it.text, style = MaterialTheme.typography.bodyMedium) }; HorizontalDivider() }
                }
                else -> SettingsScreen(state, connectionStatus, onEnable, onConnect) { confirmation = "reset" }
            }
            Spacer(Modifier.height(12.dp))
        }
    }
    outcomeDetails?.let { feedback ->
        AlertDialog(onDismissRequest = { outcomeDetails = null },
            title = { Text("Command outcome") },
            text = { Text(feedback, modifier = Modifier.verticalScroll(rememberScrollState())) },
            confirmButton = { TextButton(onClick = { outcomeDetails = null }) { Text("Close") } })
    }
    confirmation?.let { action ->
        val title = when (action) { "resume_triggers" -> "Resume triggers?"; "reset" -> "Remove this phone's authorization?"; else -> "Put ${state.pairedName ?: "Mac"} to sleep?" }
        val body = when (action) { "resume_triggers" -> "The manual timer will end and triggers take control immediately. Conditions can change; no match or a grace-only result may allow your Mac to sleep and become unreachable."; "reset" -> "This clears the key on this phone. Also revoke the phone in the Mac helper to remove authorization on the Mac."; else -> "Stop relevant Keepresso holds and pause triggers before requesting sleep. Running work may pause and the Mac may become unreachable. A disconnection alone does not confirm sleep." }
        AlertDialog(onDismissRequest = { confirmation = null }, title = { Text(title) }, text = { Text(body) }, confirmButton = { TextButton(onClick = {
            when (action) {
                "reset" -> onReset()
                "sleep_now" -> sleepRequested = true
                else -> Companion.service?.send(action)
            }
            confirmation = null
        }) { Text(if (action == "sleep_now") "Sleep now" else if (action == "reset") "Remove" else "Resume triggers") } }, dismissButton = { TextButton(onClick = { confirmation = null }) { Text("Cancel") } })
    }
    criticalAlert?.takeIf { it.macId == state.macId }?.let { CriticalHeatDialog(it) {} }
    if (sleepRequested) state.macId?.let { SleepResultDialog(it) { sleepRequested = false } }
}
@Composable private fun Pairing(state:UiState,onEnable: () -> Unit, onScan: () -> Unit, onPair: (String) -> Unit) {
    var pasted by remember { mutableStateOf("") }
    Text("Authorize this phone", style = MaterialTheme.typography.titleMedium)
    Text("Open pairing in the Mac helper, scan its one-time QR, then approve this phone locally on your Mac.", style = MaterialTheme.typography.bodySmall)
    Text(state.connection,style=MaterialTheme.typography.bodyMedium)
    state.result?.let{Text(it,style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.error)}
    Row { Button(onClick = onEnable) { Text("Enable nearby access") }; TextButton(onClick = onScan) { Text("Scan QR") } }
    OutlinedTextField(value = pasted, onValueChange = { pasted = it.take(2048) }, label = { Text("Or paste pairing invitation") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
    TextButton(onClick = { onPair(pasted); pasted = "" }, enabled = pasted.isNotBlank()) { Text("Pair with Mac") }
}
@Composable private fun Fact(label: String, value: String, modifier: Modifier = Modifier, severity: String? = null, icon:ImageVector?=null,iconLabel:String?=null,valueMaxLines:Int=1) {
    val color = when (severity) { "warm" -> if (isSystemInDarkTheme()) Color(0xFFF5CB5B) else Color(0xFF8A6100); "hot" -> if (isSystemInDarkTheme()) Color(0xFFFF9D90) else Color(0xFFB3332B); else -> MaterialTheme.colorScheme.onSurface }
    Column(modifier) {
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(5.dp))
        Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(6.dp)){
            Text(value, style = MaterialTheme.typography.bodyMedium,fontWeight=FontWeight.Normal,color=color,minLines=valueMaxLines,maxLines=valueMaxLines,overflow=TextOverflow.Ellipsis)
            icon?.let{Icon(it,iconLabel,Modifier.size(16.dp),tint=color)}
        }
    }
}
@Composable internal fun StatusScreen(state: UiState, now: Instant, connectionStatus: MacConnectionStatus, confirm: (String) -> Unit) {
    val snapshot = state.snapshot; val mac = snapshot.section("mac"); val k = snapshot.section("keepresso"); val triggers = state.triggerHistory.assessment ?: snapshot.section("triggers"); val caps = snapshot.section("capabilities"); val reminders = snapshot.section("reminders")
    val reachable = connectionStatus == MacConnectionStatus.AWAKE
    var showThermalDetails by rememberSaveable(state.macId) { mutableStateOf(false) }
    val thermalState = mac.text("thermalSeverity")
    if (showThermalDetails) ThermalDetails(mac.flag("thermalGuardActive"), reachable) { showThermalDetails = false }
    val can: (String) -> Boolean = { name -> reachable && !state.busy && caps.flag(name) == true }
    Text(state.pairedName ?: "Your Mac", style = MaterialTheme.typography.labelMedium)
    Text(connectionStatus.label, style = MaterialTheme.typography.headlineLarge)
    val recoveryMessage = state.nearbyRecoveryIssue?.compactMessage
    val contact = when {
        reachable -> "Updated at ${time(state.lastContact)} · ${state.transport}\n${recoveryMessage.orEmpty()}"
        state.lastContact == null && connectionStatus == MacConnectionStatus.UPDATING -> "Waiting for Mac status\n${recoveryMessage.orEmpty()}"
        state.lastContact == null -> "No Mac status received\n${recoveryMessage.orEmpty()}"
        recoveryMessage != null -> "Last contact ${time(state.lastContact)} · Last known\n$recoveryMessage"
        else -> "Last contact ${time(state.lastContact)}\nReadings below are last known"
    }
    Text(contact, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, minLines = 2, maxLines = 2)
    HorizontalDivider()
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Fact("Lock", readable(mac.text("lock")), modifier = Modifier.weight(1f))
        Fact("Display", readable(mac.text("display")), modifier = Modifier.weight(1f))
        Fact("Lid", readable(mac.text("lid")), modifier = Modifier.weight(1f))
    }
    HorizontalDivider()
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        val battery=mac.number("batteryPercent")
        val charging=mac.flag("isCharging")==true
        Fact("Battery",battery?.let{"${it.roundToInt()}%"} ?: "—",modifier=Modifier.weight(1f),severity=when{battery==null->null;battery<=10->"hot";battery<=20->"warm";else->null},icon=if(charging)Icons.Default.Bolt else if(mac.text("powerSource")=="ac")Icons.Default.Power else null,iconLabel=if(charging)"Charging" else "External power")
        Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically) {
            Fact(
                "Thermal state", readable(thermalState),
                modifier = Modifier.weight(1f).semantics(mergeDescendants = true) {},
                severity = when (thermalState) { "fair" -> "warm"; "serious", "critical" -> "hot"; else -> null },
            )
            IconButton(onClick = { showThermalDetails = true }) {
                Icon(
                    Icons.Outlined.Info, contentDescription = "Thermal info",
                    modifier = Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        val checked=parsed(mac.text("internetCheckedAt"))
        val serverNow=now.plusSeconds(state.serverOffsetSeconds)
        val fresh=checked?.let{it>=serverNow.minusSeconds(45) && it<=serverNow.plusSeconds(10)}==true
        val internet=mac.text("internet").let{if(it=="checking" || fresh)it else "unknown"}
        Fact("Internet",when(internet){"online"->"Online";"offline"->"Offline";"check_failed"->"Check failed";"checking"->"Checking…";else->"Not checked"},modifier=Modifier.weight(1f).semantics{contentDescription="Mac internet"},severity=when(internet){"offline"->"hot";"check_failed"->"warm";else->null})
        val network=mac.text("networkType")
        val wifiName=mac.text("wifiName")?.map{if(it.isISOControl())' ' else it}?.joinToString("")?.takeIf{it.isNotBlank()}
        Fact(if(network=="wifi")"Wi-Fi" else "Network",when(network){"wifi"->wifiName ?: "Name unavailable";"ethernet"->"Ethernet";"cellular"->"Cellular";"other"->"Other connection";"none"->"Disconnected";else->"Unknown"},modifier=Modifier.weight(1f),valueMaxLines=2)
    }
    HorizontalDivider()
    val active = k.flag("isActive"); val manual = k.text("sessionKind") == "manual" && active == true
    val safetyPause = k.text("safetyPause")
    val batteryPaused = safetyPause == "battery"
    val thermalPaused = safetyPause == "thermal"
    val cup = if (batteryPaused) { if (isSystemInDarkTheme()) R.drawable.keepresso_menu_low_battery_dark else R.drawable.keepresso_menu_low_battery_light } else if (active == true && !thermalPaused) R.drawable.keepresso_menu_brewing else R.drawable.keepresso_menu_idle
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface), modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(17.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Image(painterResource(cup), when { batteryPaused -> "Battery safety pause"; thermalPaused -> "Thermal safety pause"; active == true -> "Brewing"; else -> "Idle" }, Modifier.size(30.dp), colorFilter = if (batteryPaused) null else ColorFilter.tint(MaterialTheme.colorScheme.primary))
                Spacer(Modifier.width(8.dp)); Text("Brewing session", style = MaterialTheme.typography.titleSmall); Spacer(Modifier.weight(1f))
                if (!thermalPaused) Text(when(active) { true -> "Running"; false -> "Not running"; null -> "Unknown" }, style = MaterialTheme.typography.labelSmall)
            }
            val end = parsed(k.text("endsAt")); val remaining = end?.let { java.time.Duration.between(now.plusSeconds(state.serverOffsetSeconds), it).toMinutes().coerceAtLeast(0) }
            Text(when { batteryPaused || thermalPaused -> "Paused"; manual && remaining != null -> "${duration(remaining)} remaining"; active == true -> "Active"; active == false -> "Inactive"; else -> "Unknown" }, style = MaterialTheme.typography.headlineSmall, minLines = 1, maxLines = 1)
            Text(when { batteryPaused -> "Paused for low battery."; thermalPaused -> "Paused for heat."; manual -> "Manual session. Triggers are paused."; active == true -> when (k.text("sessionKind")) { "automatic" -> "Automatic trigger session."; "lease" -> "Companion session."; "manual" -> "Manual session."; else -> "Session kind unknown." }; active == false -> if (k.flag("triggersPaused") == true) "No manual session. Triggers are paused." else "No active brewing session."; else -> "Session status unavailable." }, style = MaterialTheme.typography.bodySmall, minLines = 2, maxLines = 2)
        }
    }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        val checked = parsed(triggers.text("checkedAt")); val status = if(state.checkingTriggers)"checking" else triggers.text("state")
        Text("Active triggers",style=MaterialTheme.typography.titleSmall,modifier=Modifier.weight(1f),minLines=1,maxLines=1,overflow=TextOverflow.Ellipsis)
        Text(when{status=="checking"->"Checking…";checked==null->"Not checked";else->"Checked ${triggerTime(checked)}"},style=MaterialTheme.typography.labelSmall,color=MaterialTheme.colorScheme.onSurfaceVariant,minLines=1,maxLines=1,modifier=Modifier.semantics{contentDescription=if(checked==null)"Triggers not checked" else "Triggers checked at ${time(checked)}${if(state.triggerHistory.outdated || state.triggerHistory.checkError!=null || status in setOf("stale","error") || !reachable) ", stale" else ""}"})
        TextButton(onClick = { Companion.service?.send("refresh_triggers") }, enabled = can("refreshTriggers") && !state.checkingTriggers,contentPadding=PaddingValues(horizontal=8.dp)) { Text("Check") }
    }
    val rules = triggers?.get("rules")?.jsonArray?.map { it.jsonObject }.orEmpty()
    rules.forEach { rule ->
        val label=rule.text("label") ?: "Trigger"
        val known=rule.flag("satisfied")
        Row(Modifier.fillMaxWidth().padding(vertical=3.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(10.dp)){
            val verdict=when(known){true->if(rule.flag("inGrace")==true)"Active in grace period" else "Active";false->"Inactive";null->"Not confirmed"}
            Icon(if(known==null)Icons.Default.HelpOutline else if(known)Icons.Default.CheckCircle else Icons.Default.RadioButtonUnchecked,"$label: $verdict",Modifier.size(20.dp),tint=if(known==true)Color(0xFF169B62) else MaterialTheme.colorScheme.onSurfaceVariant)
            Text(label,style=MaterialTheme.typography.bodyMedium,modifier=Modifier.weight(1f),minLines=1,maxLines=1,overflow=TextOverflow.Ellipsis)
        }
    }
    val checkError = state.triggerHistory.checkError?.let { if (it == "Mac is busy. Tap Check again.") it else "Couldn't check triggers" }
    val triggerFeedback = when {
        checkError != null -> "${checkError.trimEnd('.')}. ${if(parsed(triggers.text("checkedAt"))!=null) "Showing previous result." else "Tap Check to try again."}"
        triggers.text("state") == "error" -> "Couldn't check triggers"
        state.triggerHistory.outdated || triggers.flag("outdated") == true || triggers.text("state") == "stale" -> "Rules or Keepresso changed. Check again."
        triggers.text("state") == "unknown" -> "Some trigger inputs are unavailable."
        !reachable && parsed(triggers.text("checkedAt")) != null -> "Showing the last checked result."
        else -> ""
    }
    Text(triggerFeedback,style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant,minLines=2,maxLines=2)
    val paused = k.flag("triggersPaused")
    val triggerCapability = if (paused == true) "resumeTriggers" else "pauseTriggers"
    FilledTonalButton(modifier = Modifier.fillMaxWidth(), onClick = { if (paused == true) confirm("resume_triggers") else Companion.service?.send("pause_triggers") }, enabled = paused != null && can(triggerCapability)) { Text(if (paused == true) "Resume triggers" else "Pause triggers") }
    Text(if (reachable && caps.flag(triggerCapability) != true) "Trigger control unavailable. Check the Mac helper and permissions." else "", style = MaterialTheme.typography.labelSmall, minLines=2, maxLines=2)
    HorizontalDivider()
    if (manual) Button(onClick = { Companion.service?.send("stop_manual") }, enabled = can("stopManual"), modifier = Modifier.fillMaxWidth()) { Text("Stop manual session") }
    else {
        var minutes by remember { mutableIntStateOf(120) }
        Text("Manual session", style = MaterialTheme.typography.titleSmall)
        Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically) {
            Row(verticalAlignment=Alignment.CenterVertically){
                IconButton(onClick={minutes-=15},enabled=minutes>15,modifier=Modifier.size(40.dp)){Icon(Icons.Default.Remove,"Decrease duration",Modifier.size(18.dp))}
                Text(duration(minutes.toLong()),style=MaterialTheme.typography.bodyMedium,fontFamily=FontFamily.Monospace,modifier=Modifier.width(70.dp),textAlign=androidx.compose.ui.text.style.TextAlign.Center,maxLines=1)
                IconButton(onClick={minutes+=15},enabled=minutes<10080,modifier=Modifier.size(40.dp)){Icon(Icons.Default.Add,"Increase duration",Modifier.size(18.dp))}
            }
            Spacer(Modifier.weight(1f).widthIn(min=16.dp))
            Button(onClick = { Companion.service?.send("start_manual", minutes) }, enabled = can("startManual") && !batteryPaused, modifier = Modifier.width(88.dp)) { Text("Start") }
        }
    }
    Text(if (reachable && caps.flag(if (manual) "stopManual" else "startManual") != true) "Manual control unavailable. Check Keepresso and the Mac helper." else "", style = MaterialTheme.typography.labelSmall, minLines=2, maxLines=2)
    TextButton(onClick = { confirm("sleep_now") }, enabled = can("sleepNow"), modifier = Modifier.fillMaxWidth()) { Icon(Icons.Default.Bedtime, null); Spacer(Modifier.width(8.dp)); Text("Sleep now") }
    Text(when { state.localSnoozedUntil?.isAfter(now) == true -> "Reminders snoozed on this phone until ${time(state.localSnoozedUntil)}"; reminders.text("snoozedUntil") != null -> "Reminders snoozed until ${time(parsed(reminders.text("snoozedUntil")))}"; reminders.flag("enabled") == false -> "Unattended brewing alert off"; reminders.flag("enabled") == true -> "Unattended brewing alert on"; else -> "Reminder status unknown" }, style = MaterialTheme.typography.labelSmall, minLines=2, maxLines=2)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable private fun ThermalDetails(guardActive: Boolean?, reachable: Boolean, onDismiss: () -> Unit) {
    val uriHandler = LocalUriHandler.current
    var linkFailed by remember { mutableStateOf(false) }
    val guardState = when (guardActive) {
        true -> "Active"
        false -> "Inactive"
        null -> "Unknown"
    }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(start = 24.dp, end = 24.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Thermal details", style = MaterialTheme.typography.headlineSmall)
            val guardReading = if (!reachable && guardActive != null) "$guardState · last known" else guardState
            Fact("Keepresso heat guard", guardReading)
            HorizontalDivider()
            Text("As thermal stress rises, macOS may reduce performance to cool the Mac.", style = MaterialTheme.typography.bodyMedium)
            TextButton(onClick = {
                linkFailed = runCatching {
                    uriHandler.openUri("https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/RespondToThermalStateChanges.html")
                }.isFailure
            }) { Text("About macOS thermal states") }
            if (linkFailed) Text("Couldn’t open Apple’s documentation.", color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Composable private fun SettingsScreen(state: UiState, connectionStatus: MacConnectionStatus, onEnable: () -> Unit, onConnect: () -> Unit, onReset: () -> Unit) {
    val context=LocalContext.current
    val reachable = connectionStatus == MacConnectionStatus.AWAKE
    val r = state.snapshot.section("reminders")
    val currentEnabled = r.flag("enabled"); val currentInterval = r.number("intervalSeconds")?.toInt(); val currentDelay = r.number("endedAwakeDelaySeconds")?.toInt()
    fun save(enabled: Boolean) {
        Companion.service?.send("set_reminder_settings", settings = ReminderSettings(enabled, currentInterval ?: 3600, currentDelay ?: 300))
    }
    Text("Settings",style=MaterialTheme.typography.headlineMedium)
    SettingsGroup("Connection"){
        Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(10.dp)){
            Icon(Icons.Default.LaptopMac,null,tint=MaterialTheme.colorScheme.primary)
            Column{Text(state.pairedName ?: "No Mac authorized",style=MaterialTheme.typography.titleMedium);Text(if(reachable)state.transport else if(state.pairedName != null) connectionStatus.label else "Not connected",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)}
        }
        Text(state.nearbyRecoveryIssue?.message.orEmpty(),style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant,minLines=2,maxLines=2)
        Text(if(state.internetConfigured)"Internet fallback enabled" else "Internet is set up on your Mac.",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
        Row(horizontalArrangement=Arrangement.spacedBy(8.dp)){TextButton(onClick=onEnable){Text("Permissions")};TextButton(onClick=onConnect){Text("Reconnect")}}
    }
    SettingsGroup("Reminders"){
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Unattended brewing alert", style = MaterialTheme.typography.bodyMedium)
                Text("Notify after one hour of unattended brewing.", style = MaterialTheme.typography.bodySmall)
            }
            Switch(checked = currentEnabled == true, onCheckedChange = ::save, enabled = reachable && !state.busy && currentEnabled != null,
                modifier = Modifier.semantics { contentDescription = "Unattended brewing alert" })
        }
        val snoozed=state.localSnoozedUntil?.takeIf{it.isAfter(Instant.now())} ?: parsed(r.text("snoozedUntil"))?.takeIf{it.isAfter(Instant.now())}
        snoozed?.let{Text("Snoozed until ${time(it)}",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)}
        Row(horizontalArrangement=Arrangement.spacedBy(8.dp)){TextButton(onClick={Companion.service?.send("snooze_reminders")},enabled=reachable && !state.busy){Text("Snooze 6 hours")};if(snoozed!=null)TextButton(onClick={Companion.service?.send("resume_reminders")},enabled=reachable && !state.busy){Text("Resume")}}
    }
    SettingsGroup("Warning alerts"){WarningAlertSettings()}

    TextButton(onClick=onReset,enabled=state.pairedName!=null,colors=ButtonDefaults.textButtonColors(contentColor=MaterialTheme.colorScheme.error)){Text("Remove phone authorization")}
}
@Composable private fun SettingsGroup(title:String,content:@Composable ColumnScope.()->Unit){
    Card(Modifier.fillMaxWidth(),colors=CardDefaults.cardColors(containerColor=MaterialTheme.colorScheme.surface)){
        Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)){Text(title,style=MaterialTheme.typography.titleSmall,color=MaterialTheme.colorScheme.primary);content()}
    }
}

/** Notification actions use an unexported activity, so external apps cannot forge them.
 * Opening directly also avoids Android's notification-trampoline restriction. */
class ReminderActionActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Companion.service?.foreground(true)
        val action = intent.action?.takeIf { it in setOf("ack", "snooze") }
        val macId = intent.getStringExtra("macId")
        if (action != null && macId != null) {
            getSystemService(NotificationManager::class.java).cancel(intent.getIntExtra("notificationId", 0))
            if (action == "snooze") PhoneReminders.filter(this).snooze(macId, Instant.now())
            if (Companion.state.value.macId == macId && Companion.state.value.reachable(Instant.now())) Companion.service?.send(if (action == "snooze") "snooze_reminders" else "ack_reminder")
            else Companion.activity(if (action == "snooze") "Routine reminders snoozed locally for 6 hours; Mac unreachable" else "Reminder dismissed locally; Mac unreachable")
        }
        startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        finish()
    }
}

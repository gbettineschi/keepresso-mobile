package io.github.gbettineschi.keepressomobile

import android.Manifest
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
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import io.github.gbettineschi.keepressomobile.core.*
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlinx.coroutines.delay
import kotlinx.serialization.json.*

class MainActivity : ComponentActivity() {
    private val permissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        if (requiredBluetooth().all { result[it] == true || ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED }) startNearby()
        else Companion.update { it.copy(connection = "Nearby Devices permission denied. Enable it in Android Settings to connect.") }
    }
    private val scanner = registerForActivityResult(ScanContract()) { result -> result.contents?.let(::pair) }
    private fun requiredBluetooth(): Array<String> = if (Build.VERSION.SDK_INT >= 31) arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT) else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
    private fun startNearby(action: String? = null, invitation: String? = null) {
        if (requiredBluetooth().any { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }) { Companion.update { it.copy(result = "Enable nearby access before pairing") }; return }
        ContextCompat.startForegroundService(this, Intent(this, NearbyService::class.java).setAction(action).putExtra("invitation", invitation))
    }
    private fun pair(text: String) { startNearby("pair", text) }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            val dark = isSystemInDarkTheme()
            val accent = if (dark) Color(0xFFD98F52) else Color(0xFFA64B23)
            val colors = if (dark) darkColorScheme(primary = accent, background = Color(0xFF211B17), surface = Color(0xFF302720), onPrimary = Color(0xFF2D1B10), secondaryContainer = Color(0xFF493126)) else lightColorScheme(primary = accent, background = Color(0xFFF6F3EF), surface = Color.White, onPrimary = Color.White, secondaryContainer = Color(0xFFF5E7DF))
            MaterialTheme(colorScheme = colors) {
                KeespressoApp(onEnable = { val p = requiredBluetooth().toMutableList(); if (Build.VERSION.SDK_INT >= 33) p += Manifest.permission.POST_NOTIFICATIONS; permissions.launch(p.toTypedArray()) }, onConnect = { startNearby() }, onScan = { scanner.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE).setPrompt("Scan the pairing QR on your Mac").setBeepEnabled(false)) }, onPair = ::pair, onReset = { startNearby("reset") })
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
private fun parsed(value: String?): Instant? = value?.let { runCatching { Instant.parse(it) }.getOrNull() }
private fun duration(minutes: Long): String = if (minutes >= 60) "${minutes / 60}h ${minutes % 60}m" else "${minutes}m"

@Composable private fun KeespressoApp(onEnable: () -> Unit, onConnect: () -> Unit, onScan: () -> Unit, onPair: (String) -> Unit, onReset: () -> Unit) {
    val state by Companion.state.collectAsState()
    var now by remember { mutableStateOf(Instant.now()) }
    LaunchedEffect(Unit) { while (true) { now = Instant.now(); delay(1000) } }
    var tab by remember { mutableIntStateOf(0) }
    var confirmation by remember { mutableStateOf<String?>(null) }
    val reachable = state.reachable(now)
    Scaffold(containerColor = MaterialTheme.colorScheme.background, bottomBar = {
        NavigationBar { listOf("Status" to Icons.Default.LaptopMac, "Activity" to Icons.AutoMirrored.Filled.List, "Settings" to Icons.Default.Settings).forEachIndexed { i, (name, icon) -> NavigationBarItem(selected = tab == i, onClick = { tab = i }, icon = { Icon(icon, contentDescription = name) }, label = { Text(name) }) } }
    }) { insets ->
        Column(Modifier.padding(insets).fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(Modifier.fillMaxWidth().padding(top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Image(painterResource(R.drawable.keepresso_installed_icon), "Original Keepresso icon", Modifier.size(40.dp))
                Spacer(Modifier.width(10.dp)); Text("Keespresso", style = MaterialTheme.typography.titleLarge)
                Spacer(Modifier.weight(1f)); IconButton(onClick = { Companion.service?.send("status") }, enabled = state.authenticated) { Icon(Icons.Default.Refresh, "Refresh Mac status") }
            }
            if (state.pairedName == null) Pairing(onEnable, onScan, onPair)
            when (tab) {
                0 -> StatusScreen(state, now, reachable) { confirmation = it }
                1 -> {
                    Text("Activity", style = MaterialTheme.typography.headlineMedium)
                    if (state.activity.isEmpty()) Text("No activity yet", style = MaterialTheme.typography.bodyMedium)
                    state.activity.forEach { Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(14.dp)) { Text(time(it.time), style = MaterialTheme.typography.labelSmall); Text(it.text, style = MaterialTheme.typography.bodyMedium) }; HorizontalDivider() }
                }
                else -> SettingsScreen(state, reachable, onEnable, onConnect) { confirmation = "reset" }
            }
            if (state.result != null) Text(state.result!!, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(12.dp))
        }
    }
    confirmation?.let { action ->
        val title = when (action) { "resume_triggers" -> "Resume triggers?"; "reset" -> "Remove this phone's authorization?"; else -> "Put ${state.pairedName ?: "Mac"} to sleep?" }
        val body = when (action) { "resume_triggers" -> "The manual timer will end and triggers take control immediately. Conditions can change; no match or a grace-only result may allow your Mac to sleep and become unreachable."; "reset" -> "This clears the key on this phone. Also revoke the phone in the Mac helper to remove authorization on the Mac."; else -> "Stop relevant Keepresso holds and pause triggers before requesting sleep. Running work may pause and the Mac may become unreachable. A disconnection alone does not confirm sleep." }
        AlertDialog(onDismissRequest = { confirmation = null }, title = { Text(title) }, text = { Text(body) }, confirmButton = { TextButton(onClick = { if (action == "reset") onReset() else Companion.service?.send(action); confirmation = null }) { Text(if (action == "sleep_now") "Sleep now" else if (action == "reset") "Remove" else "Resume triggers") } }, dismissButton = { TextButton(onClick = { confirmation = null }) { Text("Cancel") } })
    }
}
@Composable private fun Pairing(onEnable: () -> Unit, onScan: () -> Unit, onPair: (String) -> Unit) {
    var pasted by remember { mutableStateOf("") }
    Text("Authorize this phone", style = MaterialTheme.typography.titleMedium)
    Text("Open pairing in the Mac helper, scan its one-time QR, then approve this phone locally on your Mac.", style = MaterialTheme.typography.bodySmall)
    Row { Button(onClick = onEnable) { Text("Enable nearby access") }; TextButton(onClick = onScan) { Text("Scan QR") } }
    OutlinedTextField(value = pasted, onValueChange = { pasted = it.take(2048) }, label = { Text("Or paste pairing invitation") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
    TextButton(onClick = { onPair(pasted); pasted = "" }, enabled = pasted.isNotBlank()) { Text("Pair with Mac") }
}
@Composable private fun Fact(label: String, value: String, detail: String? = null, modifier: Modifier = Modifier, severity: String? = null) {
    val color = when (severity) { "warm" -> if (isSystemInDarkTheme()) Color(0xFFF5CB5B) else Color(0xFF8A6100); "hot" -> if (isSystemInDarkTheme()) Color(0xFFFF9D90) else Color(0xFFB3332B); else -> MaterialTheme.colorScheme.onSurface }
    Column(modifier) { Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant); Spacer(Modifier.height(5.dp)); Text(value, style = MaterialTheme.typography.bodyMedium, color = color); detail?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = color) } }
}
@Composable private fun StatusScreen(state: UiState, now: Instant, reachable: Boolean, confirm: (String) -> Unit) {
    val snapshot = state.snapshot; val mac = snapshot.section("mac"); val k = snapshot.section("keepresso"); val triggers = snapshot.section("triggers"); val caps = snapshot.section("capabilities"); val reminders = snapshot.section("reminders")
    val can: (String) -> Boolean = { name -> reachable && !state.busy && caps.flag(name) == true }
    Text(state.pairedName ?: "Your Mac", style = MaterialTheme.typography.labelMedium)
    Text(if (reachable) "Awake" else "Unreachable", style = MaterialTheme.typography.headlineLarge)
    Text(if (reachable) "Updated at ${time(state.lastContact)} · Nearby Bluetooth" else "${state.connection}\nLast contact ${time(state.lastContact)} · Readings below are last known", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    HorizontalDivider()
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Fact("Lock", readable(mac.text("lock")), modifier = Modifier.weight(1f))
        Fact("Display", readable(mac.text("display")), modifier = Modifier.weight(1f))
        Fact("Lid", readable(mac.text("lid")), modifier = Modifier.weight(1f))
    }
    HorizontalDivider()
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Fact("Battery", mac.number("batteryPercent")?.let { "${it.toInt()}%" } ?: "Unknown", when(mac.text("powerSource")) { "battery" -> "On battery"; "ac" -> "Connected to power"; else -> "Power source unknown" }, Modifier.weight(1f))
        Fact("Temperature", mac.number("temperatureC")?.let { "${"%.1f".format(it)} °C" } ?: "Unavailable", "${readable(mac.text("thermal"))} · ${mac.text("temperatureSensor") ?: "Sensor unavailable"}", Modifier.weight(1f), mac.text("thermal"))
    }
    HorizontalDivider()
    val active = k.flag("isActive"); val manual = k.text("sessionKind") == "manual" && active == true
    val batteryPaused = k.text("safetyPause") == "battery"
    val cup = if (batteryPaused) { if (isSystemInDarkTheme()) R.drawable.keepresso_menu_low_battery_dark else R.drawable.keepresso_menu_low_battery_light } else if (active == true) R.drawable.keepresso_menu_brewing else R.drawable.keepresso_menu_idle
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface), modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(17.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Image(painterResource(cup), if (batteryPaused) "Battery safety pause" else if (active == true) "Brewing" else "Idle", Modifier.size(30.dp), colorFilter = if (batteryPaused) null else ColorFilter.tint(MaterialTheme.colorScheme.primary))
                Spacer(Modifier.width(8.dp)); Text("Brewing session", style = MaterialTheme.typography.titleSmall); Spacer(Modifier.weight(1f))
                Text(when(active) { true -> "Running"; false -> "Not running"; null -> "Unknown" }, style = MaterialTheme.typography.labelSmall)
            }
            val end = parsed(k.text("endsAt")); val remaining = end?.let { java.time.Duration.between(now, it).toMinutes().coerceAtLeast(0) }
            Text(when { batteryPaused -> "Paused"; manual && remaining != null -> "${duration(remaining)} remaining"; active == true -> "Active"; active == false -> "Inactive"; else -> "Unknown" }, style = MaterialTheme.typography.headlineSmall)
            Text(when { batteryPaused -> "Paused for low battery."; manual -> "Manual session. Triggers are paused."; active == true -> "Automatic trigger session."; active == false -> if (k.flag("triggersPaused") == true) "No manual session. Triggers are paused." else "No active brewing session."; else -> "Session status unavailable." }, style = MaterialTheme.typography.bodySmall)
        }
    }
    Text("Active triggers", style = MaterialTheme.typography.titleSmall)
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        val checked = parsed(triggers.text("checkedAt")); val status = triggers.text("state")
        Text(when { status == "checking" -> "Checking…"; checked == null -> "Not checked yet"; else -> "Triggers checked at ${time(checked)}${if (status in setOf("stale", "error", "unknown") || !reachable) " · Stale" else ""}" }, style = MaterialTheme.typography.labelSmall, modifier = Modifier.weight(1f), color = MaterialTheme.colorScheme.onSurfaceVariant)
        TextButton(onClick = { Companion.service?.send("refresh_triggers") }, enabled = can("refreshTriggers")) { Text("Refresh") }
    }
    val rules = triggers?.get("rules")?.jsonArray?.map { it.jsonObject }.orEmpty()
    rules.forEach { rule ->
        Column(Modifier.padding(vertical = 3.dp)) {
            Text(rule.text("label") ?: "Unnamed condition", style = MaterialTheme.typography.bodyMedium)
            val grace = rule.flag("inGrace") == true
            Text(when { rule.flag("satisfied") == null -> "Unknown · input unavailable"; grace -> "Grace only · not a promise of continued wakefulness"; rule.flag("satisfied") == true -> if (manual || k.flag("triggersPaused") == true) "Matches while trigger control is paused" else "Current match"; else -> "No current match" }, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            rule["details"]?.jsonArray?.forEach { detail -> val d = detail.jsonObject; Text("${d.text("label") ?: "Detail"} · ${when(d.flag("active")) { true -> "Active"; false -> "Inactive"; null -> "Unknown" }}${d.text("agent")?.let { " · $it" } ?: ""}", style = MaterialTheme.typography.labelSmall) }
        }
    }
    if (rules.isEmpty()) Text(triggers.text("message") ?: "Current matches unknown", style = MaterialTheme.typography.bodySmall)
    val paused = k.flag("triggersPaused")
    val triggerCapability = if (paused == true) "resumeTriggers" else "pauseTriggers"
    FilledTonalButton(modifier = Modifier.fillMaxWidth(), onClick = { if (paused == true) confirm("resume_triggers") else Companion.service?.send("pause_triggers") }, enabled = paused != null && can(triggerCapability)) { Text(if (paused == true) "Resume triggers" else "Pause triggers") }
    if (reachable && caps.flag(triggerCapability) != true) Text("Trigger control unavailable. The Mac helper needs a supported control adapter and any required permission.", style = MaterialTheme.typography.labelSmall)
    HorizontalDivider()
    if (manual) Button(onClick = { Companion.service?.send("stop_manual") }, enabled = can("stopManual"), modifier = Modifier.fillMaxWidth()) { Text("Stop manual session") }
    else {
        var minutes by remember { mutableIntStateOf(120) }
        Text("Manual session", style = MaterialTheme.typography.titleSmall)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            OutlinedButton(onClick = { minutes -= 15 }, enabled = minutes > 15) { Text("−") }
            Text(duration(minutes.toLong()), style = MaterialTheme.typography.bodyMedium)
            OutlinedButton(onClick = { minutes += 15 }, enabled = minutes < 10080) { Text("+") }
            Button(onClick = { Companion.service?.send("start_manual", minutes) }, enabled = can("startManual"), modifier = Modifier.weight(1f)) { Text("Start") }
        }
    }
    if (reachable && caps.flag(if (manual) "stopManual" else "startManual") != true) Text("Manual control unavailable on this Mac. Check Keepresso and the helper's supported actions.", style = MaterialTheme.typography.labelSmall)
    TextButton(onClick = { confirm("sleep_now") }, enabled = can("sleepNow"), modifier = Modifier.fillMaxWidth()) { Icon(Icons.Default.Bedtime, null); Spacer(Modifier.width(8.dp)); Text("Sleep now") }
    if (reachable && caps.flag("sleepNow") != true) Text("Sleep unavailable: the Mac helper could not establish a safe sleep path.", style = MaterialTheme.typography.labelSmall)
    Text(when { reminders.text("snoozedUntil") != null -> "Reminders snoozed until ${time(parsed(reminders.text("snoozedUntil")))}"; reminders.flag("enabled") == false -> "Routine reminders off"; reminders.flag("enabled") == true -> if (reminders.number("intervalSeconds") == 7200.0) "Reminders every 2 hours" else "Hourly reminders on"; else -> "Reminder status unknown" }, style = MaterialTheme.typography.labelSmall)
}
@Composable private fun SettingsScreen(state: UiState, reachable: Boolean, onEnable: () -> Unit, onConnect: () -> Unit, onReset: () -> Unit) {
    val r = state.snapshot.section("reminders")
    Text("Settings", style = MaterialTheme.typography.headlineMedium)
    Text(state.pairedName ?: "No Mac authorized", style = MaterialTheme.typography.titleMedium)
    Text("Nearby connection · Bluetooth. Reconnects automatically while nearby access is enabled.", style = MaterialTheme.typography.bodySmall)
    Row { TextButton(onClick = onEnable) { Text("Permissions") }; TextButton(onClick = onConnect) { Text("Reconnect") } }
    Text("Internet access", style = MaterialTheme.typography.titleSmall); Text("Not implemented. Delivery requires a nearby Bluetooth connection.", style = MaterialTheme.typography.bodySmall)
    HorizontalDivider()
    val currentEnabled = r.flag("enabled"); val currentInterval = r.number("intervalSeconds")?.toInt(); val currentDelay = r.number("endedAwakeDelaySeconds")?.toInt()
    fun save(enabled: Boolean = currentEnabled ?: true, interval: Int = currentInterval ?: 3600, delay: Int = currentDelay ?: 300) { Companion.service?.send("set_reminder_settings", settings = ReminderSettings(enabled, interval, delay)) }
    Text("Still-running reminder", style = MaterialTheme.typography.titleSmall)
    Row { listOf("Every hour" to 3600, "Every 2 hours" to 7200).forEach { (label, value) -> FilterChip(selected = currentEnabled == true && currentInterval == value, onClick = { save(enabled = true, interval = value) }, enabled = reachable && !state.busy && r != null, label = { Text(label) }) } }
    FilterChip(selected = currentEnabled == false, onClick = { save(enabled = false) }, enabled = reachable && !state.busy && r != null, label = { Text("Off") })
    Text("Still awake after stopping", style = MaterialTheme.typography.titleSmall)
    Row { listOf(120, 300, 600).forEach { value -> FilterChip(selected = currentDelay == value, onClick = { save(delay = value) }, enabled = reachable && !state.busy && r != null, label = { Text("${value / 60} min") }) } }
    Text("Routine reminders", style = MaterialTheme.typography.titleSmall)
    Row { TextButton(onClick = { Companion.service?.send("snooze_reminders") }, enabled = reachable && !state.busy) { Text("Snooze 6 hours") }; TextButton(onClick = { Companion.service?.send("resume_reminders") }, enabled = reachable && !state.busy) { Text("Resume") } }
    Text("Battery, heat and sleep warnings stay on during routine-reminder snoozes.", style = MaterialTheme.typography.bodySmall)
    HorizontalDivider(); TextButton(onClick = onReset, enabled = state.pairedName != null) { Text("Remove phone authorization") }
}

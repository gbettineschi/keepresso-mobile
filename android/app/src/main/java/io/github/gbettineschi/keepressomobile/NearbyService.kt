package io.github.gbettineschi.keepressomobile

import android.Manifest
import android.app.*
import android.content.*
import android.content.pm.PackageManager
import android.os.*
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.github.gbettineschi.keepressomobile.core.*
import java.time.Instant
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.*

data class ActivityEntry(val time: Instant, val text: String)
data class UiState(val connection: String = "Not connected", val authenticated: Boolean = false, val snapshot: JsonObject? = null, val receivedAt: Instant? = null, val lastContact: Instant? = null, val pairedName: String? = null, val result: String? = null, val busy: Boolean = false, val serverOffsetSeconds: Long = 0, val activity: List<ActivityEntry> = emptyList()) {
    fun reachable(now: Instant): Boolean = authenticated && receivedAt?.let { java.time.Duration.between(it, now).seconds in 0..15 } == true
}
object Companion {
    internal val mutable = MutableStateFlow(UiState())
    val state = mutable.asStateFlow()
    var service: NearbyService? = null; internal set
    fun update(block: (UiState) -> UiState) { mutable.value = block(mutable.value) }
    fun activity(text: String) { update { it.copy(activity = (listOf(ActivityEntry(Instant.now(), text.take(240))) + it.activity).take(100)) } }
}
class NearbyService : Service() {
    private lateinit var store: CredentialStore
    private lateinit var ble: BleCentral
    private val main = Handler(Looper.getMainLooper())
    private var credential: Credential? = null
    private var invitation: Invitation? = null
    private var session: ClientSession? = null
    private var delivery = Delivery()
    private var pendingMutation: String? = null
    private var pendingRequestId: String? = null
    private var pendingAction: String? = null
    private var enabled = true
    private var reconnectGeneration = 0
    private val preferences by lazy { getSharedPreferences("reminders", MODE_PRIVATE) }
    private val seenEvents = linkedSetOf<String>()
    private var serverOffset = java.time.Duration.ZERO
    private var requestedPreview = false
    private var protocolFailures = 0
    private val poll = object : Runnable { override fun run() {
        if (!enabled) return
        if (session?.ready == true) send("status", quiet = true)
        main.postDelayed(this, 10000)
    } }
    override fun onBind(intent: Intent?) = null
    override fun onCreate() {
        super.onCreate(); Companion.service = this; store = CredentialStore(this)
        credential = runCatching { store.load() }.getOrElse { Companion.update { s -> s.copy(result = "Stored authorization could not be unlocked. Pair again.") }; null }
        Companion.update { it.copy(pairedName = credential?.name) }
        Notifications.channels(this)
        startForeground(1, Notifications.connection(this, "Nearby connection enabled"))
        ble = BleCentral(this, { text -> Companion.update { it.copy(connection = text) }; Notifications.updateConnection(this, text) }, ::subscribed, ::receive, ::disconnected)
        main.postDelayed(poll, 10000)
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            "pair" -> {
                runCatching { Invitation.parse(intent.getStringExtra("invitation") ?: "", Instant.now().epochSecond) }.onSuccess {
                    invitation = null; credential = null; enabled = true; protocolFailures = 0; ble.start(); invitation = it
                }.onFailure { Companion.update { s -> s.copy(result = "Invalid or expired pairing invitation") } }
            }
            "reset" -> {
                enabled = false; invitation = null; credential = null; store.clear(); ble.close("Authorization removed from this phone")
                Companion.update { UiState(connection = "Pair with your Mac", result = "Phone reset. Revoke this phone in the Mac helper to remove its authorization there.") }; stopSelf()
            }
            "snooze" -> { preferences.edit().putLong("snoozeUntil", Instant.now().plusSeconds(21600).epochSecond).apply(); if (session?.ready == true) send("snooze_reminders") else Companion.activity("Routine notifications snoozed locally for 6 hours; Mac unreachable") }
            "ack" -> if (session?.ready == true) send("ack_reminder")
            else -> if (credential != null) { enabled = true; protocolFailures = 0; ble.start() } else Companion.update { it.copy(connection = "Pair with your Mac") }
        }
        return START_NOT_STICKY
    }
    private fun subscribed() {
        try {
            val invite = invitation
            if (invite != null) {
                val id = store.deviceId(); val name = (Build.MODEL ?: "Android phone").take(40); val nonce = randomNonce()
                val pair = buildJsonObject { put("type", "pair"); put("version", 1); put("macId", invite.macId); put("deviceId", id); put("deviceName", name); put("clientNonce", nonce); put("proof", Crypto.proof(invite.token, Crypto.pairTranscript(invite.macId, id, nonce, name))) }
                ble.send(pair.toString()); Companion.update { it.copy(connection = "Approve this phone on your Mac") }
            } else authenticate()
        } catch (_: Exception) { ble.close("Could not begin secure authorization") }
    }
    private fun authenticate() {
        val c = credential ?: return ble.close("Pair with your Mac")
        session = ClientSession(c.macId, c.deviceId, c.key); ble.send(requireNotNull(session).hello())
    }
    private fun receive(text: String) {
        try {
            val r = obj(text)
            if (invitation != null) {
                when (r.string("type")) {
                    "pair_pending" -> Companion.update { it.copy(connection = "Waiting for local approval on Mac…") }
                    "pair_denied" -> { invitation = null; ble.close("Pairing denied or expired") }
                    "paired" -> {
                        val invite = requireNotNull(invitation); val id = store.deviceId()
                        require(r.string("macId") == invite.macId && r.string("deviceId") == id)
                        val key = Crypto.deviceKey(invite.token, invite.macId, id)
                        require(Crypto.verify(key, "paired\n${invite.macId}\n$id", r.string("proof")))
                        credential = Credential(invite.macId, id, invite.name, key).also(store::save); invitation = null
                        Companion.update { it.copy(pairedName = credential?.name) }; Companion.activity("Phone authorized by Mac owner"); authenticate()
                    }
                    else -> error("Unexpected pair response")
                }; return
            }
            val s = session ?: error("No session")
            if (r.string("type") == "challenge") { ble.send(s.challenge(text)); return }
            val message = obj(s.receive(text, Instant.now()))
            val now = Instant.now()
            when (message.string("type")) {
                "ready" -> {
                    serverOffset = java.time.Duration.between(now, Instant.parse(message.string("serverTime"))); ble.authenticated()
                    Companion.update { it.copy(authenticated = true, connection = "Connected nearby", lastContact = now, serverOffsetSeconds = serverOffset.seconds) }; Companion.activity("Nearby encrypted connection authenticated")
                    send("status", quiet = true)
                }
                "response" -> {
                    val id = canonicalId(message.string("id")); val status = message.string("status"); delivery.acknowledge(id, status)
                    pendingRequestId = null; Companion.update { it.copy(busy = false) }
                    if (pendingAction == "refresh_triggers" && status != "ok") Companion.update { it.copy(result = message.stringOrNull("message") ?: "Trigger assessment unavailable; last successful check preserved") }
                    pendingAction = null
                    if (pendingMutation == id) { pendingMutation = null; Companion.update { it.copy(busy = false, result = message.stringOrNull("message") ?: when (status) { "ok" -> "Mac acknowledged the command"; "uncertain" -> "Outcome uncertain. Check your Mac before trying again."; else -> "Mac could not complete the command" }) }; Companion.activity("Command outcome: $status") }
                    val snapshot = message["snapshot"]?.takeUnless { it == JsonNull }?.jsonObject
                    if (snapshot != null) {
                        val checked = DashboardState(); checked.update(snapshot.toString(), SystemClock.elapsedRealtime(), now.plus(serverOffset))
                        val captured = Instant.parse(snapshot.string("capturedAt")); val serverNow = now.plus(serverOffset)
                        val age = java.time.Duration.between(captured, serverNow).seconds
                        require(age >= -10)
                        val localCaptured = captured.minus(serverOffset)
                        Companion.update { it.copy(snapshot = snapshot, receivedAt = localCaptured, lastContact = now) }
                        if (!requestedPreview && checked.run { connected = true; reachable(SystemClock.elapsedRealtime()) } && snapshot["capabilities"]?.jsonObject?.boolOrNull("refreshTriggers") == true) {
                            requestedPreview = true; send("refresh_triggers", quiet = true)
                        }
                    } else Companion.update { it.copy(lastContact = now) }
                }
                "event" -> event(message.getValue("event").jsonObject)
            }
        } catch (_: Exception) { protocolFailures++; if (protocolFailures >= 4) enabled = false; ble.close(if (enabled) "Secure protocol validation failed; connection closed" else "Repeated authorization failures. Check your Mac, then reconnect.") }
    }
    fun send(action: String, duration: Int? = null, settings: ReminderSettings? = null, quiet: Boolean = false) {
        val s = session
        if (s?.ready != true || (action != "status" && !Companion.state.value.reachable(Instant.now()))) { if (!quiet) Companion.update { it.copy(result = "Mac unreachable. No command was queued.") }; return }
        val mutation = action !in setOf("status", "refresh_triggers")
        if (delivery.hasPending) { if (!quiet) Companion.update { it.copy(result = "Wait for the current Mac response") }; return }
        try {
            val record = s.request(action, Instant.now(), duration, settings); val id = requireNotNull(s.lastRequestId)
            delivery.sent(id, mutation); pendingRequestId = id; pendingAction = action
            Companion.update { it.copy(busy = true) }
            if (mutation) { pendingMutation = id; Companion.update { it.copy(busy = true, result = "Waiting for Mac acknowledgement…") } }
            ble.send(record)
            val epoch = reconnectGeneration
            main.postDelayed({ if (epoch == reconnectGeneration) { if (pendingRequestId == id) ble.close(if (pendingMutation == id) "Command outcome uncertain; connection closed" else "Mac response timed out; connection closed") } }, 31000)
        } catch (_: Exception) { ble.close("Command delivery uncertain; connection closed") }
    }
    private fun disconnected() {
        reconnectGeneration++; session = null; invitation = null; requestedPreview = false
        val outcomes = delivery.disconnect()
        val uncertain = outcomes.values.any { it == "uncertain" }; pendingMutation = null; pendingRequestId = null; pendingAction = null
        Companion.update { it.copy(authenticated = false, busy = false, result = if (uncertain) "Command outcome uncertain. It will never be retried automatically." else it.result) }
        if (uncertain) Companion.activity("Connection lost before command acknowledgement — outcome uncertain")
        val epoch = reconnectGeneration
        if (enabled && credential != null) main.postDelayed({ if (enabled && epoch == reconnectGeneration && session == null) ble.start() }, 15000)
    }
    private fun event(e: JsonObject) {
        val id = canonicalId(e.string("id")); val kind = e.string("kind"); require(kind in setOf("hourly", "session_ended_awake", "battery", "thermal", "sleep_failed")); Instant.parse(e.string("createdAt"))
        if (!seenEvents.add(id)) return; while (seenEvents.size > 128) seenEvents.remove(seenEvents.first())
        val title = e.string("title").take(120); val body = e.string("body").take(1000)
        Companion.activity(title)
        if (kind == "hourly" && preferences.getLong("snoozeUntil", 0) > Instant.now().epochSecond) return
        Notifications.reminder(this, id.hashCode(), title, body, kind == "hourly")
    }
    override fun onDestroy() { enabled = false; main.removeCallbacksAndMessages(null); if (::ble.isInitialized) ble.close(null); Companion.service = null; super.onDestroy() }
}
object Notifications {
    private val posted = linkedSetOf<Int>()
    fun updateConnection(c: Context, text: String) { runCatching { c.getSystemService(NotificationManager::class.java).notify(1, connection(c, text)) } }
    fun channels(c: Context) { c.getSystemService(NotificationManager::class.java).createNotificationChannels(listOf(NotificationChannel("nearby", "Nearby connection", NotificationManager.IMPORTANCE_LOW), NotificationChannel("reminders", "Routine reminders", NotificationManager.IMPORTANCE_DEFAULT), NotificationChannel("warnings", "Battery, heat and sleep warnings", NotificationManager.IMPORTANCE_HIGH))) }
    private fun open(c: Context, id: Int) = PendingIntent.getActivity(c, id, Intent(c, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    fun connection(c: Context, text: String): Notification = NotificationCompat.Builder(c, "nearby").setSmallIcon(R.drawable.keepresso_menu_idle).setContentTitle("Keespresso nearby").setContentText(text).setContentIntent(open(c, 0)).setOngoing(true).build()
    fun reminder(c: Context, id: Int, title: String, body: String, routine: Boolean) {
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(c, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val b = NotificationCompat.Builder(c, if (routine) "reminders" else "warnings").setSmallIcon(R.drawable.keepresso_menu_brewing).setContentTitle(title).setContentText(body).setStyle(NotificationCompat.BigTextStyle().bigText(body)).setContentIntent(open(c, id)).setAutoCancel(true)
        if (routine) for ((action, label) in listOf("ack" to "OK", "snooze" to "Snooze 6 hours")) b.addAction(0, label, PendingIntent.getBroadcast(c, id xor action.hashCode(), Intent(c, ReminderReceiver::class.java).setAction(action).putExtra("notificationId", id), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        b.addAction(0, "Open", open(c, id)); val manager = c.getSystemService(NotificationManager::class.java); posted.add(id); while (posted.size > 24) manager.cancel(posted.first().also { posted.remove(it) }); manager.notify(id, b.build())
    }
}
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        context.getSystemService(NotificationManager::class.java).cancel(intent.getIntExtra("notificationId", 0))
        if (intent.action == "snooze") context.getSharedPreferences("reminders", Context.MODE_PRIVATE).edit().putLong("snoozeUntil", Instant.now().plusSeconds(21600).epochSecond).apply()
        val service = Companion.service
        if (service != null && Companion.state.value.reachable(Instant.now())) service.send(if (intent.action == "snooze") "snooze_reminders" else "ack_reminder")
        else if (intent.action == "snooze") Companion.activity("Routine reminders snoozed locally for 6 hours; Mac unreachable")
    }
}

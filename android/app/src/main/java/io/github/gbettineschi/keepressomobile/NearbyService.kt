package io.github.gbettineschi.keepressomobile

import android.Manifest
import android.app.*
import android.content.*
import android.content.pm.PackageManager
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.os.*
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.net.Uri
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.github.gbettineschi.keepressomobile.core.*
import java.time.Instant
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.*

data class ActivityEntry(val time: Instant, val text: String)
data class UiState(val connection: String = "Not connected", val transport: String = "Nearby Bluetooth", val internetConfigured: Boolean = false, val authenticated: Boolean = false, val snapshot: JsonObject? = null, val receivedAt: Instant? = null, val lastContact: Instant? = null, val pairedName: String? = null, val macId: String? = null, val localSnoozedUntil: Instant? = null, val result: String? = null, val busy: Boolean = false, val checkingTriggers:Boolean=false, val triggerHistory: TriggerHistory = TriggerHistory(), val nearbyRecoveryIssue: NearbyRecoveryIssue? = null, val serverOffsetSeconds: Long = 0, val activity: List<ActivityEntry> = emptyList()) {
    fun reachable(now: Instant): Boolean = authenticated && receivedAt?.let { java.time.Duration.between(it, now).toMillis() in 0..15000 } == true
}
object Companion {
    internal val mutable = MutableStateFlow(UiState())
    val state = mutable.asStateFlow()
    var service: NearbyService? = null; internal set
    var dashboardVisible = false
    fun update(block: (UiState) -> UiState) {
        val previous=mutable.value;val next=block(previous);mutable.value=next
        if(previous.authenticated!=next.authenticated || previous.transport!=next.transport || previous.connection!=next.connection)
            android.util.Log.i("KeepressoTransport","state authenticated=${next.authenticated} route=${next.transport} connection=${next.connection}")
    }
    fun activity(text: String) { update { it.copy(activity = (listOf(ActivityEntry(Instant.now(), text.take(240))) + it.activity).take(100)) } }
}
class NearbyService : Service() {
    private lateinit var store: CredentialStore
    private lateinit var ble: BlePeripheral
    private lateinit var journal: MutationJournal
    private val main = Handler(Looper.getMainLooper())
    private val network = java.util.concurrent.Executors.newSingleThreadExecutor()
    private var credential: Credential? = null
    private var invitation: Invitation? = null
    private var session: ClientSession? = null
    private val relayFresh = RelayFreshness()
    private val internetFresh=InternetFreshness()
    private val nearbyFresh=InternetFreshness()
    private var internetStore:InternetCredentialStore?=null
    private var internet:IrohConnection?=null
    private var nextInternetAttempt=0L
    private var internetBackoff=2L
    private var nextInternetStatus=0L
    private fun legacyAvailable()=internetStore?.configuration==null && credential?.relayUrl!=null && credential?.relayAuthTicket!=null
    private fun remoteFresh()=internetFresh.reachable(Instant.now().plus(serverOffset)) || relayFresh.reachable(Instant.now().plus(serverOffset))
    private fun internetConfigured()=internetStore?.configuration!=null || legacyAvailable()

    private var enabled = true
    private var nearbyEnabled = true
    private var foregroundActivity = false
    private var checkTriggersOnOpen = false
    private var nearbyForeground = false
    private var commandStorageAvailable = true
    private var reconnectGeneration = 0
    private val recovery = PeripheralRecovery()
    private var recoveryAt: Long? = null
    private var radioReceiverRegistered = false
    private val recoveryAttempt = Runnable {
        recoveryAt = null
        val now = SystemClock.elapsedRealtime()
        val due = recovery.nextAttemptAt(now, recoveryState())
        if (due != null && due <= now) ble.start()
        scheduleRecovery()
    }
    private val radioReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == BluetoothAdapter.ACTION_STATE_CHANGED) scheduleRecovery()
        }
    }
    private var serverOffset = java.time.Duration.ZERO
    private var protocolFailures = 0
    private var remoteBusy = false
    private var nextRemotePoll = 0L
    private var nextNearbyPoll = 0L
    private var nextRemoteStatus=0L
    private val waitingCommand=UserCommandWait()
    private var triggerCheckRequestedAt:Long?=null
    private val reconciledThisConnection = mutableSetOf<String>()
    private data class Pending(val id: String, val action: String, val mutation: Boolean, val route: String, val epoch: String?, val sent: Instant, val operationId: String? = null, val fastPoll: Boolean = false)
    private var pending: Pending? = null
    private val sleepAttempts = linkedMapOf<String, SleepAttempt>()
    var preparingSleep = false
    private fun bluetoothAllowed(): Boolean = NearbyPermissions.allowed(this)
    private fun recoveryState(): PeripheralRecovery.State {
        val permission = bluetoothAllowed()
        val radioOn = permission && runCatching { getSystemService(BluetoothManager::class.java)?.adapter?.isEnabled == true }.getOrDefault(false)
        return PeripheralRecovery.State(enabled, nearbyEnabled, credential != null, permission, radioOn, ble.isRunning, session != null)
    }
    private fun scheduleRecovery() {
        var current = recoveryState()
        if (current.serverRunning && (!current.permission || !current.radioOn)) {
            ble.close(if (current.permission) "Turn on Bluetooth to connect nearby" else "Nearby Devices permission is required")
            current = recoveryState()
        }
        Companion.update { it.copy(nearbyRecoveryIssue = nearbyRecoveryIssue(current)) }
        val due = recovery.nextAttemptAt(SystemClock.elapsedRealtime(), current)
        if (due == recoveryAt) return
        main.removeCallbacks(recoveryAttempt)
        recoveryAt = due
        if (due != null) main.postDelayed(recoveryAttempt, (due - SystemClock.elapsedRealtime()).coerceAtLeast(0))
    }
    private fun peripheralAvailabilityChanged(ready: Boolean) {
        if (ready) recovery.stable() else recovery.failed(SystemClock.elapsedRealtime())
        scheduleRecovery()
    }
    private val poll = object : Runnable { override fun run() {
        if (!enabled) return
        scheduleRecovery()
        val now = Instant.now()
        ensureInternet()
        maybeCheckTriggersOnOpen()
        if(foregroundActivity && internet?.ready==true && now.epochSecond>=nextInternetStatus && session?.ready!=true){nextInternetStatus=now.epochSecond+2;send("status",quiet=true)}
        if(session?.ready!=true && !remoteFresh())Companion.update{it.copy(authenticated=false)}
        discardStaleWait(now)
        if(waitingCommand.expire(SystemClock.elapsedRealtime()))Companion.update{it.copy(busy=false,result="Mac is busy. Your command wasn't sent; tap again.")}
        triggerCheckRequestedAt?.takeIf{SystemClock.elapsedRealtime()-it>=8000}?.let{triggerCheckRequestedAt=null;Companion.update{it.copy(checkingTriggers=pending?.action=="refresh_triggers",triggerHistory=it.triggerHistory.failed("Mac is busy. Tap Check again."))}}
        pending?.takeIf {
            val timeout=if(it.mutation || it.operationId!=null)30L else if(it.route=="nearby")5L else 15L
            if(it.action=="refresh_triggers")triggerCheckTimedOut(it.sent,now) else now>it.sent.plusSeconds(timeout)
        }?.let { android.util.Log.w("KeepressoTransport","request timed out route=${it.route} action=${it.action}");val nearby=it.route=="nearby";deliveryLost();if(nearby)ble.close("Unreachable") }
        if (session?.ready == true && now.epochSecond >= nextNearbyPoll) { nextNearbyPoll = now.epochSecond + if(foregroundActivity)2 else 10; send("status", quiet = true) }
        if (foregroundActivity && legacyAvailable() && (session?.ready != true || pending?.route == "relay")) {
            if (now.epochSecond >= nextRemotePoll) {
                nextRemotePoll = now.epochSecond + if (pending?.route == "relay" && pending?.fastPoll == true) 1 else 5
                pollRelay()
            }
            if (session?.ready != true && !relayFresh.reachable(now.plus(serverOffset))) Companion.update { it.copy(authenticated = false, connection = "Internet status is stale or unavailable") }
            if(session?.ready!=true && relayFresh.epoch!=null && now.epochSecond>=nextRemoteStatus && pending==null)send("status",quiet=true)
        }
        main.postDelayed(this, 1000)
    } }
    override fun onBind(intent: Intent?) = null
    override fun onCreate() {
        super.onCreate(); Companion.service = this; store = CredentialStore(this)
        credential = runCatching { store.load() }.getOrElse { Companion.update { s -> s.copy(result = "Stored authorization could not be unlocked. Pair again.") }; null }
        internetStore=credential?.let{runCatching{InternetCredentialStore(store,it)}.getOrNull()}
        journal = runCatching { MutationJournal({ store.readPrivate("mutationJournal") }, { store.writePrivate("mutationJournal", it) }) }.getOrElse {
            commandStorageAvailable = false
            MutationJournal({ null }, { error("Saved command outcomes unavailable") })
        }
        Companion.update { it.copy(pairedName = credential?.name, macId = credential?.macId, internetConfigured = internetConfigured(), localSnoozedUntil = credential?.macId?.let { id -> PhoneReminders.until(this, id) }, result = if (!commandStorageAvailable) "Saved command outcomes could not be read. Controls are disabled; check your Mac before removing authorization." else if (journal.unresolved().isNotEmpty()) "An earlier command has an uncertain outcome. Its status will be checked without resending it." else it.result) }
        Notifications.channels(this)
        ensureNearbyForeground()
        ble = BlePeripheral(this, { text -> if (session?.ready != true && !remoteFresh()) Companion.update { it.copy(connection = text) }; Notifications.updateConnection(this, text) }, ::subscribed, ::receive, ::disconnected, ::peripheralAvailabilityChanged)
        ContextCompat.registerReceiver(this, radioReceiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED), ContextCompat.RECEIVER_EXPORTED)
        radioReceiverRegistered = true
        main.post(poll)
    }
    private fun ensureNearbyForeground() {
        if (bluetoothAllowed() && !nearbyForeground) { startForeground(1, Notifications.connection(this, "Nearby connection enabled")); nearbyForeground = true }
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureNearbyForeground()
        if (intent?.getBooleanExtra("preparingSleep", false) == true) preparingSleep = true
        updateForegroundActivity(intent?.getBooleanExtra("foreground", foregroundActivity) ?: foregroundActivity)
        when (intent?.action) {
            "pair" -> {
                if (!bluetoothAllowed()) { Companion.update { it.copy(result = "Nearby access is needed to authorize a phone") }; return START_NOT_STICKY }
                runCatching { Invitation.parse(intent.getStringExtra("invitation") ?: "", Instant.now().epochSecond) }.onSuccess {
                    Companion.update{state->state.copy(result=null)}
                    invitation = null; enabled = true; nearbyEnabled = true; protocolFailures = 0; ble.start(resetCandidates = true); invitation = it
                }.onFailure { Companion.update { s -> s.copy(result = "Invalid or expired pairing invitation") } }
            }
            "reset" -> {
                enabled = false;internet?.close();internet=null;internetFresh.disconnect(); credential?.macId?.let { PhoneReminders.filter(this).reset(it) }; invitation = null; credential = null; ReminderDelivery.reset(this); ble.close("Authorization removed from this phone")
                Companion.update { UiState(connection = "Pair with your Mac", result = "Phone reset. Revoke this phone in the Mac helper to remove its authorization there.") }; stopSelf()
            }
            "snooze" -> { credential?.macId?.let { PhoneReminders.filter(this).snooze(it, Instant.now()) }; send("snooze_reminders") }
            "ack" -> send("ack_reminder")
            "foreground" -> { nextRemotePoll = 0; if (credential != null && nearbyEnabled && bluetoothAllowed() && session == null && !ble.isRunning) ble.start(resetCandidates = true) }
            else -> if (credential != null) { enabled = true; nearbyEnabled = true; protocolFailures = 0; if (bluetoothAllowed()) { if (!ble.isRunning && session == null) ble.start(resetCandidates = true) } else Companion.update { it.copy(connection = "Nearby access denied; checking internet") } } else Companion.update { it.copy(connection = "Pair with your Mac") }
        }
        scheduleRecovery()
        return START_NOT_STICKY
    }
    private fun updateForegroundActivity(value: Boolean) {
        if (foregroundActivity != value) {
            // An in-flight check already supplies a result for this visit.
            checkTriggersOnOpen = value && pending?.action != "refresh_triggers"
            foregroundActivity = value
        }
    }

    private fun maybeCheckTriggersOnOpen() {
        if (!checkTriggersOnOpen || preparingSleep || pending != null || waitingCommand.hasCommand || triggerCheckRequestedAt != null) return
        val capabilities = Companion.state.value.snapshot?.get("capabilities") as? JsonObject
        if (capabilities?.boolOrNull("refreshTriggers") == true) send("refresh_triggers", quiet = true)
    }

    fun foreground(value: Boolean) {
        updateForegroundActivity(value)
        if (value) { nextRemotePoll = 0; PushRegistration.configurationChanged(this) }
        else {
            triggerCheckRequestedAt=null
            if(waitingCommand.clear())Companion.update{it.copy(busy=pending?.mutation==true,result="Your command wasn't sent.")}
            Companion.update{it.copy(checkingTriggers=pending?.action=="refresh_triggers")}
            relayFresh.disconnect();internet?.close();internet=null;internetFresh.disconnect()
            if (session?.ready != true) Companion.update { it.copy(authenticated = false) }
            if (!bluetoothAllowed()) stopSelf()
        }
    }
    fun prepareSleepRoute() {
        preparingSleep = true
        if (!foregroundActivity) {
            updateForegroundActivity(true)
            nextRemotePoll = 0
        }
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
                        // Old records belong to the old authorization, never the replacement pairing.
                        credential?.macId?.let { PhoneReminders.filter(this).reset(it) }; PhoneReminders.filter(this).reset(invite.macId)
                        credential = Credential(invite.macId, id, invite.name, key).also { ReminderDelivery.replace(this, it) }; invitation = null
                        internetStore=credential?.let{InternetCredentialStore(store,it)}
                        journal = MutationJournal({ store.readPrivate("mutationJournal") }, { store.writePrivate("mutationJournal", it) }); commandStorageAvailable = true
                        Companion.update { it.copy(pairedName = credential?.name, macId = credential?.macId, internetConfigured = internetConfigured(), localSnoozedUntil = credential?.macId?.let { id -> PhoneReminders.until(this, id) }) }; Companion.activity("Phone authorized by Mac owner"); authenticate()
                    }
                    else -> error("Unexpected pair response")
                }; return
            }
            val s = session ?: error("No session")
            if (r.string("type") == "challenge") { ble.send(s.challenge(text)); return }
            val now = Instant.now(); val message = obj(s.receive(text, now))
            when (message.string("type")) {
                "ready" -> {
                    serverOffset = java.time.Duration.between(now, Instant.parse(message.string("serverTime"))); ble.authenticated(); reconciledThisConnection.clear();nearbyFresh.connected("$reconnectGeneration")
                    message["internet"]?.let{acceptInternetConfiguration(it.toString())}
                    Companion.update { it.copy(authenticated = remoteFresh(), connection = "Connected nearby", transport = "Nearby Bluetooth", lastContact = now, serverOffsetSeconds = serverOffset.seconds) }; Companion.activity("Nearby encrypted connection authenticated")
                    DirectPushRegistration.connectionAvailable(this)
                    send("status", quiet = true)
                }
                "internet_config" -> acceptInternetConfiguration(message.toString())
                "relay_config" -> {
                    if(internetStore?.configuration!=null)return
                    val enabled = message.boolOrNull("enabled") ?: error("Missing relay configuration")
                    val url = if (enabled) message.string("url").also { RelayEndpoint(it) } else null
                    val ticket = if (enabled) message.string("authTicket").also { decode64(it, 32) } else null
                    credential = requireNotNull(credential).copy(relayUrl = url, relayAuthTicket = ticket).also(store::save)
                    Companion.update { it.copy(internetConfigured = url != null) }
                    relayFresh.disconnect()
                    PushRegistration.configurationChanged(this); nextRemotePoll = 0
                    Companion.activity(if (enabled) "Internet fallback configured by the authorized Mac" else "Internet fallback disabled by the Mac")
                }
                "response" -> response(message, "nearby", null)
                "event" -> credential?.let { ReminderDelivery.post(this, it, message.getValue("event").jsonObject, now.plus(serverOffset)) }
            }
        } catch (_: Exception) { protocolFailures++; if (protocolFailures >= 4) nearbyEnabled = false; ble.close(if (nearbyEnabled) "Secure protocol validation failed; connection closed" else "Repeated authorization failures. Check your Mac, then reconnect.") }
    }
    private fun acceptInternetConfiguration(text:String) {
        runCatching {
            val metadata=internetStore ?: credential?.let{InternetCredentialStore(store,it)}?.also{internetStore=it} ?: return
            val previous=metadata.configuration
            val config=metadata.acceptAuthenticated(text)
            relayFresh.disconnect()
            Companion.update{it.copy(internetConfigured=true)}
            if(previous?.endpointId!=config.endpointId){internet?.close();internet=null;internetFresh.disconnect();nextInternetAttempt=0}
            if(previous!=config)PushRegistration.configurationChanged(this)
            ensureInternet()
        }.onFailure{android.util.Log.w("KeepressoTransport","Invalid Internet configuration ignored")}
    }
    private fun ensureInternet() {
        if(session?.ready==true && nearbyFresh.reachable(Instant.now().plus(serverOffset)) && pending?.route!="iroh"){
            internet?.close();internet=null;internetFresh.disconnect();return
        }
        if(!enabled || !foregroundActivity || internet!=null || Instant.now().epochSecond<nextInternetAttempt)return
        val credential=credential ?: return
        val configuration=internetStore?.configuration ?: return
        nextInternetAttempt=Instant.now().epochSecond+internetBackoff
        internet=IrohConnection(this,credential,configuration,{message,generation ->
            if(internet?.generation!=generation)return@IrohConnection
            when(message.string("type")) {
                "ready" -> {
                    serverOffset=java.time.Duration.between(Instant.now(),Instant.parse(message.string("serverTime")))
                    internetFresh.connected(generation);internetBackoff=2;nextInternetStatus=0
                    DirectPushRegistration.connectionAvailable(this)
                    message["internet"]?.let{acceptInternetConfiguration(it.toString())}
                    reconciledThisConnection.clear()
                    if(session?.ready!=true)send("status",quiet=true)
                }
                "response" -> response(message,"iroh",generation)
                "internet_config" -> acceptInternetConfiguration(message.toString())
                "event" -> ReminderDelivery.post(this,credential,message.getValue("event").jsonObject,Instant.now().plus(serverOffset))
            }
        },{generation ->
            if(internet?.generation==generation){
                internet=null;internetFresh.disconnect()
                if(pending?.route=="iroh" && pending?.epoch==generation)deliveryLost()
                if(session?.ready!=true)Companion.update{it.copy(authenticated=false)}
                nextInternetAttempt=Instant.now().epochSecond+internetBackoff;internetBackoff=(internetBackoff*2).coerceAtMost(30)
            }
        })
    }
    private fun http(c: Credential): RelayHttp = RelayHttp(RelayEndpoint(requireNotNull(c.relayUrl)), c.macId, c.deviceId, RelayCodec(c.macId, c.deviceId, c.key).bearer(), requireNotNull(c.relayAuthTicket))
    private fun pollRelay() {
        if (remoteBusy || !foregroundActivity || !legacyAvailable()) return
        val c = credential?.takeIf { it.relayUrl != null && it.relayAuthTicket != null } ?: return
        remoteBusy = true
        network.execute {
            val result = runCatching { http(c).call("poll") }
            main.post {
                remoteBusy = false
                if (!enabled || credential !== c || !foregroundActivity || !legacyAvailable()) return@post
                result.onSuccess { acceptRelayPoll(c,it) }.onFailure(::relayPollFailed)
            }
        }
    }
    private fun acceptRelayPoll(c:Credential,poll:JsonObject){
        runCatching {
            val now = Instant.now().plus(serverOffset); val codec = RelayCodec(c.macId, c.deviceId, c.key)
            poll["state"]?.takeUnless { it == JsonNull }?.let { value ->
                val opened = codec.open(value.toString(), now, "s2c", setOf("state"))
                val state = obj(opened.plaintext); require(state.string("type") == "relay_state" && state.string("epoch") == opened.epoch)
                val rev = state.getValue("revision").jsonPrimitive; require(!rev.isString)
                val snapshot = state.getValue("snapshot").jsonObject
                val changedEpoch=relayFresh.epoch!=opened.epoch
                val accepted=relayFresh.state(opened.epoch, requireNotNull(rev.longOrNull), opened.createdAt, snapshot, now)
                android.util.Log.d("KeepressoTransport","relay state accepted=$accepted changedEpoch=$changedEpoch ${relayFresh.diagnostic(now)}")
                if (accepted && session?.ready != true) updateSnapshot(snapshot)
            }
            val messages = poll.getValue("messages").jsonArray; require(messages.size <= 32)
            messages.forEach { value ->
                // Events from a new authenticated epoch can notify without enabling controls.
                val opened = codec.open(value.toString(), now, "s2c", setOf("response", "event"))
                val r = obj(opened.plaintext)
                if (opened.kind == "event") { require(r.string("type") == "event" && r.getValue("event").jsonObject.string("id") == opened.id); ReminderDelivery.post(this, c, r.getValue("event").jsonObject, now) }
                else if (opened.epoch == relayFresh.epoch) { require(r.string("id") == opened.id); response(r, "relay", opened.epoch) }
            }
            if (session?.ready != true) {
                // response() records its proof while processing this batch. The
                // earlier envelope-validation time predates that proof by milliseconds.
                val checkedNow=Instant.now().plus(serverOffset)
                val fresh = relayFresh.reachable(checkedNow)
                android.util.Log.d("KeepressoTransport","relay poll fresh=$fresh ${relayFresh.diagnostic(checkedNow)}")
                Companion.update { it.copy(authenticated = fresh, connection = if (fresh) "Connected over internet" else "Verifying internet connection", transport = "Internet", serverOffsetSeconds = serverOffset.seconds) }
                if (pending == null && relayFresh.epoch != null && !fresh) send("status", quiet = true)
            }
        }.onFailure { android.util.Log.w("KeepressoTransport","relay payload validation failed");relayFresh.disconnect(); if (session?.ready != true) Companion.update { it.copy(authenticated = false, connection = "Internet response could not be authenticated") } }
    }
    private fun relayPollFailed(error:Throwable){
        val transient=if(error is RelayHttpException)error.statusCode==429 || error.statusCode in 500..599 else error is java.io.IOException
        // A failed read provides no new evidence. Keep only the already proven
        // interval; never advance its timestamps or retain rejected authorization.
        if(!transient)relayFresh.disconnect()
        val fresh=relayFresh.reachable(Instant.now().plus(serverOffset))
        android.util.Log.w("KeepressoTransport","relay poll failed transient=$transient status=${(error as? RelayHttpException)?.statusCode ?: 0} evidenceFresh=$fresh")
        if(session?.ready!=true)Companion.update{it.copy(authenticated=fresh,connection=if(fresh)"Internet retrying" else "Internet unavailable; last-known readings")}
    }
    fun canRequestSleep(macId: String): Boolean {
        val now = Instant.now()
        val serverNow = now.plus(serverOffset)
        val state = Companion.state.value
        return credential?.macId == macId && commandStorageAvailable && pending == null &&
            !waitingCommand.hasCommand && state.reachable(now) &&
            (state.snapshot?.get("capabilities") as? JsonObject)?.boolOrNull("sleepNow") == true &&
            ((session?.ready == true && nearbyFresh.reachable(serverNow)) ||
                (foregroundActivity && internet?.ready == true && internetFresh.reachable(serverNow)) ||
                (foregroundActivity && legacyAvailable() && relayFresh.reachable(serverNow)))
    }

    fun send(action: String, duration: Int? = null, settings: ReminderSettings? = null, quiet: Boolean = false, sleepAttempt: SleepAttempt? = null) {
        val now = Instant.now(); val serverNow = now.plus(serverOffset)
        if (action == "sleep_now" && (credential?.macId?.let(::canRequestSleep) != true)) {
            finishSleep(sleepAttempt, SleepOutcome.COULD_NOT_REQUEST_SLEEP)
            return
        }
        val nearby = session?.ready == true && (action=="status" || nearbyFresh.reachable(serverNow))
        val iroh=foregroundActivity && internet?.ready==true && (action=="status" || internetFresh.reachable(serverNow))
        val relay = foregroundActivity && legacyAvailable() && relayFresh.reachable(serverNow)
        val canReadRelay = action == "status" && foregroundActivity && legacyAvailable() && relayFresh.epoch != null
        if ((!nearby && !iroh && !relay && !canReadRelay) || (action != "status" && !Companion.state.value.reachable(now))) { if (!quiet) Companion.update { it.copy(result = "Mac unreachable. No command was queued.") }; return }
        if (pending != null) {
            if(quiet || action=="status")return
            if(action=="refresh_triggers"){
                if(pending?.action!="refresh_triggers" && foregroundActivity && triggerCheckRequestedAt==null){triggerCheckRequestedAt=SystemClock.elapsedRealtime();Companion.update{it.copy(checkingTriggers=true,triggerHistory=it.triggerHistory.copy(checkError=null))}}
                return
            }
            if(pending?.mutation==false && foregroundActivity && waitingCommand.offer(WaitingCommand(action,duration,settings),SystemClock.elapsedRealtime(),routeIdentity())){
                Companion.update{it.copy(busy=true,result="Sending…")}
            }
            return
        }
        if (!commandStorageAvailable && action !in setOf("status", "refresh_triggers", "operation_status")) { Companion.update { it.copy(result = "Controls disabled because saved command outcomes are unavailable") }; return }
        // Both the Check button and the automatic check satisfy this visit.
        // Consume it only after the same authenticated route checks as a tap.
        if (action == "refresh_triggers") checkTriggersOnOpen = false
        val raw = Requests.create(action, serverNow, duration, settings)
        transmit(CommandSubmission(raw, nearby, relay || canReadRelay,iroh), quiet, sleepAttempt = sleepAttempt)
    }
    private fun transmit(submission: CommandSubmission, quiet: Boolean, operationId: String? = null, sleepAttempt: SleepAttempt? = null) {
        val raw = submission.body; val route = submission.route
        val r = obj(raw); val id = r.string("id"); val action = r.string("action"); val mutation = action !in setOf("status", "refresh_triggers", "operation_status")
        val c = credential ?: return
        try {
            val epoch = if (route == "relay") requireNotNull(relayFresh.epoch) else if(route=="iroh")requireNotNull(internet).generation else null
            val record = if (route == "nearby") requireNotNull(session).sealRequest(raw, Instant.now()) else if(route=="iroh")requireNotNull(internet).prepare(raw) else RelayCodec(c.macId, c.deviceId, c.key).seal(raw, id, requireNotNull(epoch), "c2s", "command", Instant.parse(r.string("issuedAt")), Instant.parse(r.string("expiresAt")))
            submission.transmit(journal) {
                pending = Pending(id, action, mutation, route, epoch, Instant.now(), operationId, !quiet || mutation || action == "refresh_triggers")
                if (sleepAttempt != null) {
                    sleepAttempts[id] = sleepAttempt
                    if (sleepAttempts.size > 32) sleepAttempts.remove(sleepAttempts.keys.first())
                }
                if (route == "relay" && action == "status") relayFresh.expectStatus(id, Instant.now().plus(serverOffset))
                Companion.update { it.copy(busy = mutation || waitingCommand.hasCommand,checkingTriggers=action=="refresh_triggers" || triggerCheckRequestedAt!=null,triggerHistory=if(action=="refresh_triggers")it.triggerHistory.copy(checkError=null) else it.triggerHistory,result = if (mutation) "Sending…" else it.result) }
                if (route == "nearby") ble.send(record)
                else if(route=="iroh")requireNotNull(internet).sendRecord(record)
                else network.execute {
                    val result = runCatching { require(http(c).call("send", envelope = record).boolOrNull("accepted") == true) }
                    main.post { if (pending?.id == id) { if (pending?.fastPoll == true) nextRemotePoll = 0; if (result.isFailure) deliveryLost() } }
                }
            }
        } catch (_: Exception) {
            if (pending?.id == id) deliveryLost() else {
                if (action == "sleep_now") finishSleep(sleepAttempt, SleepOutcome.COULD_NOT_REQUEST_SLEEP)
                else Companion.update { it.copy(result = "Command was not submitted; secure preparation failed") }
                if (route == "nearby") ble.close("Secure command preparation failed")
            }
        }
    }
    private fun response(message: JsonObject, route: String, epoch: String?) {
        val p = pending ?: return
        if (message.string("id") != p.id || p.route != route || (route != "nearby" && p.epoch != epoch)) return
        val now = Instant.now(); val parsed = Response.parse(message.toString(), now.plus(serverOffset))
        val originalSleep = p.operationId?.takeIf { id ->
            journal.unresolved().any { it.id == id && obj(it.body).string("action") == "sleep_now" }
        }
        if (p.mutation) journal.reconcile(p.id, parsed.status)
        p.operationId?.let { original ->
            if (parsed.status == "ok") { require(message.string("operationId") == original); journal.reconcile(original, message.string("operationStatus")) }
            reconciledThisConnection.add(original)
        }
        if (route == "relay" && p.action == "status" && parsed.status == "ok") parsed.snapshot?.let {
            val accepted=relayFresh.status(p.id, requireNotNull(epoch), it, now.plus(serverOffset))
            android.util.Log.d("KeepressoTransport","relay status accepted=$accepted ${relayFresh.diagnostic(now.plus(serverOffset))}")
            if(accepted)nextRemoteStatus=now.epochSecond+30
        }
        if(p.action=="status" && parsed.status=="ok")parsed.snapshot?.let { snapshot ->
            if(route=="iroh")internetFresh.status(requireNotNull(epoch),snapshot,now.plus(serverOffset))
            if(route=="nearby")nearbyFresh.status("$reconnectGeneration",snapshot,now.plus(serverOffset))
            val nearby=nearbyFresh.reachable(now.plus(serverOffset)) && session?.ready==true
            val fresh=nearby || remoteFresh()
            Companion.update{it.copy(authenticated=fresh,connection=if(nearby)"Connected nearby" else "Connected over internet",transport=if(nearby)"Nearby Bluetooth" else "Internet")}
        }
        // Commit only this authenticated, matching explicit response before the live
        // capture-order filter. A newer status may already have arrived while it ran.
        if (p.action == "refresh_triggers") Companion.update {
            val triggers = parsed.snapshot?.get("triggers")?.takeUnless { value -> value == JsonNull }?.jsonObject
            it.copy(triggerHistory = if (parsed.status == "ok") it.triggerHistory.completed(triggers) else it.triggerHistory.failed("Couldn't check triggers"))
        }
        parsed.snapshot?.let { updateSnapshot(it) }
        PhoneReminders.filter(this).acknowledge(credential?.macId ?: return, p.action, parsed.status)
        pending = null
        val sleepOutcome = when {
            p.action == "sleep_now" -> parsed.sleepResult()
            originalSleep != null && parsed.status == "ok" -> parsed.sleepOutcome
            else -> null
        }
        if (sleepOutcome != null) sleepAttempts.remove(originalSleep ?: p.id)?.finish(sleepOutcome)
        Companion.update { it.copy(busy = waitingCommand.hasCommand,checkingTriggers=triggerCheckRequestedAt!=null,lastContact = now, result = sleepOutcome?.label ?: if (p.operationId != null) message.stringOrNull("operationMessage") ?: when (message.stringOrNull("operationStatus")) { "ok" -> "Earlier command acknowledged by Mac"; "error" -> "Earlier command failed on the Mac"; else -> "Command outcome remains uncertain. It will never be retried automatically." } else if (p.mutation) parsed.message ?: when (parsed.status) { "ok" -> "Mac acknowledged the command"; "error" -> "Mac could not complete the command"; else -> "Command outcome uncertain. It will never be retried automatically." } else if(p.action=="refresh_triggers" && it.result=="Couldn't check triggers")null else it.result) }
        if (sleepOutcome != null) Companion.activity(sleepOutcome.label)
        else if (p.mutation || p.operationId != null) Companion.activity("Command outcome: ${if (p.operationId != null) message.stringOrNull("operationStatus") ?: parsed.status else parsed.status}")
        dispatchWaitingCommand()
        if (pending==null && (p.action == "status" || p.operationId != null) && (route == "nearby" || remoteFresh())) reconcileNext(route)
    }
    private fun routeIdentity()=if(session?.ready==true)"nearby:$reconnectGeneration" else if(internet?.ready==true)"iroh:${internet?.generation}" else "relay:${relayFresh.epoch}"
    private fun dispatchWaitingCommand(){
        if(pending!=null)return
        if(waitingCommand.hasCommand){
            val command=waitingCommand.take(SystemClock.elapsedRealtime(),routeIdentity(),foregroundActivity && Companion.state.value.reachable(Instant.now()))
            Companion.update{it.copy(busy=false)}
            if(command!=null)send(command.action,command.duration,command.settings)
            else Companion.update{it.copy(result="Connection changed. Your command wasn't sent; tap again.")}
        }
        if(pending==null && triggerCheckRequestedAt!=null){
            triggerCheckRequestedAt=null
            if(foregroundActivity && Companion.state.value.reachable(Instant.now()))send("refresh_triggers")
            else Companion.update{it.copy(checkingTriggers=false)}
        }
    }
    private fun reconcileNext(route: String) {
        val operation = journal.unresolved().firstOrNull { it.id !in reconciledThisConnection } ?: return
        reconciledThisConnection.add(operation.id)
        transmit(CommandSubmission(Requests.operationStatus(operation.id, operation.digest, Instant.now().plus(serverOffset)), route == "nearby", route == "relay",route=="iroh"), true, operation.id)
    }
    private fun updateSnapshot(snapshot: JsonObject) {
        val now = Instant.now(); val captured = Instant.parse(snapshot.string("capturedAt")); require(captured <= now.plus(serverOffset).plusSeconds(10)); validateSnapshot(snapshot)
        snapshot["internetConfiguration"]?.let{acceptInternetConfiguration(it.toString())}
        // A new response must not revive intent that expired while the read was in flight.
        discardStaleWait(now)
        val existing = Companion.state.value.snapshot?.stringOrNull("capturedAt")?.let(Instant::parse)
        if (existing != null && captured < existing) return
        ReminderDelivery.snapshot(this, snapshot)
        Companion.update { it.copy(snapshot = snapshot, triggerHistory = it.triggerHistory.telemetry(snapshot["triggers"]?.takeUnless { value -> value == JsonNull }?.jsonObject), receivedAt = minOf(captured.minus(serverOffset),now), lastContact = now) }
    }
    private fun discardStaleWait(now:Instant){
        if(waitingCommand.hasCommand && !Companion.state.value.reachable(now) && waitingCommand.clear())
            Companion.update{it.copy(busy=pending?.mutation==true,result="Status became stale. Your command wasn't sent; tap again.")}
    }
    private fun deliveryLost() {
        val p = pending ?: return; pending = null
        val unsent=waitingCommand.clear()
        triggerCheckRequestedAt=null
        if (p.action == "sleep_now") sleepAttempts[p.id]?.finish(SleepOutcome.COULD_NOT_REQUEST_SLEEP)
        Companion.update { it.copy(busy = false,checkingTriggers=false,triggerHistory=if(p.action=="refresh_triggers")it.triggerHistory.failed("Couldn't check triggers") else it.triggerHistory,result = if (p.action == "sleep_now") SleepOutcome.COULD_NOT_REQUEST_SLEEP.label else if (p.mutation || p.operationId != null) "Command outcome uncertain. It will never be retried automatically." else if(unsent)"Mac didn't respond. Your command wasn't sent." else it.result) }
        if (p.mutation) Companion.activity("Connection lost before command acknowledgement — outcome uncertain")
    }
    private fun disconnected() {
        val lostNearbyAuthority=session?.ready==true || pending?.route=="nearby"
        if(lostNearbyAuthority){
            triggerCheckRequestedAt=null;Companion.update{it.copy(checkingTriggers=false)}
            if(waitingCommand.clear())Companion.update{it.copy(busy=false,result="Connection changed. Your command wasn't sent; tap again.")}
        }
        reconnectGeneration++;nearbyFresh.disconnect(); session = null; invitation = null; reconciledThisConnection.clear()
        if (pending?.route == "nearby") deliveryLost()
        val remoteReady=enabled && remoteFresh()
        Companion.update { it.copy(authenticated = remoteReady,transport=if(remoteReady)"Internet" else it.transport) }; nextRemotePoll = 0
    }
    override fun onDestroy() {
        enabled = false;internet?.close();internet=null;internetFresh.disconnect(); recovery.stable(); recoveryAt = null
        if (radioReceiverRegistered) { unregisterReceiver(radioReceiver); radioReceiverRegistered = false }
        waitingCommand.clear();deliveryLost(); main.removeCallbacksAndMessages(null); if (::ble.isInitialized) ble.close(null); network.shutdownNow(); Companion.service = null; super.onDestroy()
    }
}
object Notifications {
    private val posted = linkedSetOf<Int>()
    private const val THERMAL_ID = 2
    private fun thermalTag(macId: String) = "keepresso.thermal.$macId"
    fun updateConnection(c: Context, text: String) { runCatching { c.getSystemService(NotificationManager::class.java).notify(1, connection(c, text)) } }
    const val URGENT_CHANNEL = "urgent_warnings_v1"
    fun channels(c: Context) {
        val manager = c.getSystemService(NotificationManager::class.java)
        // Existing channels retain the owner's sound/importance choices. A versioned new
        // category is necessary because Android cannot change an existing channel's audio usage.
        val urgent = manager.getNotificationChannel(URGENT_CHANNEL) ?: NotificationChannel(URGENT_CHANNEL, "Urgent Mac warnings", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Heat and sleep problems"
            setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM), AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
            enableVibration(true); vibrationPattern = longArrayOf(0, 350, 150, 350)
        }
        urgent.setBypassDnd(manager.isNotificationPolicyAccessGranted)
        manager.createNotificationChannels(listOf(NotificationChannel("nearby", "Nearby connection", NotificationManager.IMPORTANCE_LOW), NotificationChannel("reminders", "Routine reminders", NotificationManager.IMPORTANCE_DEFAULT), urgent))
    }
    private fun open(c: Context, id: Int) = PendingIntent.getActivity(c, id, Intent(c, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    fun connection(c: Context, text: String): Notification = NotificationCompat.Builder(c, "nearby").setSmallIcon(R.drawable.keepresso_menu_idle).setContentTitle("Keepresso nearby").setContentText(text).setContentIntent(open(c, 0)).setOngoing(true).build()
    private fun canPost(c: Context) = Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(c, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun warningBuilder(c: Context, id: Int, title: String, body: String, kind: String, macId: String, createdAt: Instant): NotificationCompat.Builder {
        val routine = kind == "hourly"
        return NotificationCompat.Builder(c, if (routine) "reminders" else URGENT_CHANNEL).setSmallIcon(R.drawable.keepresso_menu_brewing).setContentTitle(title).setContentText(body).setStyle(NotificationCompat.BigTextStyle().bigText(body)).setContentIntent(open(c, id)).setAutoCancel(true)
            .setPriority(if(routine) NotificationCompat.PRIORITY_DEFAULT else NotificationCompat.PRIORITY_MAX)
            .setCategory(if(routine) NotificationCompat.CATEGORY_REMINDER else NotificationCompat.CATEGORY_ALARM)
            .addExtras(Bundle().apply { putString("keepresso.kind",kind);putString("keepresso.mac",macId);putLong("keepresso.created",createdAt.toEpochMilli()) })
    }

    fun reminder(c: Context, id: Int, title: String, body: String, kind: String, macId: String, createdAt: Instant) {
        if (!canPost(c)) return
        val b = warningBuilder(c, id, title, body, kind, macId, createdAt)
        if (kind == "hourly") for ((action, label) in listOf("ack" to "OK", "snooze" to "Snooze 6 hours")) b.addAction(0, label, PendingIntent.getActivity(c, id xor action.hashCode(), Intent(c, ReminderActionActivity::class.java).setAction(action).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP).putExtra("notificationId", id).putExtra("macId", macId), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        b.addAction(0, "Open", open(c, id)); val manager = c.getSystemService(NotificationManager::class.java); posted.add(id); while (posted.size > 24) manager.cancel(posted.first().also { posted.remove(it) }); manager.notify(id, b.build())
    }

    fun thermal(c: Context, title: String, body: String, macId: String, eventId: String, warning: ThermalWarning) {
        if (!canPost(c)) return
        val builder = warningBuilder(c, THERMAL_ID, title, body, "thermal", macId, warning.createdAt)
            .setOnlyAlertOnce(false)
            .addExtras(Bundle().apply {
                putString("keepresso.thermalSeverity", warning.level.wireValue)
                putString("keepresso.eventId", eventId)
            })
        if (warning.level == ThermalWarningLevel.SERIOUS) {
            val intent = Intent(c, ThermalSnoozeReceiver::class.java)
                .setData(Uri.fromParts("keepresso-thermal", eventId, null)).putExtra("macId", macId)
            val snooze = PendingIntent.getBroadcast(c, 0, intent, PendingIntent.FLAG_IMMUTABLE)
            builder.addAction(0, "Snooze 30 min", snooze)
        }
        val manager = c.getSystemService(NotificationManager::class.java)
        clearLegacyThermal(manager, macId)
        manager.notify(thermalTag(macId), THERMAL_ID, builder.addAction(0, "Open", open(c, THERMAL_ID)).build())
    }

    private fun activeThermal(manager: NotificationManager, macId: String) = manager.activeNotifications.filter {
        it.notification.extras.getString("keepresso.mac") == macId &&
            it.notification.extras.getString("keepresso.kind") == "thermal"
    }

    fun isSnoozableHeatAlertActive(c: Context, macId: String, eventId: String): Boolean =
        activeThermal(c.getSystemService(NotificationManager::class.java), macId).any {
            val extras = it.notification.extras
            extras.getString("keepresso.eventId") == eventId &&
                extras.getString("keepresso.thermalSeverity") == ThermalWarningLevel.SERIOUS.wireValue
        }

    fun clearThermal(c: Context, macId: String) {
        val manager = c.getSystemService(NotificationManager::class.java)
        manager.cancel(thermalTag(macId), THERMAL_ID)
        clearLegacyThermal(manager, macId)
    }

    // Before upgrading, heat alerts used one untagged notification per event.
    private fun clearLegacyThermal(manager: NotificationManager, macId: String) {
        activeThermal(manager, macId).filter { it.tag == null }.forEach {
            manager.cancel(it.id)
            posted.remove(it.id)
        }
    }

    fun cancelResolved(c: Context, macId: String, snapshot: JsonObject, latestThermal: ThermalWarning?) {
        val captured = Instant.parse(snapshot.string("capturedAt")).toEpochMilli()
        val m = snapshot["mac"] as? JsonObject; val k = snapshot["keepresso"] as? JsonObject
        val manager = c.getSystemService(NotificationManager::class.java)
        // The system may not have applied the preceding notify call yet.
        if (latestThermal?.isSupersededBy(snapshot) == true) manager.cancel(thermalTag(macId), THERMAL_ID)
        manager.activeNotifications.forEach { item ->
            val extras = item.notification.extras
            if (extras.getString("keepresso.mac") != macId) return@forEach
            val kind = extras.getString("keepresso.kind")
            val created = extras.getLong("keepresso.created", Long.MAX_VALUE)
            if (kind != "thermal" && created >= captured) return@forEach
            val resolved = when(kind) {
                "lid_awake" -> m?.stringOrNull("lid") == "open"
                "thermal" -> item.tag == null &&
                    ThermalWarning(Instant.ofEpochMilli(created), ThermalWarningLevel.LEGACY).isSupersededBy(snapshot)
                "hourly" -> k?.boolOrNull("isActive") == false
                "session_ended_awake", "sleep_failed" -> k?.boolOrNull("isActive") == true
                else -> false
            }
            if (resolved) {
                manager.cancel(item.tag, item.id)
                if (item.tag == null) posted.remove(item.id)
            }
        }
    }
}

object PhoneReminders {
    private fun preferences(c: Context) = c.getSharedPreferences("reminders", Context.MODE_PRIVATE)
    fun until(c: Context, macId: String): Instant? = preferences(c).getLong("snoozeUntil.$macId", 0).takeIf { it > Instant.now().epochSecond }?.let(Instant::ofEpochSecond)
    fun filter(c: Context): LocalSnooze = LocalSnooze({ macId -> preferences(c).getLong("snoozeUntil.$macId", 0) }, { macId, value ->
        val editor = preferences(c).edit(); if (value == null) editor.remove("snoozeUntil.$macId") else editor.putLong("snoozeUntil.$macId", value); editor.apply()
        if (Companion.state.value.macId == macId) Companion.update { it.copy(localSnoozedUntil = value?.let(Instant::ofEpochSecond)) }
    })
}

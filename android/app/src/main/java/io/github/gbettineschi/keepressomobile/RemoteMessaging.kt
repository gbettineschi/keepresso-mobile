package io.github.gbettineschi.keepressomobile

import android.app.Application
import android.content.Context
import androidx.work.*
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import io.github.gbettineschi.keepressomobile.core.*
import java.time.Instant
import kotlinx.serialization.json.*

class KeepressoApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // Provider-specific setup is optional; no generated credentials or project enter git.
        if (listOf(BuildConfig.FIREBASE_APPLICATION_ID, BuildConfig.FIREBASE_API_KEY, BuildConfig.FIREBASE_PROJECT_ID, BuildConfig.FIREBASE_SENDER_ID).all { it.isNotBlank() }) {
            runCatching {
                FirebaseApp.initializeApp(this, FirebaseOptions.Builder().setApplicationId(BuildConfig.FIREBASE_APPLICATION_ID).setApiKey(BuildConfig.FIREBASE_API_KEY).setProjectId(BuildConfig.FIREBASE_PROJECT_ID).setGcmSenderId(BuildConfig.FIREBASE_SENDER_ID).build())
                PushRegistration.configurationChanged(this)
            }
        }
    }
}
object PushRegistration {
    private val tokenLock = Any()
    private val registrationLock = Any()
    private val network = java.util.concurrent.Executors.newSingleThreadExecutor()
    fun configured(): Boolean = listOf(BuildConfig.FIREBASE_APPLICATION_ID, BuildConfig.FIREBASE_API_KEY, BuildConfig.FIREBASE_PROJECT_ID, BuildConfig.FIREBASE_SENDER_ID).all { it.isNotBlank() }
    private fun preferences(c: Context) = c.getSharedPreferences("push", Context.MODE_PRIVATE)
    private fun save(c: Context, token: String) = synchronized(tokenLock) {
        require(token.toByteArray(Charsets.UTF_8).size in 1..4096 && token.none { it.isISOControl() || it.isWhitespace() })
        require(preferences(c).edit().putString("token", token).commit())
    }
    private fun configuration(c: Context): PushRelayConfig? = CredentialStore(c).load()?.let { credential ->
        val url = credential.relayUrl; val ticket = credential.relayAuthTicket
        if (url == null || ticket == null) null else PushRelayConfig(url, credential.macId, credential.deviceId, RelayCodec(credential.macId, credential.deviceId, credential.key).bearer(), ticket)
    }
    private fun enrollment(c: Context): PushEnrollment = PushEnrollment(
        configuration = { configuration(c) },
        loadToken = { preferences(c).getString("token", null) },
        saveToken = { save(c, it) },
        loadMarker = { preferences(c).getString("registered", null) },
        saveMarker = { require(preferences(c).edit().putString("registered", it).commit()) },
        upload = { target, token -> require(target.http().call("push", token = token).boolOrNull("registered") == true) },
        tokenTransaction = { block -> synchronized(tokenLock) { block() } },
    )
    private fun enqueue(c: Context) {
        val target = configuration(c)
        if (target == null) { WorkManager.getInstance(c).cancelUniqueWork("relay-push-registration"); return }
        val work = OneTimeWorkRequestBuilder<PushRegistrationWorker>()
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setInputData(workDataOf("configurationId" to target.identity))
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, java.util.concurrent.TimeUnit.SECONDS)
            .build()
        WorkManager.getInstance(c).enqueueUniqueWork("relay-push-registration", ExistingWorkPolicy.REPLACE, work)
    }
    fun configurationChanged(c: Context) {
        val context = c.applicationContext
        // Commit durable work as well as trying immediately while the nearby session is alive.
        runCatching { enqueue(context) }
        network.execute {
            runCatching {
                synchronized(registrationLock) {
                    enrollment(context).configurationReceived { received ->
                        if (configured()) FirebaseMessaging.getInstance().token.addOnSuccessListener { token ->
                            network.execute {
                                runCatching { synchronized(registrationLock) { received(token) } }
                                runCatching { enqueue(context) }
                            }
                        }
                    }
                }
            }
        }
    }
    fun tokenChanged(c: Context, token: String) {
        val context = c.applicationContext
        // Persist before returning from FCM; WorkManager survives process exit and has no BLE dependency.
        runCatching { save(context, token); enqueue(context) }
    }
    internal fun registerStored(c: Context, expectedIdentity: String) = synchronized(registrationLock) { enrollment(c).registerStoredToken(expectedIdentity) }
}
class PushRegistrationWorker(context: Context, parameters: WorkerParameters) : Worker(context, parameters) {
    override fun doWork(): Result {
        val identity = inputData.getString("configurationId") ?: return Result.success()
        return runCatching { PushRegistration.registerStored(applicationContext, identity); Result.success() }
            .getOrElse { if (PushRetry.retry(it, runAttemptCount)) Result.retry() else Result.failure() }
    }
}

class RelayMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) { PushRegistration.tokenChanged(this, token) }
    override fun onMessageReceived(message: RemoteMessage) {
        runCatching {
            val credential = CredentialStore(this).load() ?: return
            if (credential.relayUrl == null || credential.relayAuthTicket == null) return
            val direct = message.data["relayEnvelope"]
            if (direct != null) RelayEventDelivery.deliver(this, credential, direct)
            else if (message.data["relayWake"] == "1" && message.data["macId"] == credential.macId && message.data["deviceId"] == credential.deviceId) {
                // Only a durable, bounded worker may fetch for a hint; the hint itself cannot notify.
                val work = OneTimeWorkRequestBuilder<RelayHintWorker>()
                    .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                    .setInputData(workDataOf("macId" to credential.macId, "deviceId" to credential.deviceId, "queuedAt" to Instant.now().epochSecond))
                    .build()
                WorkManager.getInstance(this).enqueueUniqueWork("relay-hint.${credential.macId}.${credential.deviceId}", ExistingWorkPolicy.REPLACE, work)
            }
        }
    }
}

/** One attempt with the HTTP client's 15-second deadline, never a background polling loop. */
class RelayHintWorker(context: Context, parameters: WorkerParameters) : Worker(context, parameters) {
    override fun doWork(): Result {
        return runCatching {
            val now = Instant.now(); val queuedAt = inputData.getLong("queuedAt", 0)
            if (queuedAt <= 0 || now.epochSecond - queuedAt !in 0..299 || isStopped) return Result.success()
            val credential = CredentialStore(applicationContext).load() ?: return Result.success()
            if (inputData.getString("macId") != credential.macId || inputData.getString("deviceId") != credential.deviceId) return Result.success()
            val url = credential.relayUrl ?: return Result.success(); val ticket = credential.relayAuthTicket ?: return Result.success()
            val codec = RelayCodec(credential.macId, credential.deviceId, credential.key)
            val poll = RelayHttp(RelayEndpoint(url), credential.macId, credential.deviceId, codec.bearer(), ticket).call("poll")
            val messages = poll.getValue("messages").jsonArray; require(messages.size <= 32)
            messages.forEach { if (it.jsonObject.string("kind") == "event" && !isStopped) RelayEventDelivery.deliver(applicationContext, credential, it.toString()) }
            Result.success()
        }.getOrElse { Result.failure() }
    }
}
private object RelayEventDelivery {
    fun deliver(context: Context, credential: Credential, encoded: String) {
        val now = Instant.now()
        val opened = RelayCodec(credential.macId, credential.deviceId, credential.key).open(encoded, now, "s2c", setOf("event"))
        val r = obj(opened.plaintext); require(r.string("type") == "event")
        val event = r.getValue("event").jsonObject; require(event.string("id") == opened.id)
        ReminderDelivery.post(context, credential, event, now)
    }
}

object ReminderDelivery {
    private val lock = Any()
    fun snapshot(c: Context, value: JsonObject) = synchronized(lock) { val store = CredentialStore(c); store.writePrivate("latestSnapshot", value.toString()); store.load()?.let { Notifications.cancelResolved(c, it.macId, value) } }
    fun reset(c: Context) = synchronized(lock) { CredentialStore(c).clear() }
    fun replace(c: Context, credential: Credential) = synchronized(lock) { val store = CredentialStore(c); store.clearPrivateState(); store.save(credential) }
    fun post(c: Context, credential: Credential, event: JsonObject, now: Instant) = synchronized(lock) {
        val macId = credential.macId
        val store = CredentialStore(c)
        val current = store.load() ?: return@synchronized
        if (current.macId != macId || current.deviceId != credential.deviceId || !java.security.MessageDigest.isEqual(current.key, credential.key)) return@synchronized
        val snapshot = store.readPrivate("latestSnapshot")?.let(::obj)
        val claims = EventClaims({ store.readPrivate("eventClaims") }, { store.writePrivate("eventClaims", it) })
        if (!claims.claim(macId, event, now, snapshot)) return@synchronized
        val kind = event.string("kind")
        if (PhoneReminders.filter(c).suppressed(macId, kind, now)) return@synchronized
        val title = event.string("title").take(120); val body = event.string("body").take(1000)
        Notifications.channels(c)
        Notifications.reminder(c, event.string("id").hashCode(), title, body, kind, macId, Instant.parse(event.string("createdAt")))
        Companion.activity(title)
    }
}

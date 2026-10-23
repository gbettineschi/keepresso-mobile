package io.github.gbettineschi.keepressomobile

import android.app.Application
import android.content.Context
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import io.github.gbettineschi.keepressomobile.core.*
import java.time.Instant
import kotlinx.serialization.json.*

class KeespressoApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // Provider-specific setup is optional; no generated credentials or project enter git.
        if (listOf(BuildConfig.FIREBASE_APPLICATION_ID, BuildConfig.FIREBASE_API_KEY, BuildConfig.FIREBASE_PROJECT_ID, BuildConfig.FIREBASE_SENDER_ID).all { it.isNotBlank() }) {
            runCatching {
                FirebaseApp.initializeApp(this, FirebaseOptions.Builder().setApplicationId(BuildConfig.FIREBASE_APPLICATION_ID).setApiKey(BuildConfig.FIREBASE_API_KEY).setProjectId(BuildConfig.FIREBASE_PROJECT_ID).setGcmSenderId(BuildConfig.FIREBASE_SENDER_ID).build())
                FirebaseMessaging.getInstance().token.addOnSuccessListener { PushRegistration.save(this, it) }
            }
        }
    }
}
object PushRegistration {
    fun configured(): Boolean = listOf(BuildConfig.FIREBASE_APPLICATION_ID, BuildConfig.FIREBASE_API_KEY, BuildConfig.FIREBASE_PROJECT_ID, BuildConfig.FIREBASE_SENDER_ID).all { it.isNotBlank() }
    fun save(c: Context, token: String) { if (token.length in 1..4096) c.getSharedPreferences("push", Context.MODE_PRIVATE).edit().putString("token", token).apply() }
    fun token(c: Context): String? = c.getSharedPreferences("push", Context.MODE_PRIVATE).getString("token", null)
}

class RelayMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) { PushRegistration.save(this, token) }
    override fun onMessageReceived(message: RemoteMessage) {
        runCatching {
            val credential = CredentialStore(this).load() ?: return
            val url = credential.relayUrl ?: return
            val ticket = credential.relayAuthTicket ?: return
            val codec = RelayCodec(credential.macId, credential.deviceId, credential.key)
            val direct = message.data["relayEnvelope"]
            val envelopes = if (direct != null) listOf(direct) else {
                // A content-free hint can cause one bounded authenticated fetch, never a notification by itself.
                if (message.data["relayWake"] != "1" || message.data["macId"] != credential.macId || message.data["deviceId"] != credential.deviceId) return
                val poll = RelayHttp(RelayEndpoint(url), credential.macId, credential.deviceId, codec.bearer(), ticket).call("poll")
                val values = poll.getValue("messages").jsonArray; require(values.size <= 32)
                values.filter { it.jsonObject.string("kind") == "event" }.map { it.toString() }
            }
            envelopes.forEach { encoded ->
                val opened = codec.open(encoded, Instant.now(), "s2c", setOf("event"))
                val r = obj(opened.plaintext); require(r.string("type") == "event")
                val event = r.getValue("event").jsonObject; require(event.string("id") == opened.id)
                ReminderDelivery.post(this, credential, event, Instant.now())
            }
        }
    }
}

object ReminderDelivery {
    private val lock = Any()
    fun snapshot(c: Context, value: JsonObject) = synchronized(lock) { CredentialStore(c).writePrivate("latestSnapshot", value.toString()) }
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
        Notifications.reminder(c, event.string("id").hashCode(), title, body, kind == "hourly", macId)
        Companion.activity(title)
    }
}

package io.github.gbettineschi.keepressomobile

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import io.github.gbettineschi.keepressomobile.core.*
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.serialization.json.*

data class Credential(val macId: String, val deviceId: String, val name: String, val key: ByteArray, val relayUrl: String? = null, val relayAuthTicket: String? = null)
class CredentialStore(context: Context) {
    private val prefs = context.getSharedPreferences("credentials", Context.MODE_PRIVATE)
    // Stable Keystore alias: retain access to already encrypted pairing state.
    private val alias = "keespresso.credentials.v1"
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build()); generateKey()
        }
    }
    fun readPrivate(name: String): String? {
        val blob = prefs.getString(name, null) ?: return null
        val bytes = decode64(blob); require(bytes.size > 28)
        val c = Cipher.getInstance("AES/GCM/NoPadding"); c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        return String(c.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8)
    }
    fun load(): Credential? = readPrivate("wrapped")?.let { text ->
        val r = obj(text)
        Credential(canonicalId(r.string("macId")), canonicalId(r.string("deviceId")), r.string("name"), decode64(r.string("key"), 32), r.stringOrNull("relayUrl")?.also { RelayEndpoint(it) }, r.stringOrNull("relayAuthTicket")?.also { decode64(it, 32) })
    }
    fun writePrivate(name: String, value: String) {
        val c = Cipher.getInstance("AES/GCM/NoPadding"); c.init(Cipher.ENCRYPT_MODE, key())
        require(prefs.edit().putString(name, encode64(c.iv + c.doFinal(value.toByteArray(Charsets.UTF_8)))).commit())
    }
    fun save(value: Credential) {
        writePrivate("wrapped", buildJsonObject { put("macId", value.macId); put("deviceId", value.deviceId); put("name", value.name); put("key", encode64(value.key)); value.relayUrl?.let { RelayEndpoint(it); put("relayUrl", it) }; value.relayAuthTicket?.let { decode64(it, 32); put("relayAuthTicket", it) } }.toString())
    }
    fun deviceId(): String = prefs.getString("deviceId", null) ?: UUID.randomUUID().toString().also { require(prefs.edit().putString("deviceId", it).commit()) }
    fun clearPrivateState() { require(prefs.edit().remove("mutationJournal").remove("eventClaims").remove("latestSnapshot").commit()) }
    fun clear() { require(prefs.edit().clear().commit()); KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry(alias) } }
}

package io.github.gbettineschi.keepressomobile.core

import kotlinx.serialization.json.*

private fun validFirebaseProject(value: String) = Regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$").matches(value)
data class FirebaseClientConfiguration(val projectId: String, val applicationId: String, val apiKey: String, val senderId: String) {
    init {
        val parts = applicationId.split(':')
        require(validFirebaseProject(projectId) && senderId.length in 1..32 && senderId.all { it in '0'..'9' })
        require(parts.size == 4 && parts[0] == "1" && parts[1] == senderId && parts[2] == "android" && parts[3].length in 1..128 && parts[3].all { it in "0123456789abcdefABCDEF" })
        require(apiKey.length in 1..256 && apiKey.all { it.code in 33..126 })
    }
    fun json() = buildJsonObject { put("projectId",projectId);put("applicationId",applicationId);put("apiKey",apiKey);put("senderId",senderId) }
    companion object { fun decode(r: JsonObject) = FirebaseClientConfiguration(r.string("projectId"),r.string("applicationId"),r.string("apiKey"),r.string("senderId")) }
}

data class InternetConfiguration(val endpointId: String, val firebase: FirebaseClientConfiguration? = null) {
    init { decode64(endpointId,32) }
    fun encoded() = buildJsonObject { put("type","internet_config");put("version",1);put("endpointId",endpointId);firebase?.let { put("firebase",it.json()) } }.toString()
    companion object {
        fun decode(text: String): InternetConfiguration {
            require(text.toByteArray(Charsets.UTF_8).size <= 16384)
            val r = obj(text); val version = r.getValue("version").jsonPrimitive
            require(r.string("type") == "internet_config" && !version.isString && version.intOrNull == 1)
            return InternetConfiguration(r.string("endpointId"),r["firebase"]?.takeUnless { it == JsonNull }?.jsonObject?.let(FirebaseClientConfiguration::decode))
        }
    }
}

data class PushRegistration(val projectId: String, val token: String, val revision: Long) {
    init { require(validFirebaseProject(projectId) && revision > 0 && token.length in 1..4096 && token.all { it.code in 33..126 }) }
    val tokenHash: String get() = bodyDigest(token)
    fun encoded() = buildJsonObject { put("type","push_registration");put("projectId",projectId);put("token",token);put("revision",revision) }.toString()
    companion object {
        fun decode(text: String): PushRegistration {
            require(text.toByteArray(Charsets.UTF_8).size <= 8192)
            val r=obj(text); require(r.string("type")=="push_registration")
            val revision=r.getValue("revision").jsonPrimitive;require(!revision.isString)
            return PushRegistration(r.string("projectId"),r.string("token"),requireNotNull(revision.longOrNull))
        }
    }
}

data class PushRegistrationAck(val projectId: String, val revision: Long, val tokenHash: String) {
    init { require(validFirebaseProject(projectId) && revision > 0);decode64(tokenHash,32) }
    fun matches(value: PushRegistration) = projectId==value.projectId && revision==value.revision && tokenHash==value.tokenHash
    fun encoded() = buildJsonObject { put("type","push_registered");put("projectId",projectId);put("revision",revision);put("tokenHash",tokenHash) }.toString()
    companion object {
        fun decode(text: String): PushRegistrationAck {
            require(text.toByteArray(Charsets.UTF_8).size <= 1024)
            val r=obj(text); require(r.string("type")=="push_registered")
            val revision=r.getValue("revision").jsonPrimitive;require(!revision.isString)
            return PushRegistrationAck(r.string("projectId"),requireNotNull(revision.longOrNull),r.string("tokenHash"))
        }
    }
}

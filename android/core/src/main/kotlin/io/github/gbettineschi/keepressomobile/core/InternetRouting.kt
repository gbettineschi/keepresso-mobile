package io.github.gbettineschi.keepressomobile.core

import java.time.Instant
import java.time.Duration
import kotlinx.serialization.json.*

/** Separate metadata; neither this store nor a failed update can replace the pairing. */
class InternetEnrollmentStore(private val macId:String,private val deviceId:String,key:ByteArray,load:()->String?,private val save:(String)->Unit) {
    private val fingerprint=bodyDigest(encode64(key))
    var configuration:InternetConfiguration?=null;private set
    init {
        canonicalId(macId);canonicalId(deviceId);require(key.size==32)
        load()?.let { text ->
            require(text.toByteArray().size<=20000)
            val r=obj(text)
            require(r.string("macId")==macId && r.string("deviceId")==deviceId && r.string("fingerprint")==fingerprint)
            configuration=InternetConfiguration.decode(r.getValue("configuration").toString())
        }
    }
    fun accept(text:String,authenticated:Boolean):InternetConfiguration {
        require(authenticated)
        val next=InternetConfiguration.decode(text)
        if(next==configuration)return next
        val record=buildJsonObject{put("macId",macId);put("deviceId",deviceId);put("fingerprint",fingerprint);put("configuration",obj(next.encoded()))}.toString()
        save(record);configuration=next;return next
    }
}

/** A handshake is not evidence of an awake Mac. Only a matching status is. */
class InternetFreshness {
    var generation:String?=null;private set
    private var proof:Instant?=null
    private var capture:Instant?=null
    fun connected(generation:String){this.generation=generation;proof=null;capture=null}
    fun disconnect(){generation=null;proof=null;capture=null}
    fun status(generation:String,snapshot:JsonObject,now:Instant):Boolean {
        if(this.generation!=generation)return false
        val captured=Instant.parse(snapshot.string("capturedAt"))
        if(captured>now.plusSeconds(10) || captured<now.minusSeconds(15))return false
        proof=now;capture=minOf(captured,now);return true
    }
    fun reachable(now:Instant):Boolean = generation!=null && proof?.let{Duration.between(it,now).toMillis() in 0..14999}==true && capture?.let{Duration.between(it,now).toMillis() in 0..14999}==true
}

/** Independent transport identity, reused after reconnect/process restart. */
class InternetEndpointIdentity(private val load:()->String?,private val save:(String)->Unit) {
    fun loadOrCreate():ByteArray {
        val encoded=load()
        if(encoded!=null){
            require(encoded.toByteArray().size<=512)
            val record=obj(encoded);val version=record.getValue("version").jsonPrimitive
            require(!version.isString && version.intOrNull==1)
            return decode64(record.string("seed"),32)
        }
        val seed=randomNonce()
        save(buildJsonObject{put("version",1);put("seed",seed)}.toString())
        return decode64(seed,32)
    }
}

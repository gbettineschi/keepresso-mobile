package io.github.gbettineschi.keepressomobile.core

import java.time.Instant
import kotlinx.serialization.json.*

/** Caller serializes load/change/save across SDK callbacks and background workers. */
class DirectPushEnrollment(load:()->String?,private val save:(String)->Unit) {
    private var current:PushRegistration?=null
    private var acknowledged:PushRegistrationAck?=null
    val revision get()=current?.revision ?: 0L
    init {
        load()?.let {text ->
            require(text.toByteArray().size<=16000)
            val state=obj(text)
            current=state["current"]?.let{PushRegistration.decode(it.toString())}
            acknowledged=state["ack"]?.let{PushRegistrationAck.decode(it.toString())}
            require(acknowledged==null || current?.let{acknowledged?.matches(it)}==true)
        }
    }
    private fun persist(next:PushRegistration?,ack:PushRegistrationAck?) {
        save(buildJsonObject{next?.let{put("current",obj(it.encoded()))};ack?.let{put("ack",obj(it.encoded()))}}.toString())
        current=next;acknowledged=ack
    }
    fun tokenChanged(project:String,token:String) {
        if(current?.projectId==project && current?.token==token)return
        require(revision<Long.MAX_VALUE)
        persist(PushRegistration(project,token,revision+1),null)
    }
    fun tokenRequested(project:String,token:String,expectedRevision:Long):Boolean {
        if(revision!=expectedRevision)return false
        tokenChanged(project,token);return true
    }
    fun pending(project:String):PushRegistration?=current?.takeIf{it.projectId==project && acknowledged?.matches(it)!=true}
    fun acknowledge(ack:PushRegistrationAck):Boolean {
        val current=current ?: return false
        if(!ack.matches(current))return false
        persist(current,ack);return true
    }
}

object DirectPushEvent {
    fun decode(codec:RelayCodec,encoded:String,now:Instant):JsonObject {
        require(encoded.toByteArray(Charsets.UTF_8).size<=3000)
        val opened=codec.open(encoded,now,"s2c",setOf("event"))
        val message=obj(opened.plaintext)
        require(message.string("type")=="event")
        val event=message.getValue("event").jsonObject
        require(event.string("id")==opened.id)
        return event
    }
}

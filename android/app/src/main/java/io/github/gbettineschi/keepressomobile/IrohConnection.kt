package io.github.gbettineschi.keepressomobile

import android.content.Context
import computer.iroh.*
import io.github.gbettineschi.keepressomobile.core.*
import java.nio.ByteBuffer
import java.time.Instant
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.serialization.json.*

/** One transport, one fresh application cipher, no stored or retried power intent. */
class IrohConnection(context:Context,private val credential:Credential,private val configuration:InternetConfiguration,
                     private val message:(JsonObject,String)->Unit,private val disconnected:(String)->Unit) {
    companion object {val ALPN="keepresso-mobile/iroh/1".toByteArray()}
    val generation=UUID.randomUUID().toString()
    private val scope=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate)
    private val output=Channel<String>(8)
    private val endpointLease=AtomicReference<IrohEndpoints.Lease?>()
    private val connection=AtomicReference<Connection?>()
    private var session:ClientSession?=null
    private var phase="starting"
    private var deadline:Job?=null
    @Volatile private var closed=false
    val ready get()=!closed && session?.ready==true
    init {
        IrohAndroid.installAndroidContext(context.applicationContext)
        scope.launch {
            try {
                armDeadline(25_000)
                withTimeout(25_000) {
                    phase="binding"
                    val endpoint=withContext(Dispatchers.IO){
                        val lease=IrohEndpoints.acquire(context.applicationContext)
                        endpointLease.set(lease)
                        if(closed){releaseEndpoint();throw CancellationException("Connection closed")}
                        lease.endpoint
                    }
                    val id=EndpointId.fromBytes(decode64(configuration.endpointId,32))
                    phase="connecting"
                    val connected=connect(endpoint,id)
                    require(connected.remoteId()==id)
                    phase="opening"
                    val bi=withContext(Dispatchers.IO){connected.openBi()}
                    phase="authenticating"
                    val cipher=ClientSession(credential.macId,credential.deviceId,credential.key)
                    session=cipher
                    write(bi,cipher.hello())
                    write(bi,cipher.challenge(read(bi)))
                    val ready=obj(cipher.receive(read(bi),Instant.now()))
                    message(ready,generation)
                    phase="reading"
                    // Return this stream to an outer loop, so the connect deadline
                    // does not become a fixed maximum lifetime for healthy sessions.
                    bi
                }.let { bi ->
                    scope.launch {try{for(record in output)write(bi,record)}catch(_:Exception){close()}}
                    while(isActive && !closed) {
                        val record=withTimeout(25_000){read(bi)}
                        message(obj(requireNotNull(session).receive(record,Instant.now())),generation)
                    }
                }
            }catch(_:CancellationException){}catch(e:Exception){if(!closed)android.util.Log.w("KeepressoTransport","Internet connection closed at $phase (${e.javaClass.simpleName})")}
            finally{close();disconnected(generation)}
        }
    }
    fun prepare(raw:String):String {check(ready);return requireNotNull(session).sealRequest(raw,Instant.now())}
    fun prepareRegistration(registration:io.github.gbettineschi.keepressomobile.core.PushRegistration):String {check(ready);return requireNotNull(session).registerPush(registration)}
    fun sendRecord(record:String){check(ready);check(output.trySend(record).isSuccess)}
    fun close() {
        if(closed)return
        closed=true;deadline?.cancel();deadline=null;output.close();session=null
        closeNativeConnection();releaseEndpoint();scope.cancel()
    }
    private fun closeNativeConnection(){runCatching{connection.getAndSet(null)?.close(0L,byteArrayOf())}}
    private fun releaseEndpoint(){endpointLease.getAndSet(null)?.let{IrohEndpoints.releaseSoon(it)}}
    private suspend fun connect(endpoint:Endpoint,id:EndpointId):Connection {
        // Address publication can briefly contain no route during Mac startup.
        // Retry only TLS dialing before application authentication or any command.
        repeat(3){attempt ->
            try{return withContext(Dispatchers.IO){
                val connected=endpoint.connect(EndpointAddr(id=id,relayUrl=null,addresses=emptyList()),ALPN)
                connection.set(connected)
                if(closed){closeNativeConnection();throw CancellationException("Connection closed")}
                connected
            }}
            catch(e:CancellationException){throw e}
            catch(e:Exception){if(attempt==2)throw e;delay(2_000)}
        }
        error("Dial attempts exhausted")
    }
    private fun armDeadline(milliseconds:Long){
        deadline?.cancel()
        deadline=scope.launch{delay(milliseconds);close()}
    }
    private suspend fun write(stream:BiStream,record:String){
        val bytes=record.toByteArray();require(bytes.size in 1..65536)
        withContext(Dispatchers.IO){stream.send().writeAll(ByteBuffer.allocate(4).putInt(bytes.size).array()+bytes)}
    }
    private suspend fun read(stream:BiStream):String {
        armDeadline(25_000)
        val first=withContext(Dispatchers.IO){stream.recv().readExact(1u)}
        armDeadline(10_000)
        return withContext(Dispatchers.IO) {
            val length=ByteBuffer.wrap(first+stream.recv().readExact(3u)).int
            require(length in 1..65536)
            stream.recv().readExact(length.toUInt()).decodeToString(throwOnInvalidSequence=true)
        }
    }
}

package io.github.gbettineschi.keepressomobile

import android.content.Context
import computer.iroh.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.concurrent.atomic.AtomicBoolean

/** One local endpoint; independent authenticated sessions share its network identity. */
internal object IrohEndpoints {
    private val mutex=Mutex()
    private val cleanup=CoroutineScope(SupervisorJob()+Dispatchers.IO)
    private var current:Entry?=null
    private var idleClose:Job?=null
    internal class Entry(val endpoint:Endpoint,val secret:ByteArray,var users:Int=0)
    internal class Lease(private val entry:Entry) {
        private val released=AtomicBoolean()
        val endpoint get()=entry.endpoint
        suspend fun release(){
            if(!released.compareAndSet(false,true))return
            mutex.withLock {
                check(current===entry && entry.users>0)
                entry.users--
                if(entry.users==0){
                    // A reconnect reuses its relay route instead of immediately
                    // tearing it down and racing another bind of the same identity.
                    idleClose=cleanup.launch {
                        delay(15_000)
                        mutex.withLock {
                            if(current===entry && entry.users==0){
                                try{entry.endpoint.shutdown()}finally{current=null;idleClose=null}
                            }
                        }
                    }
                }
            }
        }
    }
    suspend fun acquire(context:Context):Lease=mutex.withLock {
        idleClose?.cancel();idleClose=null
        val secret=InternetCredentialStore.endpointSecret(CredentialStore(context))
        val entry=current ?: Entry(Endpoint.bind(EndpointOptions(preset=presetN0(),secretKey=secret,relayMode=RelayMode.defaultMode())),secret).also{current=it}
        require(entry.secret.contentEquals(secret))
        entry.users++
        Lease(entry)
    }
    fun releaseSoon(lease:Lease){cleanup.launch{lease.release()}}
}

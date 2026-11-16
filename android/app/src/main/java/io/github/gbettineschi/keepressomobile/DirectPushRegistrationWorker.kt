package io.github.gbettineschi.keepressomobile

import android.content.Context
import androidx.work.*
import com.google.firebase.messaging.FirebaseMessaging
import io.github.gbettineschi.keepressomobile.core.*
import kotlinx.coroutines.*
import java.util.concurrent.TimeUnit

object DirectPushRegistration {
    private val lock=Any()
    private fun state(store:CredentialStore)=DirectPushEnrollment({store.readPrivate("directPushRegistration")},{store.writePrivate("directPushRegistration",it)})
    fun configurationChanged(context:Context):Boolean {
        val options=FirebaseClientSetup.stored(context) ?: return false
        WorkManager.getInstance(context).cancelUniqueWork("relay-push-registration")
        WorkManager.getInstance(context).cancelAllWorkByTag("legacy-relay-hint")
        if(!FirebaseClientSetup.configure(context,options)){
            Companion.update{it.copy(result="Restart Keepresso Mobile to finish notification setup.")};return true
        }
        val revision=synchronized(lock){state(CredentialStore(context)).revision}
        FirebaseMessaging.getInstance().token.addOnSuccessListener{token ->
            runCatching {
                if(FirebaseClientSetup.stored(context)!=options || FirebaseClientSetup.current()!=options)return@addOnSuccessListener
                synchronized(lock){state(CredentialStore(context)).tokenRequested(options.projectId,token,revision)}
                enqueue(context)
            }
        }
        enqueue(context);return true
    }
    fun tokenChanged(context:Context,token:String):Boolean {
        val options=FirebaseClientSetup.stored(context) ?: return false
        if(FirebaseClientSetup.current()!=options)return true
        runCatching {synchronized(lock){state(CredentialStore(context)).tokenChanged(options.projectId,token)};enqueue(context)}
        return true
    }
    fun connectionAvailable(context:Context){runCatching{enqueue(context)}}
    private fun enqueue(context:Context) {
        val options=FirebaseClientSetup.stored(context) ?: return
        val store=CredentialStore(context)
        val pending=synchronized(lock){state(store).pending(options.projectId)} ?: return
        val credential=store.load() ?: return
        val identity=bodyDigest("${credential.macId}/${credential.deviceId}/${encode64(credential.key)}/${options.projectId}")
        val work=OneTimeWorkRequestBuilder<DirectPushRegistrationWorker>()
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setBackoffCriteria(BackoffPolicy.LINEAR,30,TimeUnit.SECONDS)
            .setInputData(workDataOf("identity" to identity,"revision" to pending.revision)).build()
        WorkManager.getInstance(context).enqueueUniqueWork("direct-push-registration",ExistingWorkPolicy.REPLACE,work)
    }
    suspend fun register(context:Context,identity:String,revision:Long) {
        val store=CredentialStore(context);val credential=store.load() ?: return
        val configuration=InternetCredentialStore(store,credential).configuration ?: return
        val project=configuration.firebase?.projectId ?: return
        if(bodyDigest("${credential.macId}/${credential.deviceId}/${encode64(credential.key)}/$project")!=identity)return
        val registration=synchronized(lock){state(store).pending(project)} ?: return
        if(registration.revision!=revision)return
        withContext(Dispatchers.Main.immediate) {
            val result=CompletableDeferred<PushRegistrationAck>()
            var link:IrohConnection?=null
            try {
                withTimeout(45_000) {
                    link=IrohConnection(context,credential,configuration,{message,_ ->
                        when(message.string("type")) {
                            "ready" -> link?.let{it.sendRecord(it.prepareRegistration(registration))}
                            "push_registered" -> result.complete(PushRegistrationAck.decode(message.toString()))
                            "push_registration_error" -> result.completeExceptionally(IllegalStateException("Mac notification setup unavailable"))
                        }
                    },{if(!result.isCompleted)result.completeExceptionally(java.io.IOException("Mac unreachable"))})
                    val ack=result.await()
                    val current=store.load()
                    if(current?.macId==credential.macId && current.deviceId==credential.deviceId && current.key.contentEquals(credential.key))
                        synchronized(lock){state(store).acknowledge(ack)}
                }
            }finally{link?.close()}
        }
    }
}

internal suspend fun directRegistrationAttempt(register:suspend()->Unit):ListenableWorker.Result {
    return try{register();ListenableWorker.Result.success()}
    catch(_:TimeoutCancellationException){ListenableWorker.Result.retry()}
    catch(e:CancellationException){throw e}
    catch(_:Exception){ListenableWorker.Result.retry()}
}

class DirectPushRegistrationWorker(context:Context,parameters:WorkerParameters):CoroutineWorker(context,parameters) {
    override suspend fun doWork():Result {
        val identity=inputData.getString("identity") ?: return Result.success()
        return directRegistrationAttempt{DirectPushRegistration.register(applicationContext,identity,inputData.getLong("revision",0))}
    }
}

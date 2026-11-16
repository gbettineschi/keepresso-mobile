package io.github.gbettineschi.keepressomobile

import android.content.Context
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging
import io.github.gbettineschi.keepressomobile.core.FirebaseClientConfiguration

object FirebaseClientSetup {
    @Volatile var restartRequired=false;private set
    private fun options(c:FirebaseClientConfiguration)=FirebaseOptions.Builder().setApplicationId(c.applicationId).setApiKey(c.apiKey).setProjectId(c.projectId).setGcmSenderId(c.senderId).build()
    @Synchronized fun configure(context:Context,configuration:FirebaseClientConfiguration):Boolean {
        return runCatching {
            val desired=options(configuration)
            val existing=runCatching{FirebaseApp.getInstance()}.getOrNull()
            if(existing?.options!=desired){existing?.delete();FirebaseApp.initializeApp(context.applicationContext,desired)}
            restartRequired=false;true
        }.getOrElse{restartRequired=true;false}
    }
    fun current():FirebaseClientConfiguration?=runCatching {
        if(restartRequired)return null
        val o=FirebaseApp.getInstance().options
        FirebaseClientConfiguration(requireNotNull(o.projectId),o.applicationId,o.apiKey,requireNotNull(o.gcmSenderId))
    }.getOrNull()
    fun stored(context:Context):FirebaseClientConfiguration?=runCatching {
        val store=CredentialStore(context);val credential=store.load() ?: return null
        InternetCredentialStore(store,credential).configuration?.firebase
    }.getOrNull()
}

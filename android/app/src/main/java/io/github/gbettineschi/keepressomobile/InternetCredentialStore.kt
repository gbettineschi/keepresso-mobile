package io.github.gbettineschi.keepressomobile

import io.github.gbettineschi.keepressomobile.core.*

class InternetCredentialStore(store:CredentialStore,credential:Credential) {
    companion object {
        @Synchronized fun endpointSecret(store:CredentialStore):ByteArray = InternetEndpointIdentity(
            {store.readPrivate("internetEndpointIdentity")},{store.writePrivate("internetEndpointIdentity",it)}).loadOrCreate()
    }
    private val metadata=InternetEnrollmentStore(credential.macId,credential.deviceId,credential.key,{store.readPrivate("internetEnrollment")},{store.writePrivate("internetEnrollment",it)})
    val configuration get()=metadata.configuration
    fun acceptAuthenticated(text:String)=metadata.accept(text,true)
}

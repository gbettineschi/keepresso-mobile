package io.github.gbettineschi.keepressomobile.core

data class PushRelayConfig(val url: String, val macId: String, val deviceId: String, val bearer: String, val authTicket: String) {
    init { RelayEndpoint(url); canonicalId(macId); canonicalId(deviceId); decode64(bearer, 32); decode64(authTicket, 32) }
    fun http(): RelayHttp = RelayHttp(RelayEndpoint(url), macId, deviceId, bearer, authTicket)
    fun registrationMarker(token: String): String = bodyDigest("${RelayEndpoint(url).url}\n$macId\n$deviceId\n$bearer\n$authTicket\n$token")
}

/** Both nearby configuration and Firebase rotation enter this same bounded registration flow. */
class PushEnrollment(
    private val configuration: () -> PushRelayConfig?,
    private val loadToken: () -> String?,
    private val saveToken: (String) -> Unit,
    private val loadMarker: () -> String?,
    private val saveMarker: (String) -> Unit,
    private val upload: (PushRelayConfig, String) -> Unit,
    private val tokenTransaction: (() -> Unit) -> Unit = { it() },
) {
    fun configurationReceived(requestToken: ((String) -> Unit) -> Unit) {
        // Validate and capture the owner-provided endpoint/ticket before asking Firebase for a token.
        configuration() ?: return
        val previous = loadToken()
        requestToken { token ->
            tokenTransaction {
                val current = loadToken()
                // A rotation received while getToken was in flight wins over its older callback.
                if (current == previous || current == token) { validateToken(token); saveToken(token) }
            }
            registerStoredToken()
        }
        registerStoredToken()
    }
    fun tokenChanged(token: String) { tokenTransaction { validateToken(token); saveToken(token) }; registerStoredToken() }
    fun registerStoredToken() {
        val target = configuration() ?: return
        val token = loadToken() ?: return
        validateToken(token)
        val marker = target.registrationMarker(token)
        if (loadMarker() == marker) return
        upload(target, token)
        saveMarker(marker)
    }
    private fun validateToken(token: String) { require(token.toByteArray(Charsets.UTF_8).size in 1..4096 && token.none { it.isISOControl() || it.isWhitespace() }) }
}

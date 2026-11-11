package com.xmtx.im.client

import kotlinx.coroutines.withContext

/** One signed-in account activation owns HTTP admission across foreground/background and reconnects.
 * The caller drains its business workers and native resource owners before closeAndDrain.
 * Login/bootstrap and post-retirement revocation intentionally use their separate credential owner.
 */
class AccountNetworkActivity(val scheduler:AccountWorkScheduler=AccountWorkScheduler()) {
    val networkDiagnostics get()=scheduler.networkDiagnostics
    private var authorization: Pair<AuthSession, AuthSessionEpoch>? = null
    private fun epoch(auth: AuthSession): AuthSessionEpoch = synchronized(this) {
        val existing = authorization
        if (existing != null) {
            if (existing.first !== auth) throw ClientFailure.SessionInvalidated()
            existing.second
        } else auth.currentEpoch().also { authorization = auth to it }
    }
    fun authenticated(auth:AuthSession,transport:EdgeTransport,account:UserId,device:DeviceId):AuthenticatedTransport=
        AuthenticatedApi(auth,transport,account,device,scheduler,epoch(auth))
    suspend fun access(auth:AuthSession,rejectedAccess:Credentials?=null):Credentials=
        withContext(NetworkWorkScope(scheduler,NetworkWorkContext("authentication",NetworkWorkPriority.Critical,NetworkWorkKind.Authentication))) {
            auth.access(rejectedAccess, expectedEpoch = epoch(auth))
        }
    fun recoveryScope()=NetworkWorkScope(scheduler,NetworkWorkContext("account",NetworkWorkPriority.Recovery))
    suspend fun closeAndDrain() {
        val bound = synchronized(this) { authorization }
        bound?.let { (auth, epoch) -> auth.cancelRefreshAndDrain(epoch) }
        scheduler.closeAndDrain()
    }
}

package com.xmtx.im.client

/** Independent, non-secret exit intent. Implementations must durably commit before returning. */
interface LocalExitMarker {
    suspend fun isPending(): Boolean
    suspend fun markPending()
    suspend fun clearPending()
}

/** Cleanup routing only; neither credentials nor permission to reopen an account. */
data class LocalExitAccount(val user: UserId, val device: DeviceId)

class LocalExitFailure(val reason: Reason) : Exception("Local exit state: ${reason.name}") {
    enum class Reason { Unavailable, Malformed }
}

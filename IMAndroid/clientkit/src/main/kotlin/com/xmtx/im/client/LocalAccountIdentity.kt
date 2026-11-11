package com.xmtx.im.client

/** Opaque process-local lifetime. A different AuthSession never owns this epoch. */
class AuthSessionEpoch internal constructor() {
    override fun toString() = "AuthSessionEpoch(<opaque>)"
}

/** Device-bound local identity only; contains no tokens and grants no network/display authority. */
data class LocalAccountIdentity internal constructor(val userId: UserId, val deviceId: DeviceId,
    val epoch: AuthSessionEpoch)

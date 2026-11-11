package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentMap

/** Durable invalidation versions contain no presentation content or authorization. */
data class ProfileFence(val securityRevision: Long = 0,val aliasRevision: Long = 0,val nicknameRevision: Long = 0,val minimumProfileRevision: Long = 0) {
    init { require(securityRevision >= 0 && aliasRevision >= 0 && nicknameRevision >= 0 && minimumProfileRevision >= 0) }
}
data class ProfileFenceSnapshot(val generation: String,val floors: PersistentMap<ProfileKey,ProfileFence>)

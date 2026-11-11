package com.xmtx.im.client

import kotlinx.collections.immutable.*

/** Account-local text facts. No lease, avatar identifier, URL or resource authority. */
data class LocalProfileDisplay(val key: ProfileKey, val identity: PublicIdentity,
    val profileRevision: Long, val visibilityRevision: Long, val contextRevision: Long,
    val alias: ProfileAlias?, val groupName: ProfileGroupName?, val observedAt: Long) {
    init {
        require(identity.user == key.user && profileRevision > 0 && visibilityRevision > 0 && contextRevision >= 0)
        require(alias == null || alias.target == key.user)
        require(groupName == null || groupName.user == key.user && key.context == ProfileContext.Room(groupName.room))
    }
    fun supersedes(old: LocalProfileDisplay) = key == old.key && profileRevision >= old.profileRevision &&
        visibilityRevision >= old.visibilityRevision && contextRevision >= old.contextRevision && observedAt >= old.observedAt &&
        (alias?.revision ?: 0) >= (old.alias?.revision ?: 0) && (groupName?.revision ?: 0) >= (old.groupName?.revision ?: 0)
    companion object {
        fun from(value: AuthorizedProfile): LocalProfileDisplay? = value.view.identity?.takeIf { value.view.state == ProfileState.Active }?.let {
            LocalProfileDisplay(value.lease.key, it, value.view.revision, value.view.visibilityRevision,
                value.lease.contextRevision, value.alias, value.groupName, value.lease.observedAt)
        }
    }
}

/** Shared public identity and the current account's own remark, independently versioned. */
data class LocalProfileBasics(val identity: PublicIdentity, val profileRevision: Long,
    val visibilityRevision: Long, val alias: ProfileAlias?) {
    init { require(profileRevision > 0 && visibilityRevision > 0 && (alias == null || alias.target == identity.user)) }
    companion object {
        fun merge(value: LocalProfileDisplay, old: LocalProfileBasics? = null): LocalProfileBasics {
            require(old == null || old.identity.user == value.key.user)
            val newer = old == null || value.profileRevision >= old.profileRevision && value.visibilityRevision >= old.visibilityRevision
            return LocalProfileBasics(if (newer) value.identity else old!!.identity,
                if (newer) value.profileRevision else old!!.profileRevision,
                if (newer) value.visibilityRevision else old!!.visibilityRevision,
                value.alias?.takeIf { it.revision >= (old?.alias?.revision ?: 0) } ?: old?.alias)
        }
    }
}

data class LocalProfileDisplaySnapshot(val records: PersistentMap<ProfileKey, LocalProfileDisplay> = persistentMapOf(),
    val basics: PersistentMap<UserId, LocalProfileBasics> = persistentMapOf(),
    val deniedKeys: PersistentSet<ProfileKey> = persistentSetOf(), val deniedUsers: PersistentSet<UserId> = persistentSetOf()) {
    data class Value(val name: String, val identity: PublicIdentity)
    fun value(key: ProfileKey): Value? {
        if (key in deniedKeys || key.user in deniedUsers) return null
        val basic = basics[key.user] ?: return null
        val scoped = records[key]
        val remark = when (key.context) {
            ProfileContext.Relationship, ProfileContext.DirectConversation -> basic.alias?.name
            is ProfileContext.Room, is ProfileContext.GroupJoinReview -> if (scoped?.alias != null) basic.alias?.name else null
        }
        return Value(remark ?: scoped?.groupName?.name ?: basic.identity.displayName, basic.identity)
    }
}

/** Commit only accepted page results, atomically against the exact durable fences used by that page. */
fun interface LocalProfileDisplaySaving {
    suspend fun save(results: PersistentList<ProfileReadResult>, expected: ProfileFenceSnapshot): Boolean
}

/** Null means the captured durable fences changed; it never means permission to use stale text. */
fun interface LocalProfileDisplayReading {
    suspend fun load(keys: PersistentList<ProfileKey>, expected: ProfileFenceSnapshot): LocalProfileDisplaySnapshot?
}

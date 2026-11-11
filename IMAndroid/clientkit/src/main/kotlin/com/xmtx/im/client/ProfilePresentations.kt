package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.toPersistentList
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.*
import java.text.Normalizer

/** Full lookup identity. A user ID alone never authorizes a profile read. */
sealed interface ProfileContext {
    data object Relationship : ProfileContext
    data object DirectConversation : ProfileContext
    data class Room(val room: RoomId) : ProfileContext { init { uuidId(room.value) } }
    data class GroupJoinReview(val room: RoomId) : ProfileContext { init { uuidId(room.value) } }
}
data class ProfileKey(val user: UserId, val context: ProfileContext) {
    init { uuidId(user.value) }
    internal fun payload() = buildJsonObject {
        put("userID",wireId(user.value))
        put("context",buildJsonObject { when(val scope = context) {
            ProfileContext.Relationship -> put("relationship",buildJsonObject {})
            ProfileContext.DirectConversation -> put("directConversation",buildJsonObject {})
            is ProfileContext.Room -> put("room",buildJsonObject { put("_0",wireId(scope.room.value)) })
            is ProfileContext.GroupJoinReview -> put("groupJoinReview",buildJsonObject { put("_0",wireId(scope.room.value)) })
        } })
    }
}

/** Independent counters form a partial order; never add them or choose a single maximum. */
data class ProfileAuthority(val control: Long, val room: RoomId?, val membership: Long, val permission: Long) {
    init {
        require(control >= 0 && membership >= 0 && permission >= 0)
        require(room != null || membership == 0L && permission == 0L)
        room?.let { uuidId(it.value) }
    }
    fun isAtLeast(other: ProfileAuthority) = control >= other.control && (other.room == null || room == other.room) && membership >= other.membership && permission >= other.permission
    fun merged(other: ProfileAuthority): ProfileAuthority {
        require(room == null || other.room == null || room == other.room)
        return ProfileAuthority(maxOf(control,other.control),room ?: other.room,maxOf(membership,other.membership),maxOf(permission,other.permission))
    }
    internal fun matches(context: ProfileContext, denial: Boolean = false) = when(context) {
        ProfileContext.Relationship -> room == null
        ProfileContext.DirectConversation -> room != null || denial
        is ProfileContext.Room -> room == context.room
        is ProfileContext.GroupJoinReview -> room == context.room
    }
}
enum class ProfileState { Active, Deleted, Suspended, Hidden }
data class ProfileView(val user: UserId, val identity: PublicIdentity?, val avatarMediaId: String?, val state: ProfileState,
    val revision: Long, val visibilityRevision: Long) {
    init {
        uuidId(user.value);require(revision > 0 && visibilityRevision > 0)
        require(if(state == ProfileState.Active) identity?.user == user else identity == null && avatarMediaId == null)
        avatarMediaId?.let { require(uuidId(it) == it) }
    }
}
data class ProfileAlias(val owner: UserId,val target: UserId,val name: String?,val revision: Long) {
    init { uuidId(owner.value);uuidId(target.value);require(revision > 0);name?.let { require(profileLocalName(it) == it) } }
}
data class ProfileGroupName(val room: RoomId,val user: UserId,val name: String?,val revision: Long) {
    init { uuidId(room.value);uuidId(user.value);require(revision > 0);name?.let { require(profileLocalName(it) == it) } }
}
/** Memory-only lease. It must additionally be bound to a live account/page activation by the consumer. */
data class ProfileLease(val actor: UserId,val device: DeviceId,val key: ProfileKey,val profileRevision: Long,
    val visibilityRevision: Long,val contextRevision: Long,val authority: ProfileAuthority,val observedAt: Long,val validUntil: Long) {
    init {
        uuidId(actor.value);require(profileRevision > 0 && visibilityRevision > 0 && contextRevision >= 0)
        require(authority.matches(key.context) && authority.membership == contextRevision)
        val duration = Math.subtractExact(validUntil,observedAt)
        require(duration in 1..300_000)
    }
}
data class AuthorizedProfile(val view: ProfileView,val lease: ProfileLease,val groupName: ProfileGroupName? = null,val alias: ProfileAlias? = null) {
    init {
        require(view.user == lease.key.user && view.revision == lease.profileRevision && view.visibilityRevision == lease.visibilityRevision)
        groupName?.let { require(view.state == ProfileState.Active && lease.key.context == ProfileContext.Room(it.room) && it.user == view.user) }
        alias?.let { require(view.state == ProfileState.Active && it.owner == lease.actor && it.target == view.user && it.owner != it.target) }
    }
    fun displayName(allowsPrivateAlias: Boolean = true): String = when(view.state) {
        ProfileState.Deleted -> "已注销用户"
        ProfileState.Suspended -> "受限用户"
        ProfileState.Hidden -> "资料暂不可用"
        ProfileState.Active -> (if(allowsPrivateAlias) alias?.name else null) ?: groupName?.name ?: view.identity!!.displayName
    }
}
sealed interface ProfileReadResult {
    val key: ProfileKey
    data class Available(val profile: AuthorizedProfile,val deadlineNanos: Long,val avatar: AvatarAccess?=null,val avatarDownloadDeadlineNanos: Long?=null) : ProfileReadResult {
        init {
            require(avatar==null || profile.view.state==ProfileState.Active && profile.view.avatarMediaId==avatar.content.media)
            require((avatar?.plan==null)==(avatarDownloadDeadlineNanos==null))
            require(avatarDownloadDeadlineNanos==null || deadlineNanos-avatarDownloadDeadlineNanos>=0)
        }
        override val key get() = profile.lease.key
        fun valid(nowNanos: Long = System.nanoTime()) = deadlineNanos - nowNanos > 0
    }
    data class Unavailable(override val key: ProfileKey,val authority: ProfileAuthority) : ProfileReadResult {
        init { require(authority.matches(key.context,denial = true)) }
    }
    /** A temporary failure (including an already expired response), never a negative cache entry. */
    data class Retryable(override val key: ProfileKey) : ProfileReadResult
}

object ProfileReadBatch {
    const val MaximumKeys = 100
    const val MaximumAuthorityContexts = 8
    /** Selects one bounded read in input order, preserving complete room/review/direct identity. */
    fun select(keys: Iterable<ProfileKey>, maximumKeys: Int = MaximumKeys): PersistentList<ProfileKey> {
        val limit = maximumKeys.coerceIn(0,MaximumKeys)
        if(limit == 0) return emptyList<ProfileKey>().toPersistentList()
        val contexts = mutableSetOf<ProfileContext>();val direct = mutableSetOf<UserId>();val seen = mutableSetOf<ProfileKey>()
        val result = mutableListOf<ProfileKey>()
        for(key in keys) {
            if(!seen.add(key)) continue
            when(val context = key.context) {
                is ProfileContext.Room,is ProfileContext.GroupJoinReview -> {
                    if(context !in contexts && contexts.size + direct.size >= MaximumAuthorityContexts) continue
                    contexts.add(context)
                }
                ProfileContext.DirectConversation -> {
                    if(key.user !in direct && contexts.size + direct.size >= MaximumAuthorityContexts) continue
                    direct.add(key.user)
                }
                ProfileContext.Relationship -> Unit
            }
            result.add(key);if(result.size == limit) break
        }
        return result.toPersistentList()
    }
    fun payload(keys: PersistentList<ProfileKey>): JsonObject {
        require(keys.isNotEmpty() && keys.size <= MaximumKeys && select(keys) == keys)
        return buildJsonObject { put("keys",JsonArray(keys.map { it.payload() })) }
    }
}

fun interface ProfilePresentationReading {
    suspend fun read(keys: PersistentList<ProfileKey>): PersistentList<ProfileReadResult>
}

/** Memory-only presentation read. A validated avatar descriptor still requires a live scope capability.
 * No result, lease or temporary download plan is serializable or written to storage.
 */
class ProfilePresentationClient(private val transport: AuthenticatedTransport,private val actor: UserId,private val device: DeviceId,
    private val nanoTime: () -> Long = System::nanoTime) : ProfilePresentationReading {
    init { uuidId(actor.value) }
    override suspend fun read(keys: PersistentList<ProfileKey>): PersistentList<ProfileReadResult> {
        val payload = ProfileReadBatch.payload(keys);val started = nanoTime()
        val response = withTimeout(15_000) { transport.requestWithResourcePlans("/v2/profile-presentations/batch",payload,maximumBytes = 2 * 1024 * 1024) }
        currentCoroutineContext().ensureActive()
        if(response.status != 200) throw response.failure()
        return decode(keys,response.body,actor,device,started,nanoTime())
    }
    companion object {
        internal fun decode(keys: PersistentList<ProfileKey>,body: JsonObject,actor: UserId,device: DeviceId,started: Long,received: Long): PersistentList<ProfileReadResult> {
            ProfileReadBatch.payload(keys)
            val now = body.profileNumber("serverNowUnixMilliseconds")
            val values = body["results"] as? JsonArray ?: throw ClientFailure.Protocol()
            if(values.size != keys.size || received - started < 0) throw ClientFailure.Protocol()
            val results = values.map { element ->
                val entry = element as? JsonObject ?: throw ClientFailure.Protocol()
                if(entry.size != 1) throw ClientFailure.Protocol()
                when(entry.keys.single()) {
                    "presentation" -> {
                        val envelope=entry.objectValue("presentation")
                        val value = envelope.objectValue("_0")
                        val profile = decodeProfile(value)
                        val lease = profile.lease
                        if(lease.actor != actor || lease.device != device || lease.observedAt > now || lease.validUntil <= now) throw ClientFailure.Protocol()
                        // Subtract the whole request duration. Client wall-clock changes cannot extend permission.
                        val deadline = started + (lease.validUntil - now) * 1_000_000
                        val access=envelope.profileOptionalObject("avatar")?.let(AvatarAccess::decode)
                        if(access!=null && (profile.view.state!=ProfileState.Active || access.content.media!=profile.view.avatarMediaId)) throw ClientFailure.Protocol()
                        val downloadDeadline=access?.plan?.let { plan ->
                            if(plan.expiresAt<=now || plan.expiresAt>lease.validUntil) throw ClientFailure.Protocol()
                            started+(plan.expiresAt-now)*1_000_000
                        }?.takeIf { it-received>0 }
                        if(deadline - received <= 0) ProfileReadResult.Retryable(lease.key)
                        else ProfileReadResult.Available(profile,deadline,if(downloadDeadline==null) access?.copy(plan=null) else access,downloadDeadline)
                    }
                    "unavailable" -> {
                        val value = entry.objectValue("unavailable").objectValue("_0")
                        ProfileReadResult.Unavailable(decodeKey(value.objectValue("key")),decodeAuthority(value.objectValue("authorityVersion")))
                    }
                    "retryable" -> ProfileReadResult.Retryable(decodeKey(entry.objectValue("retryable").objectValue("_0")))
                    else -> throw ClientFailure.Protocol()
                }
            }
            if(results.map { it.key }.toSet() != keys.toSet() || results.map { it.key }.toSet().size != results.size) throw ClientFailure.Protocol()
            val indexed = results.associateBy { it.key }
            return keys.map { indexed.getValue(it) }.toPersistentList()
        }
        internal fun decodeProfile(value: JsonObject): AuthorizedProfile {
            val raw = value.objectValue("lease")
            val lease = ProfileLease(UserId(raw.profileId("actorUserID")),DeviceId(raw.profileId("deviceID")),decodeKey(raw.objectValue("key")),
                raw.profileNumber("profileRevision"),raw.profileNumber("visibilityRevision"),raw.profileNumber("contextRevision"),decodeAuthority(raw.objectValue("authorityVersion")),
                raw.profileNumber("observedAtUnixMilliseconds"),raw.profileNumber("validUntilUnixMilliseconds"))
            val view = decodeView(value.objectValue("view"))
            val group = value.profileOptionalObject("groupMember")?.let { ProfileGroupName(RoomId(it.profileId("roomID")),UserId(it.profileId("userID")),it.profileOptionalName("groupNickname"),it.profileNumber("revision")) }
            val alias = value.profileOptionalObject("contactAlias")?.let { ProfileAlias(UserId(it.profileId("ownerUserID")),UserId(it.profileId("targetUserID")),it.profileOptionalName("remarkName"),it.profileNumber("revision")) }
            return AuthorizedProfile(view,lease,group,alias)
        }
        internal fun decodeView(v: JsonObject): ProfileView {
            val identity = v.profileOptionalObject("publicIdentity")?.let {
                val handle = it.objectValue("handle").profileString("rawValue")
                val canonical = PublicHandle(handle);if(canonical.value != handle) throw ClientFailure.Protocol()
                val name = Normalizer.normalize(it.profileString("displayName"),Normalizer.Form.NFC).trim { c -> c.isWhitespace() }
                PublicIdentity(UserId(it.profileId("userID")),canonical,name,when(it.profileString("accountKind")) {
                    "regular" -> AccountKind.Regular;"system" -> AccountKind.System;"customer_support" -> AccountKind.CustomerSupport;else -> throw ClientFailure.Protocol()
                })
            }
            val state = when(v.profileString("state")) { "active" -> ProfileState.Active;"deleted" -> ProfileState.Deleted;"suspended" -> ProfileState.Suspended;"hidden" -> ProfileState.Hidden;else -> throw ClientFailure.Protocol() }
            return ProfileView(UserId(v.profileId("userID")),identity,v.profileOptionalObject("avatar")?.profileId("mediaID"),state,v.profileNumber("revision"),v.profileNumber("visibilityRevision"))
        }
        internal fun decodeKey(raw: JsonObject): ProfileKey {
            val context = raw.objectValue("context")
            if(context.size != 1) throw ClientFailure.Protocol()
            val name = context.keys.single();val associated = context.objectValue(name)
            val scope = when(name) {
                "relationship" -> { if(associated.isNotEmpty()) throw ClientFailure.Protocol();ProfileContext.Relationship }
                "directConversation" -> { if(associated.isNotEmpty()) throw ClientFailure.Protocol();ProfileContext.DirectConversation }
                "room" -> ProfileContext.Room(RoomId(associated.profileId("_0")))
                "groupJoinReview" -> ProfileContext.GroupJoinReview(RoomId(associated.profileId("_0")))
                else -> throw ClientFailure.Protocol()
            }
            return ProfileKey(UserId(raw.profileId("userID")),scope)
        }
        internal fun decodeAuthority(raw: JsonObject) = ProfileAuthority(raw.profileNumber("controlSequence"),raw.profileOptionalObject("roomID")?.let { RoomId(uuidId(it.profileString("rawValue"))) },raw.profileNumber("membershipRevision"),raw.profileNumber("permissionRevision"))
    }
}

private fun JsonObject.profileString(key: String) = (get(key) as? JsonPrimitive)?.takeIf { it.isString }?.content ?: throw ClientFailure.Protocol()
private fun JsonObject.profileNumber(key: String) = (get(key) as? JsonPrimitive)?.takeUnless { it.isString }?.longOrNull ?: throw ClientFailure.Protocol()
private fun JsonObject.profileId(key: String) = uuidId(objectValue(key).profileString("rawValue"))
private fun JsonObject.profileOptionalObject(key: String): JsonObject? = when(val value = get(key)) { null,JsonNull -> null;is JsonObject -> value;else -> throw ClientFailure.Protocol() }
private fun JsonObject.profileOptionalName(key: String): String? = when(get(key)) { null,JsonNull -> null;else -> profileString(key).also { if(profileLocalName(it) != it) throw ClientFailure.Protocol() } }
internal fun profileLocalName(input: String): String {
    val value = Normalizer.normalize(input,Normalizer.Form.NFC).trim { it.isWhitespace() }
    require(value.isNotEmpty() && value.toByteArray(Charsets.UTF_8).size <= 80)
    require(value.codePoints().allMatch { !Character.isISOControl(it) && Character.getType(it) != Character.FORMAT.toInt() })
    return value
}

package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import java.text.Normalizer

@Serializable sealed interface ProfileAvatarPatch {
    @Serializable data object Unchanged: ProfileAvatarPatch
    @Serializable data object Remove: ProfileAvatarPatch
    /** Stable media identity only. The server must separately verify a ready, bindable own avatar. */
    @Serializable data class Set(val media: String): ProfileAvatarPatch { init { require(uuidId(media) == media) } }
}
@Serializable data class OwnProfilePatch(val name: String? = null,val avatar: ProfileAvatarPatch = ProfileAvatarPatch.Unchanged) {
    init { require(name != null || avatar != ProfileAvatarPatch.Unchanged);name?.let { require(normalizedName(it) == it) } }
    fun payload() = buildJsonObject {
        put("displayName",buildJsonObject { if(name == null) put("unchanged",buildJsonObject {}) else put("set",buildJsonObject { put("_0",name) }) })
        put("avatar",buildJsonObject { when(avatar) {
            ProfileAvatarPatch.Unchanged -> put("unchanged",buildJsonObject {})
            ProfileAvatarPatch.Remove -> put("remove",buildJsonObject {})
            is ProfileAvatarPatch.Set -> put("set",buildJsonObject { put("_0",buildJsonObject { put("mediaID",wireId(avatar.media)) }) })
        } })
    }
    fun satisfiedBy(profile: ProfileView) = profile.state == ProfileState.Active && (name == null || name == profile.identity?.displayName) && when(avatar) {
        ProfileAvatarPatch.Unchanged -> true
        ProfileAvatarPatch.Remove -> profile.avatarMediaId == null
        is ProfileAvatarPatch.Set -> profile.avatarMediaId == avatar.media
    }
    companion object {
        fun normalizedName(input: String): String {
            val value = Normalizer.normalize(input,Normalizer.Form.NFC).trim { it.isWhitespace() }
            PublicIdentity(UserId("00000000-0000-0000-0000-000000000001"),PublicHandle("profile_update"),value,AccountKind.Regular)
            return value
        }
    }
}
@Serializable data class OwnProfileCommand(val actor: UserId,val operation: String,val revision: Long,val patch: OwnProfilePatch,val deadline: Long) {
    init { uuidId(actor.value);require(uuidId(operation) == operation && revision > 0 && deadline > 0) }
    val fingerprint get() = OperationFingerprint("profileUpdate").apply {
        text("actor",actor.value)
        if(patch.avatar is ProfileAvatarPatch.Set) text("avatar",patch.avatar.media)
        text("avatarAction",when(patch.avatar) { ProfileAvatarPatch.Unchanged -> "unchanged";ProfileAvatarPatch.Remove -> "remove";is ProfileAvatarPatch.Set -> "set" })
        if(patch.name == null) absent("displayName") else text("displayName",patch.name)
        unsigned("expectedRevision",revision);unsigned("firstSubmissionDeadline",deadline);text("operation",operation)
    }.digest()
    fun payload() = buildJsonObject { put("operation_id",operation);put("expected_revision",revision);put("patch",patch.payload());put("first_submission_deadline_ms",deadline) }
    fun identity() = buildJsonObject {
        put("accountID", wireId(actor.value))
        put("scope", buildJsonObject { put("account", buildJsonObject { put("_0", wireId(actor.value)) }) })
        put("operation", buildJsonObject { put("profileUpdate", buildJsonObject { put("_0", wireId(operation)) }) })
    }
    fun recovery(close: Boolean) = buildJsonObject { put("operation_id",operation);put("fingerprint",fingerprintPayload(fingerprint));put("action",if(close) "closeIfAbsent" else "query") }
}
@Serializable enum class OwnProfileStatus { Pending, NeedsAttention, Committed, Conflicted, Rejected, Closed, Expired }
@Serializable data class OwnProfileWork(val command: OwnProfileCommand,val status: OwnProfileStatus = OwnProfileStatus.Pending,
    val submissionStarted: Boolean = false,val reconcile: Boolean = false,val attempts: Int = 0,val roundStarted: Long? = null,
    val nextAttempt: Long = 0,val receipt: String? = null,val reason: String? = null,val draftRetained: Boolean = true) {
    init { require(attempts >= 0 && nextAttempt >= 0 && (roundStarted == null || roundStarted >= 0)) }
    val terminal get() = status !in setOf(OwnProfileStatus.Pending,OwnProfileStatus.NeedsAttention)
}
sealed interface OwnProfileResult {
    /** A later current snapshot does not change the original operation outcome. */
    data class Receipt(val status: OwnProfileStatus,val revision: Long?,val visibilityRevision: Long?,val conflictRevision: Long?,
        val snapshot: ProfileView?,val reason: String?,val wire: String): OwnProfileResult
    data object Unresolved: OwnProfileResult
    data object Conflict: OwnProfileResult
}
interface OwnProfileTransport {
    suspend fun current(): ProfileView
    suspend fun submit(command: OwnProfileCommand): OwnProfileResult.Receipt
    suspend fun recover(command: OwnProfileCommand,close: Boolean): OwnProfileResult
}
class OwnProfileClient(private val api: AuthenticatedTransport,private val actor: UserId): OwnProfileTransport {
    override suspend fun current(): ProfileView = withTimeout(15_000) {
        val response = api.request("/v2/profile/me");if(response.status != 200) throw response.failure()
        decodeProfile(actor,response.body)
    }
    override suspend fun submit(command: OwnProfileCommand): OwnProfileResult.Receipt = withTimeout(15_000) {
        require(command.actor == actor)
        val response = api.putWithoutReplay("/v2/profile/me",command.payload());if(response.status != 200) throw response.failure()
        decodeResult(command,response.body)
    }
    override suspend fun recover(command: OwnProfileCommand,close: Boolean): OwnProfileResult = withTimeout(15_000) {
        require(command.actor == actor)
        val response = api.request("/v2/profile/me/operations/recover",command.recovery(close));if(response.status != 200) throw response.failure()
        val root = response.body;require(root.size == 1)
        when(val kind = root.keys.single()) {
            "receipt" -> {
                val fields = root.objectValue(kind)
                decodeResult(command,buildJsonObject { put("receipt",fields.objectValue("_0"));fields["currentSnapshot"]?.let { put("currentSnapshot",it) } })
            }
            "unresolved" -> { require(root.objectValue(kind).isEmpty());OwnProfileResult.Unresolved }
            "fingerprintConflict" -> { require(root.objectValue(kind).isEmpty());OwnProfileResult.Conflict }
            else -> throw ClientFailure.Protocol()
        }
    }
    companion object {
        fun decodeProfile(actor: UserId,value: JsonObject): ProfileView = ProfilePresentationClient.decodeView(value).also { require(it.user == actor) }
        /** Canonical, known profile fields only; never stores a download plan or presentation lease. */
        fun profilePayload(profile: ProfileView) = buildJsonObject {
            put("userID",wireId(profile.user.value));put("revision",profile.revision);put("visibilityRevision",profile.visibilityRevision)
            put("state",when(profile.state) { ProfileState.Active -> "active";ProfileState.Deleted -> "deleted";ProfileState.Hidden -> "hidden";ProfileState.Suspended -> "suspended" })
            profile.identity?.let { identity -> put("publicIdentity",buildJsonObject {
                put("userID",wireId(identity.user.value));put("handle",buildJsonObject { put("rawValue",identity.handle.value) });put("displayName",identity.displayName)
                put("accountKind",when(identity.kind) { AccountKind.Regular -> "regular";AccountKind.System -> "system";AccountKind.CustomerSupport -> "customer_support" })
            }) }
            profile.avatarMediaId?.let { put("avatar",buildJsonObject { put("mediaID",wireId(it)) }) }
        }
        fun decodeResult(command: OwnProfileCommand,result: JsonObject): OwnProfileResult.Receipt {
            val root = result.objectValue("receipt")
            require(UserId(root.identifier("actorUserID")) == command.actor && uuidId(root.identifier("operationID")) == command.operation)
            val fp = root.objectValue("fingerprint");require(fp.ownNumber("version") == 1L && fp.string("digest") == command.fingerprint)
            require(root.ownNumber("resolvedAtMilliseconds") >= 0)
            val snapshot = when(val raw = result["currentSnapshot"]) { null,JsonNull -> null;is JsonObject -> decodeProfile(command.actor,raw);else -> throw ClientFailure.Protocol() }
            val outcome = root.objectValue("outcome");require(outcome.size == 1)
            var revision: Long? = null;var visibility: Long? = null;var conflict: Long? = null;var reason: String? = null
            val status = when(val kind = outcome.keys.single()) {
                "committed" -> {
                    val fields = outcome.objectValue(kind);revision = fields.ownNumber("revision");visibility = fields.ownNumber("visibilityRevision")
                    // The server returns the same version when the patch was already satisfied.
                    require(revision >= command.revision && revision-command.revision <= 1 && visibility > 0)
                    snapshot?.let {
                        require(it.revision >= revision && it.visibilityRevision >= visibility)
                        if(it.revision == revision) require(it.visibilityRevision == visibility && command.patch.satisfiedBy(it))
                    }
                    OwnProfileStatus.Committed
                }
                "closed" -> { require(outcome.objectValue(kind).isEmpty());OwnProfileStatus.Closed }
                "rejected" -> {
                    val rejection = outcome.objectValue(kind).objectValue("_0");require(rejection.size == 1);reason = rejection.keys.single()
                    val fields = rejection.objectValue(reason)
                    if(reason == "revisionConflict") { conflict = fields.ownNumber("current");require(conflict > 0);OwnProfileStatus.Conflicted }
                    else { require(reason in setOf("avatarUnavailable","expiredUnsubmitted") && fields.isEmpty());OwnProfileStatus.Rejected }
                }
                else -> throw ClientFailure.Protocol()
            }
            val clean = buildJsonObject {
                put("receipt",buildJsonObject {
                    put("actorUserID",wireId(command.actor.value));put("operationID",wireId(command.operation));put("fingerprint",fingerprintPayload(command.fingerprint))
                    put("resolvedAtMilliseconds",root.ownNumber("resolvedAtMilliseconds"))
                    put("outcome",buildJsonObject { when(status) {
                        OwnProfileStatus.Committed -> put("committed",buildJsonObject { put("revision",requireNotNull(revision));put("visibilityRevision",requireNotNull(visibility)) })
                        OwnProfileStatus.Closed -> put("closed",buildJsonObject {})
                        else -> put("rejected",buildJsonObject { put("_0",buildJsonObject { put(requireNotNull(reason),buildJsonObject { conflict?.let { put("current",it) } }) }) })
                    } })
                })
                snapshot?.let { put("currentSnapshot",profilePayload(it)) }
            }
            return OwnProfileResult.Receipt(status,revision,visibility,conflict,snapshot,reason,clean.toString())
        }
    }
}
private fun JsonObject.ownNumber(key: String) = (get(key) as? JsonPrimitive)?.takeUnless { it.isString }?.longOrNull ?: throw ClientFailure.Protocol()
interface OwnProfileStore {
    suspend fun ownProfile(): ProfileView?
    suspend fun ownProfileWorks(): PersistentList<OwnProfileWork>
    /** Exact journal observation; persistent adapters should use their operation primary key. */
    suspend fun ownProfileWork(operation:String): OwnProfileWork? = ownProfileWorks().firstOrNull {it.command.operation==operation}
    suspend fun saveOwnProfile(profile: ProfileView): ProfileView?
    suspend fun enqueueOwnProfile(command: OwnProfileCommand,replaces: String? = null): OwnProfileWork
    suspend fun updateOwnProfile(expected: OwnProfileWork,updated: OwnProfileWork)
    suspend fun discardOwnProfileDraft(operation: String)
}

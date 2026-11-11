package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

@Serializable sealed interface NameTarget {
    @Serializable data class Contact(val user: UserId): NameTarget { init { uuidId(user.value) } }
    @Serializable data class Group(val room: RoomId): NameTarget { init { uuidId(room.value) } }
    val kind get() = if(this is Contact) "contactAlias" else "groupNickname"
    val id get() = when(this) { is Contact -> user.value;is Group -> room.value }
    val key get() = "$kind/$id"
    val path get() = when(this) { is Contact -> "/v2/profile-presentations/contact-aliases/$id";is Group -> "/v2/profile-presentations/groups/$id/nickname" }
}
/** Only the caller's editable field. This does not grant permission to display another profile. */
@Serializable data class NameSnapshot(val actor: UserId,val target: NameTarget,val name: String?,val revision: Long?) {
    init {
        uuidId(actor.value);require(target !is NameTarget.Contact || actor != target.user)
        require(revision == null || revision > 0);require(name == null || revision != null)
        name?.let { require(profileLocalName(it) == it) }
    }
}
@Serializable data class NameCommand(val actor: UserId,val target: NameTarget,val operation: String,val name: String?,val revision: Long?,val deadline: Long) {
    init {
        NameSnapshot(actor,target,name,revision ?: 1);require(uuidId(operation) == operation && deadline > 0)
        require(revision == null || revision in 1 until Long.MAX_VALUE)
    }
    val fingerprint get() = OperationFingerprint(target.kind).apply {
        text("actor",actor.value)
        if(revision == null) absent("expectedRevision") else unsigned("expectedRevision",revision)
        unsigned("firstSubmissionDeadline",deadline)
        if(name == null) absent("name") else text("name",name)
        text("operation",operation);text("target",target.id)
    }.digest()
    fun identity() = when(val value = target) {
        is NameTarget.Contact -> pairIdentity(actor,value.user,operation,target.kind)
        is NameTarget.Group -> roomIdentity(actor,value.room,operation,target.kind)
    }
    fun payload() = buildJsonObject {
        when(target) {
            is NameTarget.Contact -> { put("ownerUserID",wireId(actor.value));put("targetUserID",wireId(target.id));name?.let { put("remarkName",it) } }
            is NameTarget.Group -> { put("actorUserID",wireId(actor.value));put("roomID",wireId(target.id));name?.let { put("nickname",it) } }
        }
        put("operationID",wireId(operation));revision?.let { put("expectedRevision",it) }
        put("firstSubmissionDeadlineMilliseconds",deadline)
    }
    fun recovery(close: Boolean) = buildJsonObject {
        put("identity",identity());put("fingerprint",fingerprintPayload(fingerprint));put("action",if(close) "closeIfAbsent" else "query")
    }
    internal fun validate(value: JsonObject) { when(val target = target) {
        is NameTarget.Contact -> validatePairProof(actor,target.user,operation,target.kind,fingerprint,value)
        is NameTarget.Group -> validateRoomProof(actor,target.room,operation,target.kind,fingerprint,value)
    } }
    companion object {
        fun normalizedName(input: String?): String? = input?.trim { it.isWhitespace() }?.takeIf { it.isNotEmpty() }?.let(::profileLocalName)
    }
}
@Serializable enum class NameStatus { Pending, NeedsAttention, Committed, Conflicted, Rejected, Closed, Cancelled }
@Serializable data class NameWork(val command: NameCommand,val status: NameStatus = NameStatus.Pending,
    val submissionStarted: Boolean = false,val reconcile: Boolean = false,val closeRequested: Boolean = false,
    val attempts: Int = 0,val roundStarted: Long? = null,val nextAttempt: Long = 0,val receipt: String? = null,val reason: String? = null) {
    init { require(attempts >= 0 && nextAttempt >= 0 && (roundStarted == null || roundStarted >= 0)) }
    val terminal get() = status !in setOf(NameStatus.Pending,NameStatus.NeedsAttention)
}
sealed interface NameResult {
    data class Receipt(val status: NameStatus,val snapshot: NameSnapshot?,val reason: String?,val wire: String): NameResult
    data object Unresolved: NameResult
    data object Conflict: NameResult
}
interface NameTransport {
    suspend fun snapshot(actor: UserId,target: NameTarget): NameSnapshot
    suspend fun submit(command: NameCommand): NameResult.Receipt
    suspend fun recover(command: NameCommand,close: Boolean): NameResult
}
class NameOperationClient(private val api: AuthenticatedTransport): NameTransport {
    override suspend fun snapshot(actor: UserId,target: NameTarget): NameSnapshot = withTimeout(15_000) {
        val response = api.request(target.path);if(response.status != 200) throw response.failure()
        decodeSnapshot(actor,target,response.body)
    }
    override suspend fun submit(command: NameCommand): NameResult.Receipt = withTimeout(15_000) {
        val response = api.putWithoutReplay(command.target.path,command.payload());if(response.status != 200) throw response.failure()
        decodeReceipt(command,response.body)
    }
    override suspend fun recover(command: NameCommand,close: Boolean): NameResult = withTimeout(15_000) {
        val response = api.request(command.target.path+"/operations/recover",command.recovery(close));if(response.status != 200) throw response.failure()
        val root = response.body;require(root.size == 1)
        when(val kind = root.keys.single()) {
            "receipt" -> decodeReceipt(command,root.objectValue(kind).objectValue("_0"))
            "unresolved" -> { require(root.objectValue(kind).isEmpty());NameResult.Unresolved }
            "fingerprintConflict" -> { require(root.objectValue(kind).isEmpty());NameResult.Conflict }
            else -> throw ClientFailure.Protocol()
        }
    }
    companion object {
        private fun value(actor: UserId,target: NameTarget,fields: JsonObject): NameSnapshot {
            val nameKey = when(target) {
                is NameTarget.Contact -> {
                    require(UserId(fields.identifier("ownerUserID")) == actor && UserId(fields.identifier("targetUserID")) == target.user);"remarkName"
                }
                is NameTarget.Group -> {
                    require(UserId(fields.identifier("userID")) == actor && RoomId(fields.identifier("roomID")) == target.room);"groupNickname"
                }
            }
            val name = when(val raw = fields[nameKey]) { null,JsonNull -> null;else -> (raw as? JsonPrimitive)?.takeIf { it.isString }?.content ?: throw ClientFailure.Protocol() }
            return NameSnapshot(actor,target,name,fields.nameNumber("revision"))
        }
        fun decodeSnapshot(actor: UserId,target: NameTarget,root: JsonObject): NameSnapshot {
            when(target) {
                is NameTarget.Contact -> require(UserId(root.identifier("ownerUserID")) == actor && UserId(root.identifier("targetUserID")) == target.user)
                is NameTarget.Group -> require(UserId(root.identifier("actorUserID")) == actor && RoomId(root.identifier("roomID")) == target.room)
            }
            return when(val raw = root["value"]) { null,JsonNull -> NameSnapshot(actor,target,null,null);is JsonObject -> value(actor,target,raw);else -> throw ClientFailure.Protocol() }
        }
        fun decodeReceipt(command: NameCommand,root: JsonObject): NameResult.Receipt {
            command.validate(root);require(root.nameNumber("resolvedAtMilliseconds") >= 0)
            val outcome = root.objectValue("outcome");require(outcome.size == 1)
            var snapshot: NameSnapshot? = null;var reason: String? = null
            val status = when(val kind = outcome.keys.single()) {
                "committed" -> {
                    snapshot = value(command.actor,command.target,outcome.objectValue(kind).objectValue("_0"))
                    require(snapshot.name == command.name && snapshot.revision == (command.revision ?: 0)+1);NameStatus.Committed
                }
                "closed" -> { require(outcome.objectValue(kind).isEmpty());NameStatus.Closed }
                "rejected" -> {
                    val rejection = outcome.objectValue(kind).objectValue("_0");require(rejection.size == 1);reason = rejection.keys.single()
                    val fields = rejection.objectValue(reason)
                    if(reason == "revisionConflict") {
                        fields["current"]?.takeUnless { it is JsonNull }?.let { require(fields.nameNumber("current") > 0) };NameStatus.Conflicted
                    } else { require(reason in setOf("permissionDenied","notFound","expiredUnsubmitted") && fields.isEmpty());NameStatus.Rejected }
                }
                else -> throw ClientFailure.Protocol()
            }
            // Persist only the validated original outcome, not unknown response fields or display data.
            val clean = buildJsonObject {
                put("identity",command.identity());put("fingerprint",fingerprintPayload(command.fingerprint));put("resolvedAtMilliseconds",root.nameNumber("resolvedAtMilliseconds"))
                put("outcome",buildJsonObject {
                    when(status) {
                        NameStatus.Committed -> put("committed",buildJsonObject { put("_0",buildJsonObject {
                            when(command.target) {
                                is NameTarget.Contact -> { put("ownerUserID",wireId(command.actor.value));put("targetUserID",wireId(command.target.id));snapshot?.name?.let { put("remarkName",it) } }
                                is NameTarget.Group -> { put("userID",wireId(command.actor.value));put("roomID",wireId(command.target.id));snapshot?.name?.let { put("groupNickname",it) } }
                            }
                            put("revision",requireNotNull(snapshot?.revision))
                        }) })
                        NameStatus.Closed -> put("closed",buildJsonObject {})
                        NameStatus.Conflicted,NameStatus.Rejected -> put("rejected",buildJsonObject { put("_0",buildJsonObject { put(requireNotNull(reason),buildJsonObject {
                            if(status == NameStatus.Conflicted) outcome.objectValue("rejected").objectValue("_0").objectValue("revisionConflict")["current"]?.takeUnless { it is JsonNull }?.let { put("current",it) }
                        }) }) })
                        else -> throw ClientFailure.Protocol()
                    }
                })
            }
            return NameResult.Receipt(status,snapshot,reason,clean.toString())
        }
    }
}
private fun JsonObject.nameNumber(key: String) = (get(key) as? JsonPrimitive)?.takeUnless { it.isString }?.longOrNull ?: throw ClientFailure.Protocol()
interface NameOperationStore {
    suspend fun nameWorks(): PersistentList<NameWork>
    /** Exact journal observation; persistent adapters should use their operation primary key. */
    suspend fun nameWork(operation:String): NameWork? = nameWorks().firstOrNull {it.command.operation==operation}
    suspend fun saveNameSnapshot(snapshot: NameSnapshot): NameSnapshot?
    suspend fun enqueueName(command: NameCommand): NameWork
    suspend fun updateName(expected: NameWork,updated: NameWork)
}

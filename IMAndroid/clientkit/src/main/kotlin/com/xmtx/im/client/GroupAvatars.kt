package com.xmtx.im.client

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

@Serializable sealed interface GroupAvatarMutation {
    @Serializable data object Remove: GroupAvatarMutation
    @Serializable data class Set(val media: String): GroupAvatarMutation { init { require(uuidId(media)==media) } }
    val mediaId: String? get()=(this as? Set)?.media
    fun payload()=buildJsonObject { when(val mutation=this@GroupAvatarMutation) {
        Remove -> put("remove",buildJsonObject {})
        is Set -> put("set",buildJsonObject { put("_0",wireId(mutation.media)) })
    } }
}

/** Persist before sending. Upload completion alone never changes the group avatar. */
@Serializable data class GroupAvatarCommand(val operation: String,val room: RoomId,val revision: Long,val mutation: GroupAvatarMutation) {
    init { require(uuidId(operation)==operation);uuidId(room.value);require(revision>=0) }
    fun payload()=buildJsonObject {
        put("operationID",wireId(operation));put("roomID",wireId(room.value));put("expectedRevision",revision);put("mutation",mutation.payload())
    }
    companion object {
        fun decode(value: JsonObject): GroupAvatarCommand {
            val mutation=value.resourceObject("mutation");require(mutation.size==1)
            val kind=mutation.keys.single();val fields=mutation.resourceObject(kind)
            val change=when(kind) {
                "remove" -> { require(fields.isEmpty());GroupAvatarMutation.Remove }
                "set" -> GroupAvatarMutation.Set(fields.resourceId("_0"))
                else -> throw ClientFailure.Protocol()
            }
            return GroupAvatarCommand(value.resourceId("operationID"),RoomId(value.resourceId("roomID")),value.resourceNumber("expectedRevision"),change)
        }
    }
}

/** Logical state only. Revision zero means never configured; it is not a byte capability. */
@Serializable data class GroupAvatarState(val room: RoomId,val media: String?,val revision: Long) {
    init { uuidId(room.value);media?.let { require(uuidId(it)==it) };require(revision>=0 && (revision>0 || media==null)) }
    companion object { fun decode(value: JsonObject)=GroupAvatarState(RoomId(value.resourceId("roomID")),
        value.resourceOptionalObject("mediaID")?.let { uuidId(it.resourceString("rawValue")) },value.resourceNumber("revision")) }
}
@Serializable data class GroupAvatarChange(val state: GroupAvatarState,val roomSequence: Long,val updatedAt: Long) {
    init { require(state.revision>0 && roomSequence>0) }
    internal fun boundTo(command: GroupAvatarCommand) {
        require(state.room==command.room && state.media==command.mutation.mediaId && command.revision<Long.MAX_VALUE && state.revision==command.revision+1)
    }
    companion object { fun decode(value: JsonObject)=GroupAvatarChange(GroupAvatarState.decode(value.resourceObject("state")),
        value.resourceNumber("roomSequence"),value.resourceNumber("updatedAtUnixMilliseconds")) }
}

/** Only Committed is durable. Other outcomes describe one attempt, not closure of earlier submissions. */
sealed interface GroupAvatarOutcome {
    data class Committed(val change: GroupAvatarChange): GroupAvatarOutcome
    data object RevisionConflict: GroupAvatarOutcome
    data object IdempotencyConflict: GroupAvatarOutcome
    data object ResourceUnavailable: GroupAvatarOutcome
    data object Forbidden: GroupAvatarOutcome
}
@Serializable enum class GroupAvatarRecoveryAction(val wire: String) { Query("query"), CloseIfAbsent("closeIfAbsent") }
@Serializable data class GroupAvatarRecoveryRequest(val command: GroupAvatarCommand,val action: GroupAvatarRecoveryAction) {
    fun payload()=buildJsonObject { put("command",command.payload());put("action",action.wire) }
}
sealed interface GroupAvatarRecoveryResult {
    data class Committed(val change: GroupAvatarChange): GroupAvatarRecoveryResult
    data object Closed: GroupAvatarRecoveryResult
    data object Unresolved: GroupAvatarRecoveryResult
    data object IdempotencyConflict: GroupAvatarRecoveryResult
}
data class GroupAvatarCommandResponse(val actor: UserId,val device: DeviceId,val command: GroupAvatarCommand,val outcome: GroupAvatarOutcome) {
    init { uuidId(actor.value);if(outcome is GroupAvatarOutcome.Committed) outcome.change.boundTo(command) }
}
data class GroupAvatarRecoveryResponse(val actor: UserId,val device: DeviceId,val request: GroupAvatarRecoveryRequest,val result: GroupAvatarRecoveryResult) {
    init {
        uuidId(actor.value);if(result is GroupAvatarRecoveryResult.Committed) result.change.boundTo(request.command)
        require(request.action!=GroupAvatarRecoveryAction.CloseIfAbsent || result!=GroupAvatarRecoveryResult.Unresolved)
    }
}

interface GroupAvatarCommands {
    suspend fun submit(command: GroupAvatarCommand): GroupAvatarCommandResponse
    suspend fun recover(request: GroupAvatarRecoveryRequest): GroupAvatarRecoveryResponse
}

/** HTTP errors, including 410, are hints only. Resolve uncertain work using its full frozen request. */
class GroupAvatarCommandClient(private val api: AuthenticatedTransport,private val actor: UserId,private val device: DeviceId): GroupAvatarCommands {
    init { uuidId(actor.value) }
    override suspend fun submit(command: GroupAvatarCommand): GroupAvatarCommandResponse=withTimeout(15_000) {
        val response=api.requestWithoutReplay("/v2/rooms/${command.room.value}/avatar",command.payload(),16*1024)
        currentCoroutineContext().ensureActive()
        if(response.status !in setOf(200,403,409,422)) throw response.failure()
        // A control-domain denial lacks a room receipt and cannot resolve an older attempt.
        if(response.status==403 && "command" !in response.body) throw response.failure()
        decodeSubmission(response,actor,device,command)
    }
    override suspend fun recover(request: GroupAvatarRecoveryRequest): GroupAvatarRecoveryResponse=withTimeout(15_000) {
        val response=api.requestWithoutReplay("/v2/rooms/${request.command.room.value}/avatar/recovery",request.payload(),16*1024)
        currentCoroutineContext().ensureActive()
        if(response.status!=200) throw response.failure()
        decodeRecovery(response.body,actor,device,request)
    }
    companion object {
        internal fun decodeSubmission(response: EdgeResponse,actor: UserId,device: DeviceId,command: GroupAvatarCommand): GroupAvatarCommandResponse {
            val root=response.body;bind(root,actor,device);require(GroupAvatarCommand.decode(root.resourceObject("command"))==command)
            val outcome=root.resourceObject("outcome");require(outcome.size==1)
            val kind=outcome.keys.single();val fields=outcome.resourceObject(kind)
            val value=when(kind) {
                "committed" -> GroupAvatarOutcome.Committed(GroupAvatarChange.decode(fields.resourceObject("_0")))
                "revisionConflict" -> GroupAvatarOutcome.RevisionConflict
                "idempotencyConflict" -> GroupAvatarOutcome.IdempotencyConflict
                "resourceUnavailable" -> GroupAvatarOutcome.ResourceUnavailable
                "forbidden" -> GroupAvatarOutcome.Forbidden
                else -> throw ClientFailure.Protocol()
            }
            if(value !is GroupAvatarOutcome.Committed) require(fields.isEmpty())
            require(response.status==when(value) {
                is GroupAvatarOutcome.Committed -> 200
                GroupAvatarOutcome.RevisionConflict,GroupAvatarOutcome.IdempotencyConflict -> 409
                GroupAvatarOutcome.ResourceUnavailable -> 422
                GroupAvatarOutcome.Forbidden -> 403
            })
            return GroupAvatarCommandResponse(actor,device,command,value)
        }
        internal fun decodeRecovery(root: JsonObject,actor: UserId,device: DeviceId,request: GroupAvatarRecoveryRequest): GroupAvatarRecoveryResponse {
            bind(root,actor,device);val echoed=root.resourceObject("request")
            require(GroupAvatarCommand.decode(echoed.resourceObject("command"))==request.command && echoed.resourceString("action")==request.action.wire)
            val result=root.resourceObject("result");require(result.size==1)
            val kind=result.keys.single();val fields=result.resourceObject(kind)
            val value=when(kind) {
                "committed" -> GroupAvatarRecoveryResult.Committed(GroupAvatarChange.decode(fields.resourceObject("_0")))
                "closed" -> GroupAvatarRecoveryResult.Closed
                "unresolved" -> GroupAvatarRecoveryResult.Unresolved
                "idempotencyConflict" -> GroupAvatarRecoveryResult.IdempotencyConflict
                else -> throw ClientFailure.Protocol()
            }
            if(value !is GroupAvatarRecoveryResult.Committed) require(fields.isEmpty())
            return GroupAvatarRecoveryResponse(actor,device,request,value)
        }
        private fun bind(root: JsonObject,actor: UserId,device: DeviceId) {
            require(root.resourceId("actorUserID")==actor.value && root.resourceId("deviceID")==device.value)
        }
    }
}

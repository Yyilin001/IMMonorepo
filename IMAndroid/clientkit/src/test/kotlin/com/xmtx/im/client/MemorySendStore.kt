package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import java.util.UUID

/** Serial, volatile fixture for transport tests only. Real persistence and lease fencing have SQLite device tests. */
internal class MemorySendStore: OutboxStore {
    private data class Entry(val command: MessageSendOperation,val state: SendRecovery,val token: String?=null,val lease: Long=0,val receipt: MessageSendOperationReceipt?=null)
    private val entries=linkedMapOf<String,Entry>()
    val commands get()=entries.values.map {it.command}.toPersistentList()
    val receipts get()=entries.mapNotNull {(id,value)->value.receipt?.let {id to it}}.toMap().toPersistentMap()
    fun recovery(operation: String)=entries.getValue(operation).state
    fun seed(command: MessageSendOperation,state: SendRecovery=SendRecovery()) {
        val old=entries[command.clientMessageId]
        require(old==null || old.command==command)
        if(old==null) entries[command.clientMessageId]=Entry(command,state)
    }
    override suspend fun enqueue(command: MessageSendOperation)=seed(command)
    override suspend fun observeSend(attempt:SendAttempt,now:Long):OperationStepObservation? {
        val value=entries[attempt.command.clientMessageId]?.takeIf {it.command==attempt.command} ?: return null
        return value.receipt?.let {
            validateSendReceipt(value.command,it)
            OperationStepObservation(when {it.hasAccepted()->OperationExecutionState.Committed
                it.hasRejected()->OperationExecutionState.Rejected;else->OperationExecutionState.Closed},OperationSchedulingState.Finished)
        } ?: value.state.operationObservation(now,claimed=value.token!=null && value.lease>now)
    }
    fun pending()=entries.values.filter {it.receipt==null}.map {it.command}.toPersistentList()
    override suspend fun claimSend(now: Long): SendAttempt? {
        val blocked=mutableSetOf<String>()
        for((id,entry) in entries) {
            if(entry.receipt!=null || entry.state.status==SendRecoveryStatus.ExpiredUnsubmitted) continue
            if(!blocked.add(entry.command.roomId) || entry.lease>now) continue
            when(val decision=SendRecoveryPolicy.claim(entry.state,now,entry.command.firstSubmissionDeadlineMs)) {
                SendClaimDecision.Wait->Unit
                is SendClaimDecision.Stop->{entries[id]=entry.copy(state=decision.state,token=null,lease=0);if(decision.state.status==SendRecoveryStatus.ExpiredUnsubmitted) blocked.remove(entry.command.roomId)}
                is SendClaimDecision.Ready->{
                    val token=UUID.randomUUID().toString()
                    entries[id]=entry.copy(state=decision.state,token=token,lease=now+SendRecoveryPolicy.LEASE_MILLISECONDS)
                    return SendAttempt(entry.command,token,decision.action,decision.state,isRetry=entry.state.submitted)
                }
            }
        }
        return null
    }
    private fun matching(attempt: SendAttempt)=entries[attempt.command.clientMessageId]?.takeIf {it.command==attempt.command && it.token==attempt.token && it.receipt==null}
    override suspend fun deferSend(attempt: SendAttempt,state: SendRecovery) {
        matching(attempt)?.let {entries[attempt.command.clientMessageId]=it.copy(state=state,token=null,lease=0)}
    }
    override suspend fun completeSend(attempt: SendAttempt,receipt: MessageSendOperationReceipt) {
        matching(attempt)?.let {validateSendReceipt(attempt.command,receipt);entries[attempt.command.clientMessageId]=it.copy(receipt=receipt,token=null,lease=0)}
    }
    override suspend fun resumeNetworkWaitingSends(viewer: UserId,now: Long) {
        entries.entries.toList().forEach {(id,entry)->
            require(entry.command.senderUserId==viewer.value)
            if(entry.receipt==null) entries[id]=entry.copy(state=SendRecoveryPolicy.connected(entry.state,now))
        }
    }
    override suspend fun resumeSend(room: RoomId,viewer: UserId,operation: String,now: Long) {
        val entry=entries.getValue(operation)
        require(entry.command.roomId==room.value && entry.command.senderUserId==viewer.value)
        if(entry.receipt==null && entry.state.status==SendRecoveryStatus.NeedsAttention)
            entries[operation]=entry.copy(state=SendRecoveryPolicy.resume(entry.state,now),token=null,lease=0)
    }
}

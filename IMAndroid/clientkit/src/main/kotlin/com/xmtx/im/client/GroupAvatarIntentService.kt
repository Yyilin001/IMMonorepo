package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Account foreground worker. The journal, not a page, owns commands and original source references. */
class GroupAvatarIntentService(private val actor: UserId,private val device: DeviceId,private val commands: GroupAvatarCommands,
    private val reader: GroupAvatarReading,private val store: GroupAvatarIntentStore,private val now: ()->Long=System::currentTimeMillis) {
    private val activity=Mutex()
    suspend fun refresh(room: RoomId): GroupAvatarEditAuthority {
        val before=store.groupAvatarFence(room);require(before.authorized)
        val value=reader.read(room);currentCoroutineContext().ensureActive()
        val after=store.groupAvatarFence(room)
        require(before==after && value.actor==actor && value.device==device && value.state.room==room && value.valid() && value.state.revision>=after.revision && value.membershipRevision>=after.membershipRevision)
        return GroupAvatarEditAuthority(value,after)
    }
    suspend fun enqueue(authority: GroupAvatarEditAuthority,asset: ResourceLocalAsset?=null): GroupAvatarIntent {
        val room=authority.presentation.state.room
        val upload=asset?.let {
            require(it.purpose==ResourceUsage.GroupAvatar(room) && it.contentType.startsWith("image/"))
            GroupAvatarUploadPreparation(newGroupAvatarId(),it.id,ResourceUploadRequest(newGroupAvatarId(),newGroupAvatarId(),it.purpose,it.contentType,it.byteCount,it.checksum,displayName=it.displayName,dimensions=it.dimensions))
        }
        return store.enqueueGroupAvatar(authority,GroupAvatarCommand(newGroupAvatarId(),room,authority.presentation.state.revision,
            upload?.let { GroupAvatarMutation.Set(it.request.media) } ?: GroupAvatarMutation.Remove),upload,now())
    }
    suspend fun enqueueImported(authority: GroupAvatarEditAuthority,source: GroupAvatarImportPreparation): GroupAvatarIntent {
        val room=authority.presentation.state.room
        require(source.request.targetUsage==ResourceUsage.GroupAvatar(room))
        return store.enqueueImportedGroupAvatar(authority,GroupAvatarCommand(newGroupAvatarId(),room,authority.presentation.state.revision,
            GroupAvatarMutation.Set(source.request.targetMedia)),source,now())
    }
    suspend fun retry(id: String)=store.retryGroupAvatar(id)
    suspend fun resolve(id: String,action: GroupAvatarRecoveryAction)=store.requestGroupAvatarRecovery(id,action)
    suspend fun cancel(id: String)=store.cancelGroupAvatar(id)
    suspend fun abandon(id: String)=store.abandonGroupAvatar(id)
    suspend fun replace(id: String,authority: GroupAvatarEditAuthority)=store.replaceGroupAvatar(id,authority,newGroupAvatarId(),newGroupAvatarId(),newGroupAvatarId(),now())

    /** A deterministic bounded pass is also usable by explicit recovery callers. */
    suspend fun recoverOnce()=activity.withLock { coroutineScope {
        store.prepareGroupAvatars(now())
        val due=store.dueGroupAvatars(now()).take(2)
        val candidatesObserved=System.nanoTime()
        due.map { async { perform(it,candidatesObserved) } }.awaitAll()
        store.prepareGroupAvatars(now())
    } }
    suspend fun runForeground(): Unit=activity.withLock { coroutineScope {
        val wake=Channel<Unit>(Channel.CONFLATED)
        val observer=launch { store.groupAvatarIntentChanges.collect { wake.trySend(Unit) } }
        val flights=mutableMapOf<String,Job>()
        try {
            while(isActive) {
                flights.entries.removeAll { it.value.isCompleted }
                store.prepareGroupAvatars(now())
                val values=store.groupAvatarIntents()
                val due=store.dueGroupAvatars(now()).filter { it !in flights }
                val candidatesObserved=System.nanoTime()
                for(id in due) {
                    if(flights.size>=2) break
                    flights[id]=launch { try { perform(id,candidatesObserved) } finally { wake.trySend(Unit) } }
                }
                // Waiting for an upload is event driven; only actual claim/retry times schedule a wake.
                val deadline=values.filter { it.id !in flights && !it.terminal }.mapNotNull {
                    if(it.claimUntil!=null) it.claimUntil
                    else if(it.submissionStarted) maxOf(it.retryAt,it.serverRetryAt).takeIf { time -> time>now() }
                    else null
                }.minOrNull()
                if(deadline==null) wake.receive() else withTimeoutOrNull((deadline-now()).coerceIn(1,60000)) { wake.receive() }
            }
        } finally {
            withContext(NonCancellable) { observer.cancelAndJoin();flights.values.forEach { it.cancel() };flights.values.forEach { it.join() };wake.close() }
        }
    } }
    private suspend fun perform(id: String,candidatesObserved:Long) {
        val claim=store.claimGroupAvatar(id,now()) ?: return
        require(claim.intent.actor==actor && claim.intent.device==device)
        measureOperationStep(OperationKind.GroupAvatar,
            if(claim.intent.action==null) OperationWorkAction.Submit else OperationWorkAction.Reconcile,
            claim.intent.attempts,claim.intent.attempts>1,candidatesObserved,priority=NetworkWorkPriority.Recovery,
            observe={store.groupAvatarIntent(id)?.takeIf {it.actor==actor && it.device==device && it.command==claim.intent.command}?.operationObservation(now())}) {
            try {
                withPreparationAttempt(claim.intent.attempts) {withTimeout(15000) {
                    val action=claim.intent.action
                    if(action==null) {
                        val response=commands.submit(claim.intent.command)
                        // A verified positive receipt may survive cancellation after physical I/O ends.
                        withContext(NonCancellable) { store.finishGroupAvatar(claim,response,now()) }
                    } else {
                        val response=commands.recover(GroupAvatarRecoveryRequest(claim.intent.command,action))
                        withContext(NonCancellable) { store.finishGroupAvatarRecovery(claim,response,now()) }
                    }
                }}
            } catch(error: Exception) {
                val failure=error as? ClientFailure.Http
                val hint=failure?.retryAfter?.let { runCatching { retryAfterMilliseconds(it,now()) }.getOrDefault(86400000) } ?: 0
                val retry=Math.addExact(now(),maxOf(hint,minOf(30000L,1000L shl claim.intent.attempts)))
                val issue=when {
                    failure?.status==429 -> GroupAvatarIssue.Throttled
                    error is ClientFailure.SignedOut || failure?.status==401 -> GroupAvatarIssue.AuthorizationUnavailable
                    failure?.status==403 -> GroupAvatarIssue.Forbidden
                    error is ClientFailure.Protocol || error is IllegalArgumentException -> GroupAvatarIssue.InvalidResponse
                    else -> GroupAvatarIssue.OutcomeUnknown
                }
                val attention=issue in setOf(GroupAvatarIssue.Forbidden,GroupAvatarIssue.InvalidResponse) || failure?.status==410 || hint>60000
                withContext(NonCancellable) { store.failGroupAvatar(claim,issue,retry,attention,if(hint>0) Math.addExact(now(),hint) else 0) }
                if(error is CancellationException && error !is TimeoutCancellationException) throw error
                if(error is ClientFailure.SignedOut) throw error
            }
        }
    }
}

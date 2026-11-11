package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID

class GroupAvatarActivation internal constructor(val room: RoomId,internal val id: String,internal val epoch: String)
class GroupAvatarOverloaded: Exception("群头像读取繁忙，请稍后重试")

/** Account-owned, fair shared reads. A new visible activation always obtains its own authorization. */
@OptIn(ExperimentalCoroutinesApi::class)
class GroupAvatarRepository(private val actor: UserId,private val device: DeviceId,private val reader: GroupAvatarReading,
    private val fences: suspend (RoomId)->GroupAvatarFence,parent: CoroutineScope,
    private val nanoTime: ()->Long=System::nanoTime,private val wallTime: ()->Long=System::currentTimeMillis) {
    private class Activation(val token: GroupAvatarActivation,var authorized: Boolean=false,var generation: String=UUID.randomUUID().toString(),var observer: Channel<Unit>?=null)
    private data class Entry(val value: GroupAvatarPresentation,val fence: GroupAvatarFence,var refreshAfter: Long?=null)
    private class Demand(val id: String=UUID.randomUUID().toString(),val waiters: LinkedHashMap<String,Waiter> = linkedMapOf())
    private data class Waiter(val token: GroupAvatarActivation,val result: CompletableDeferred<GroupAvatarPresentation>)
    private data class Flight(val demand: String,val job: Job)
    private data class Cooldown(val until: Long,val error: ClientFailure.Http)
    private val mutex=Mutex()
    private val work=SupervisorJob(parent.coroutineContext[Job])
    private val scope=CoroutineScope(parent.coroutineContext+work)
    private var epoch=UUID.randomUUID().toString();private var closed=false
    private val activations=mutableMapOf<String,Activation>()
    private val access=mutableMapOf<RoomId,Entry>()
    private val demands=linkedMapOf<RoomId,Demand>() // Insertion order is the admission order.
    private val flights=mutableMapOf<RoomId,Flight>()
    private val cooldowns=linkedMapOf<RoomId,Cooldown>()
    private val fenceReads=mutableSetOf<Job>()
    private var bytes=0;private var waiting=0

    suspend fun activate(room: RoomId): GroupAvatarActivation=mutex.withLock {
        requireOpen();uuidId(room.value)
        if(activations.size>=256) throw GroupAvatarOverloaded()
        GroupAvatarActivation(room,UUID.randomUUID().toString(),epoch).also { activations[it.id]=Activation(it) }
    }
    suspend fun invalidations(token: GroupAvatarActivation): Flow<Unit> = mutex.withLock {
        val activation=requireActive(token);activation.observer?.close()
        Channel<Unit>(Channel.CONFLATED).also { activation.observer=it }.receiveAsFlow()
    }
    suspend fun deactivate(token: GroupAvatarActivation)=mutex.withLock {
        if(token.epoch!=epoch) return@withLock
        activations.remove(token.id)?.observer?.close()
        demands[token.room]?.waiters?.filterValues { it.token===token }?.keys?.toList()?.forEach { cancelWaiter(token.room,it) }
        if(activations.values.none { it.token.room==token.room && it.authorized }) removeAccess(token.room)
    }
    suspend fun invalidate(room: RoomId)=mutex.withLock { invalidateRoom(room) }
    /** Check current durable epochs on sync publication, without borrowing a display capability. */
    suspend fun reconcile() {
        val rooms=mutex.withLock { access.keys.toList() }
        for(room in rooms) {
            val current=currentFence(room)
            mutex.withLock { access[room]?.let { if(it.fence!=current) invalidateRoom(room) } }
        }
    }
    suspend fun endAllActivations()=mutex.withLock { endAll() }
    suspend fun close()=withContext(NonCancellable) {
        val pending=mutex.withLock { closed=true;endAll();(flights.values.map { it.job }+fenceReads).distinct() }
        pending.forEach { it.cancel() };pending.forEach { it.join() };work.cancelAndJoin()
    }
    data class Diagnostics(val activations: Int,val waiting: Int,val rooms: Int,val flights: Int,val cached: Int,val bytes: Int)
    suspend fun diagnostics()=mutex.withLock { Diagnostics(activations.size,waiting,demands.size,flights.size,access.size,bytes) }

    suspend fun read(token: GroupAvatarActivation): GroupAvatarPresentation=read(token,false,null)
    suspend fun cached(token: GroupAvatarActivation): GroupAvatarPresentation?=validated(token)?.value
    suspend fun refreshAvatarReadGrant(token: GroupAvatarActivation,replacing: AvatarAccess?): AvatarReadGrant? {
        read(token,true,replacing);return avatarReadGrant(token)
    }
    suspend fun avatarReadGrant(token: GroupAvatarActivation): AvatarReadGrant? {
        val entry=validated(token) ?: return null
        val avatar=entry.value.avatar ?: return null
        val generation=mutex.withLock { requireActive(token).takeIf { it.authorized && access[token.room]===entry }?.generation } ?: return null
        val downloadable=entry.value.downloadDeadlineNanos?.let { it-nanoTime()>0 }==true
        return AvatarReadGrant(actor,device,avatar.content,ResourceHome.Room(token.room),entry.value.deadlineNanos,
            if(downloadable) avatar.plan else null,if(downloadable) entry.value.downloadDeadlineNanos else null,nanoTime) {
            val current=try { validated(token) } catch(_: AvatarAccessFailure) { null }
            mutex.withLock {
                current!=null && active(token)?.let { it.authorized && it.generation==generation }==true &&
                    access[token.room]===current && sameAuthority(current.value,entry.value)
            }
        }.also { it.requireValid() }
    }
    private suspend fun read(token: GroupAvatarActivation,refresh: Boolean,replacing: AvatarAccess?): GroupAvatarPresentation {
        currentCoroutineContext().ensureActive()
        val existing=validated(token)
        if(existing!=null) {
            if(!refresh) return existing.value
            val avatar=existing.value.avatar?.let { if(existing.value.downloadDeadlineNanos?.let { deadline -> deadline-nanoTime()>0 }==true) it else it.copy(plan=null) }
            if(avatar==null || avatar!=replacing && (avatar.content!=replacing?.content || avatar.plan!=null)) return existing.value
        }
        val waiterId=UUID.randomUUID().toString()
        val waiter=mutex.withLock {
            requireActive(token)
            cooldowns[token.room]?.let { if(it.until-nanoTime()>0) throw it.error }
            cooldowns.remove(token.room)
            if(refresh && existing!=null && access[token.room]===existing && demands[token.room]==null) {
                if(existing.refreshAfter?.let { it-nanoTime()>0 }==true) throw ClientFailure.Http(429,retryAfter="3")
                existing.refreshAfter=nanoTime()+2_500_000_000
            }
            if(token.room !in demands && demands.size>=128 || waiting>=512) throw GroupAvatarOverloaded()
            Waiter(token,CompletableDeferred()).also {
                demands.getOrPut(token.room) { Demand() }.waiters[waiterId]=it;waiting++;launchReads()
            }
        }
        try { return waiter.result.await() }
        catch(error: CancellationException) {
            withContext(NonCancellable) { mutex.withLock { cancelWaiter(token.room,waiterId) } };throw error
        }
    }
    private suspend fun validated(token: GroupAvatarActivation): Entry? {
        currentCoroutineContext().ensureActive()
        val previous=mutex.withLock {
            if(!requireActive(token).authorized) return null
            access[token.room] ?: return null
        }
        val fence=currentFence(token.room)
        currentCoroutineContext().ensureActive()
        return mutex.withLock {
            if(!requireActive(token).authorized) return@withLock null
            val current=access[token.room] ?: return@withLock null
            // Retry against the replacement entry rather than accepting a fence read for a removed authority.
            if(current!==previous) return@withLock null
            if(!fence.authorized || current.fence!=fence || current.value.state.revision<fence.revision || current.value.membershipRevision<fence.membershipRevision) {
                invalidateRoom(token.room);return@withLock null
            }
            if(!current.value.valid(nanoTime())) { removeAccess(token.room);revoke(token.room);return@withLock null }
            current
        }
    }
    private fun launchReads() {
        if(closed || !work.isActive) return
        for((room,demand) in demands) {
            if(flights.size>=2) break
            if(room in flights) continue
            // Atomic start guarantees slot cleanup even if the account parent was just cancelled.
            // finish() cannot acquire mutex until this flight has been registered.
            val job=scope.launch(start=CoroutineStart.ATOMIC) {
                val result=runCatching {
                    ensureActive();val before=currentFence(room)
                    if(!before.authorized) throw AvatarAccessFailure()
                    val value=reader.read(room);ensureActive();val after=currentFence(room);ensureActive()
                    if(before!=after || !after.authorized || value.state.revision<after.revision || value.membershipRevision<after.membershipRevision) throw AvatarAccessFailure()
                    require(value.actor==actor && value.device==device && value.state.room==room)
                    if(!value.valid(nanoTime())) throw AvatarAccessFailure()
                    Entry(value,after)
                }
                withContext(NonCancellable) { mutex.withLock { finish(room,demand.id,result) } }
            }
            flights[room]=Flight(demand.id,job)
        }
    }
    private fun finish(room: RoomId,id: String,result: Result<Entry>) {
        if(flights[room]?.demand!=id) return
        flights.remove(room)
        if(demands[room]?.id==id) {
            val error=result.exceptionOrNull()
            if(error==null) {
                val entry=result.getOrThrow()
                val previous=access[room]
                if(previous!=null && (!sameAuthority(previous.value,entry.value) || previous.fence!=entry.fence)) revoke(room)
                entry.refreshAfter=previous?.refreshAfter;removeAccess(room)
                while(access.size>=256 || bytes>2*1024*1024-entry.value.wireBytes) {
                    val oldest=access.minByOrNull { it.value.value.deadlineNanos-nanoTime() }?.key ?: break
                    removeAccess(oldest);revoke(oldest)
                }
                access[room]=entry;bytes+=entry.value.wireBytes;cooldowns.remove(room)
                demands[room]?.waiters?.values?.forEach { active(it.token)?.authorized=true }
                complete(room,Result.success(entry.value))
            } else {
                if(error is AvatarAccessFailure || error is ClientFailure.SignedOut || error is ClientFailure.Http && error.status in setOf(401,403)) { removeAccess(room);revoke(room) }
                if(error is ClientFailure.Http && error.status in setOf(403,429)) {
                    // A malformed server hint must not strand the waiters after the flight slot is released.
                    val delay=if(error.status==403) 30_000L else retryDelay(error.retryAfter)
                    if(cooldowns.size>=256) cooldowns.remove(cooldowns.keys.first())
                    cooldowns[room]=Cooldown(nanoTime()+delay*1_000_000,error)
                }
                complete(room,Result.failure(error))
            }
        }
        launchReads()
    }
    private fun sameAuthority(a: GroupAvatarPresentation,b: GroupAvatarPresentation)=a.state==b.state && a.resourceGeneration==b.resourceGeneration &&
        a.membershipRevision==b.membershipRevision && a.canManage==b.canManage && a.avatar?.content==b.avatar?.content
    private suspend fun currentFence(room: RoomId): GroupAvatarFence=coroutineScope {
        val job=currentCoroutineContext().job
        mutex.withLock { requireOpen();fenceReads.add(job) }
        try { fences(room).also { currentCoroutineContext().ensureActive() } }
        finally { withContext(NonCancellable) { mutex.withLock { fenceReads.remove(job) } } }
    }
    private fun retryDelay(hint: String?): Long {
        val raw=hint?.trim() ?: return 1000
        val seconds=raw.toLongOrNull()
        if(seconds!=null) return seconds.coerceIn(1,315_576_000)*1000
        if(raw.isNotEmpty() && raw.all { it in '0'..'9' }) return 315_576_000_000
        return runCatching {
            val until=java.time.ZonedDateTime.parse(raw,java.time.format.DateTimeFormatter.RFC_1123_DATE_TIME).toInstant().toEpochMilli()
            Math.subtractExact(until,wallTime()).coerceIn(1000,315_576_000_000)
        }.getOrDefault(1000)
    }
    private fun requireOpen() { if(closed || !work.isActive) throw AvatarAccessFailure() }
    private fun active(token: GroupAvatarActivation)=activations[token.id]?.takeIf { token.epoch==epoch && it.token===token && !closed && work.isActive }
    private fun requireActive(token: GroupAvatarActivation)=active(token) ?: throw AvatarAccessFailure()
    private fun removeAccess(room: RoomId) { access.remove(room)?.let { bytes-=it.value.wireBytes } }
    private fun revoke(room: RoomId) {
        activations.values.filter { it.token.room==room }.forEach {
            val visible=it.authorized;it.authorized=false;it.generation=UUID.randomUUID().toString()
            if(visible) it.observer?.trySend(Unit)
        }
    }
    private fun invalidateRoom(room: RoomId) {
        removeAccess(room);cooldowns.remove(room);revoke(room);complete(room,Result.failure(AvatarAccessFailure()));flights[room]?.job?.cancel()
    }
    private fun complete(room: RoomId,result: Result<GroupAvatarPresentation>) {
        val demand=demands.remove(room) ?: return
        waiting-=demand.waiters.size
        demand.waiters.values.forEach { waiter ->
            if(active(waiter.token)==null) waiter.result.completeExceptionally(AvatarAccessFailure())
            else result.fold(waiter.result::complete,waiter.result::completeExceptionally)
        }
    }
    private fun cancelWaiter(room: RoomId,id: String) {
        val demand=demands[room] ?: return
        val waiter=demand.waiters.remove(id) ?: return
        waiting--;waiter.result.cancel()
        if(demand.waiters.isEmpty()) { demands.remove(room);flights[room]?.takeIf { it.demand==demand.id }?.job?.cancel() }
    }
    private fun endAll() {
        activations.values.forEach { it.observer?.close() };activations.clear();epoch=UUID.randomUUID().toString()
        access.clear();bytes=0;cooldowns.clear()
        demands.keys.toList().forEach { complete(it,Result.failure(AvatarAccessFailure())) }
        flights.values.forEach { it.job.cancel() }
        // A cancelled but physically running request continues occupying its slot until finish().
    }
}

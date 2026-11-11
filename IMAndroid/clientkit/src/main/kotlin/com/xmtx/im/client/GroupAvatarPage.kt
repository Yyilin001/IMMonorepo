package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import java.util.concurrent.atomic.AtomicBoolean

/** One visible group owns one activation. Encoded pixels expire independently of the UI collector. */
data class GroupAvatarDisplay(val image: AvatarPresentationBytes?=null,val loading: Boolean=false,val unavailable: Boolean=false)
class GroupAvatarPage(private val room: RoomId,private val repository: GroupAvatarRepository,
    private val bytes: suspend (AvatarReadGrant)->AvatarDownloadedBytes,parent: CoroutineScope,
    private val onClose: (GroupAvatarPage)->Unit={},private val budget: GroupAvatarDisplayBudget=GroupAvatarDisplayBudget()) {
    private val reservation=Any()
    private val closed=AtomicBoolean(false)
    val isClosed get()=closed.get()
    private val publication=Any()
    private fun display(value: GroupAvatarDisplay) { synchronized(publication) { if(!closed.get()) mutable.value=value } }
    private val mutable=MutableStateFlow(GroupAvatarDisplay(loading=true))
    val state=mutable.asStateFlow()
    private val wake=Channel<Unit>(Channel.CONFLATED)
    private val scope=CoroutineScope(parent.coroutineContext+SupervisorJob(parent.coroutineContext[Job]))
    private val worker=scope.launch {
        var token: GroupAvatarActivation?=null
        try {
            token=repository.activate(room)
            val invalidations=repository.invalidations(token)
            val observer=launch { try { invalidations.collect { display(GroupAvatarDisplay());wake.trySend(Unit) } } finally { close() } }
            wake.trySend(Unit)
            try { wake.receiveAsFlow().collectLatest {
                display(GroupAvatarDisplay(loading=true))
                var loaded=false
                for(attempt in 0..2) {
                    try {
                        val shown=repository.read(token)
                        var grant=repository.avatarReadGrant(token)
                        val pixels=if(shown.avatar==null) null else {
                            requireNotNull(grant);budget.acquire(reservation,grant.content.byteCount)
                            val downloaded=try { bytes(grant) } catch(error: AvatarTargetExpired) {
                                budget.release(reservation)
                                grant=repository.refreshAvatarReadGrant(token,shown.avatar)
                                budget.acquire(reservation,requireNotNull(grant).content.byteCount);bytes(requireNotNull(grant))
                            }
                            val encoded=downloaded.read();currentCoroutineContext().ensureActive()
                            requireNotNull(grant).requireValid()
                            require(downloaded.content==grant.content)
                            AvatarPresentationBytes(grant.content,encoded,minOf(grant.deadlineNanos,downloaded.deadlineNanos))
                        }
                        currentCoroutineContext().ensureActive()
                        if(closed.get()) return@collectLatest
                        display(GroupAvatarDisplay(pixels));loaded=true
                        val deadline=pixels?.deadlineNanos ?: shown.deadlineNanos
                        val remaining=deadline-System.nanoTime()
                        if(remaining>0) delay((remaining+999999)/1000000)
                        display(GroupAvatarDisplay());repository.invalidate(room);break
                    } catch(error: CancellationException) { throw error }
                    catch(_: Exception) { display(GroupAvatarDisplay(unavailable=true));budget.release(reservation);if(attempt<2) delay(3000) }
                    finally { budget.release(reservation) }
                }
                if(!loaded && !closed.get()) display(GroupAvatarDisplay(unavailable=true))
            } } finally { observer.cancelAndJoin() }
        } catch(error: CancellationException) { throw error }
        catch(_: Exception) { display(GroupAvatarDisplay(unavailable=true)) }
        finally {
            display(GroupAvatarDisplay())
            withContext(NonCancellable) { token?.let { repository.deactivate(it) } }
        }
    }
    init { worker.invokeOnCompletion { close() } }
    fun refresh() { if(!closed.get()) wake.trySend(Unit) }
    fun close() {
        val changed=synchronized(publication) { if(closed.compareAndSet(false,true)) { mutable.value=GroupAvatarDisplay();true } else false }
        if(changed) { scope.cancel();wake.close();onClose(this) }
    }
    suspend fun awaitClosed() { close();withContext(NonCancellable) { worker.join() } }
}

package com.xmtx.im

import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit

/** A resource repeated in two messages has two independent read permissions. */
data class ChatImageRequest(val selection: MessageImageSelection,val revision: Long,val descriptor: ResourceDescriptor)
data class ChatImagesState(val room: RoomId,val available: Boolean=false,
    val previews: PersistentMap<ChatImageRequest,MessagePreviewBytes> = persistentMapOf(),
    val loading: PersistentSet<ChatImageRequest> = persistentSetOf(),val failed: PersistentSet<ChatImageRequest> = persistentSetOf())

/** Main-thread page owner. Retains at most twelve visible previews and performs two reads at a time. */
internal class ChatImagesController(val room: RoomId,parent: CoroutineScope,
    private val changes: Flow<Long>,private val generation: suspend ()->String,
    private val read: suspend (ChatImageRequest)->MessagePreviewBytes,private val publish: (ChatImagesState)->Unit,
    private val expiry: suspend (Long)->Unit=::awaitPresentationExpiry) {
    private val scope=CoroutineScope(parent.coroutineContext+SupervisorJob(parent.coroutineContext[Job]))
    private val slots=Semaphore(2)
    private val jobs=mutableMapOf<ChatImageRequest,Job>()
    private val expirations=mutableMapOf<ChatImageRequest,Job>()
    private var interests=persistentSetOf<ChatImageRequest>()
    private var attempted=persistentSetOf<ChatImageRequest>()
    private var observer: Job?=null
    private var sourceUnavailable=false
    private var active=false;private var closed=false;private var epoch=0L;private var token: String?=null
    var state=ChatImagesState(room);private set
    private fun update(body: (ChatImagesState)->ChatImagesState) { if(!closed) { state=body(state);publish(state) } }
    private fun clear() {
        epoch++;jobs.values.forEach { it.cancel() };jobs.clear();expirations.values.forEach { it.cancel() };expirations.clear();attempted=persistentSetOf()
        update { it.copy(previews=persistentMapOf(),loading=persistentSetOf(),failed=persistentSetOf()) }
    }
    fun foreground(value: Boolean) {
        if(closed || active==value) return
        active=value;observer?.cancel();clear();token=null;sourceUnavailable=false;update { it.copy(available=value) }
        if(value) observer=scope.launch {
            changes.collectLatest {
                try {
                    val next=generation();currentCoroutineContext().ensureActive()
                    if(active && !closed && token!=next) { clear();token=next;sourceUnavailable=false;load() }
                } catch(error: CancellationException) { throw error }
                catch(_: Exception) { if(active && !closed) { clear();token=null;sourceUnavailable=true;update { it.copy(failed=interests) } } }
            }
        }
    }
    fun visible(requests: PersistentList<ChatImageRequest>) {
        if(closed) return
        val next=requests.asSequence().filter { it.selection.location.room==room && it.descriptor.key==it.selection.key }.distinct().take(12).toPersistentSet()
        if(next==interests) return
        interests=next
        jobs.keys.filter { it !in next }.forEach { jobs.remove(it)?.cancel() }
        expirations.keys.filter { it !in next }.forEach { expirations.remove(it)?.cancel() }
        attempted=attempted.filter { it in next }.toPersistentSet()
        update { it.copy(previews=it.previews.filterKeys { key -> key in next }.toPersistentMap(),loading=it.loading.intersect(next).toPersistentSet(),failed=if(active && sourceUnavailable) next else it.failed.intersect(next).toPersistentSet()) }
        load()
    }
    fun retry(request: ChatImageRequest) {
        if(closed || !active || request !in interests || request in jobs) return
        if(token==null) { foreground(false);foreground(true);return }
        attempted=attempted.remove(request);load()
    }
    private fun load() {
        val expected=token ?: return
        if(!active || closed) return
        val e=epoch
        for(request in interests) {
            if(request in attempted) continue
            attempted=attempted.add(request)
            update { it.copy(loading=it.loading.add(request),failed=it.failed.remove(request)) }
            val job=scope.launch(start=CoroutineStart.LAZY) {
                try {
                    val result=slots.withPermit { read(request) };currentCoroutineContext().ensureActive()
                    check(result.valid() && result.read.generation==expected && result.read.descriptor==request.descriptor &&
                        result.read.source.room==room && result.read.source.message==request.selection.location.message && result.read.source.revision==request.revision)
                    if(valid(e,expected,request)) {
                        update { it.copy(previews=it.previews.put(request,result)) }
                        expirations.remove(request)?.cancel()
                        expirations[request]=scope.launch {
                            expiry(result.deadlineNanos)
                            if(valid(e,expected,request) && state.previews[request]===result) update { it.copy(previews=it.previews.remove(request),failed=it.failed.add(request)) }
                        }
                    }
                } catch(error: CancellationException) { throw error }
                catch(_: Exception) { if(valid(e,expected,request)) update { it.copy(previews=it.previews.remove(request),failed=it.failed.add(request)) } }
                finally {
                    if(jobs[request]===currentCoroutineContext().job) { jobs.remove(request);update { it.copy(loading=it.loading.remove(request)) } }
                }
            }
            jobs[request]=job;job.start()
        }
    }
    private fun valid(e: Long,t: String,request: ChatImageRequest)=!closed && active && epoch==e && token==t && request in interests
    fun close() { if(closed) return;closed=true;active=false;epoch++;scope.cancel();jobs.clear();expirations.clear();interests=persistentSetOf();attempted=persistentSetOf();state=ChatImagesState(room) }
}

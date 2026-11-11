package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlin.random.Random

/** One negotiated foreground connection. Register/change/close on the parent's single UI dispatcher.
 * Pages keep independent HTTP and author grants. This owner drains the old view before opening another.
 */
class AuthorPresentationCoordinator(private val source: AuthorPresentationSource,private val commands: AuthorPresentationCommands,
    parent: CoroutineScope,private val nanoTime: ()->Long=System::nanoTime,
    private val renewalLeadMillis: ()->Long={Random.nextLong(4000,6001)}) : AutoCloseable {
    private val job=SupervisorJob(parent.coroutineContext[Job])
    private val scope=CoroutineScope(parent.coroutineContext+job)
    private class Page(val value: ProfilePresentationPage,var demand: ProfileAuthorDemand,var watcher: Job?=null)
    private val pages=linkedMapOf<ProfilePresentationPage,Page>()
    private val changed=Channel<Unit>(Channel.CONFLATED)
    private val candidates=AuthorPresentationCandidates(nanoTime)
    private var generation=0L
    private var messageRoom: RoomId?=null
    private var flight: Deferred<Unit>?=null
    private var currentView: AuthorPresentationView?=null
    private var boundView: AuthorPresentationView?=null
    private var closed=false
    init {
        scope.launch {candidates.nextExpiry.collectLatest {deadline->
            if(deadline!=null) {delay(((deadline-nanoTime()).coerceAtLeast(0)+999_999)/1_000_000);candidates.prune()}
        }}
        scope.launch {
        try {
            while(isActive) {
                if(!hasDemand()) {changed.receive();continue}
                delay(40)
                val version=generation
                val selected=pages.values.filter {!it.demand.closed}.map {it.value}
                if(selected.isEmpty() || !hasDemand()) continue
                try {
                    supervisorScope {
                        val running=async {runView(selected,version)};flight=running
                        try {running.await()} finally {if(flight===running) flight=null}
                    }
                } catch(cancelled: CancellationException) {if(!isActive) throw cancelled}
                catch(failure: GatewayFailure) {
                    if(!failure.retryable || failure.code=="FORBIDDEN") break
                    delay(maxOf(2000L,failure.retryAfterSeconds.toLong()*1000)+Random.nextLong(100,501))
                } catch(_: Exception) {break}
            }
        } finally {close()}
    }}
    fun register(page: ProfilePresentationPage): Boolean {
        if(closed || page in pages || pages.size>=16 || page.authorDemand.value.closed) return false
        val item=Page(page,page.authorDemand.value);pages[page]=item
        reset()
        item.watcher=scope.launch {
            page.authorDemand.collect {next->
                if(next.closed) {remove(page);return@collect}
                val previous=item.demand;item.demand=next
                if(previous.revision!=next.revision) reset() else changed.trySend(Unit)
            }
        }
        return true
    }
    fun remove(page: ProfilePresentationPage) {
        val removed=pages.remove(page) ?: return
        boundView?.let(page::unbindAuthor);removed.watcher?.cancel();reset()
    }
    fun selectMessageRoom(room: RoomId?) {
        room?.let {uuidId(it.value)}
        if(closed || messageRoom==room) return
        messageRoom=room;reset()
    }
    private fun reset() {
        generation++;candidates.clear()
        currentView?.let(source::endAuthorPresentationView)
        flight?.cancel();changed.trySend(Unit)
    }
    private fun requireCurrent(version: Long) {check(!closed);if(generation!=version) throw CancellationException("Author page set changed")}
    private fun hasDemand()=pages.isNotEmpty() && (messageRoom!=null || visibleKeys().isNotEmpty())
    internal fun bufferedCandidates()=candidates.diagnostics()
    private fun visibleKeys(): PersistentList<ProfileKey> = pages.values.flatMap {it.demand.keys}.distinct()
        .sortedBy {it.payload().toString()}.take(128).toPersistentList()
    private suspend fun runView(selected: List<ProfilePresentationPage>,version: Long) {
        requireCurrent(version)
        for(page in selected) if(!page.prepareAuthor()) throw CancellationException("Author authority changed")
        requireCurrent(version)
        val view=source.beginAuthorPresentationView(messageRoom?.let {persistentListOf(it)} ?: persistentListOf())
        currentView=view
        try {
            candidates.clear();boundView=view;selected.forEach {it.bindAuthor(view,candidates)}
            commands.start(view.start);requireCurrent(version)
            val lead=renewalLeadMillis().coerceIn(1,10000)*1_000_000
            val renewAt=MutableStateFlow(view.renewByNanos-lead)
            coroutineScope {
                val finished=CompletableDeferred<Unit>()
                val timer=launch {renewAt.collectLatest {deadline->delay(((deadline-nanoTime()).coerceAtLeast(0)+999_999)/1_000_000);finished.complete(Unit)}}
                val interests=launch {
                    var sequence=0L;var previous: PersistentList<ProfileKey>?=null
                    while(isActive) {
                        requireCurrent(version)
                        val keys=visibleKeys()
                        if(keys!=previous) {
                            check(sequence<Long.MAX_VALUE)
                            commands.interests(AuthorPresentationInterests(view.start.stream,view.start.view,++sequence,keys));previous=keys
                        }
                        changed.receive();delay(25)
                    }
                }
                val receiver=launch {
                    while(isActive) {
                        val delta=source.nextAuthorPresentationDelta(view);requireCurrent(version)
                        for(page in selected) {page.ingestAuthor(delta);requireCurrent(version)}
                        val now=nanoTime()
                        // Re-read every page after suspending authority checks. Departed or superseded grants cannot be acknowledged.
                        val retained=selected.flatMap {it.retainedAuthor(delta).entries}.groupBy {it.key}.mapValues {(_,values)->values.minBy {it.value-now}.value}
                        val keys=delta.entries.map {it.key}.filter {retained[it]?.minus(now)?.let {remaining->remaining>0}==true}.toPersistentList()
                        if(keys.isNotEmpty()) {
                            val deadline=retained.getValue(keys.minBy {retained.getValue(it)-now})
                            val minimum=((deadline-now).coerceAtLeast(0)/1_000_000).coerceAtMost(300000)
                            val grantExpiry=delta.entries.filterIsInstance<ReceivedAuthorPresentationEntry.Available>().filter {it.key in keys}.minByOrNull {retained.getValue(it.key)-now}?.let {retained.getValue(it.key)}
                            grantExpiry?.let {expiry->
                                val remaining=(expiry-now).coerceAtLeast(0)
                                val renewal=expiry-minOf(lead,remaining/2)
                                if(renewal-renewAt.value<0) renewAt.value=renewal
                            }
                            commands.receipt(AuthorPresentationReceipt(view.start.stream,view.start.view,delta.sequence,keys,minimum))
                        }
                    }
                }
                try {finished.await()} finally {timer.cancel();interests.cancel();receiver.cancel()}
            }
        } finally {
            source.endAuthorPresentationView(view);if(currentView==view) currentView=null
            // Physical correlation belongs to the original connection, including a cancelled start.
            withContext(NonCancellable) {runCatching {commands.end(view.start)}}
        }
    }
    override fun close() {
        if(closed) return
        closed=true
        currentView?.let(source::endAuthorPresentationView);boundView?.let {view->pages.keys.toList().forEach {it.unbindAuthor(view)}}
        candidates.clear();pages.clear();job.cancel();changed.cancel()
    }
    suspend fun awaitClosed() {job.join()}
}

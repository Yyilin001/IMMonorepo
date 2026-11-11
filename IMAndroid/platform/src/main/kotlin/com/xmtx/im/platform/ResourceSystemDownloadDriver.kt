package com.xmtx.im.platform

import android.app.job.*
import android.content.*
import android.os.PersistableBundle
import android.os.SystemClock
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import okhttp3.HttpUrl.Companion.toHttpUrl
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/** Delegates only a journaled, capacity-admitted whole-object GET. No business account work runs in JobService. */
class ResourceSystemDownloadDriver(context:Context,private val service:Class<out ResourceDownloadJobService> = ResourceDownloadJobService::class.java,private val exitMarker:FileLocalExitMarker?=null) {
    private val context=context.applicationContext
    private val scheduler=this.context.getSystemService(JobScheduler::class.java)
    init {exitMarker?.requireContext(this.context)}
    suspend fun schedule(store:SqliteClientStore,files:ManagedResourceFiles,mapping:ResourceBackgroundDownloadMapping,target:ResourceBackgroundDownloadTarget):Unit=mutations.withLock {
        if(exitMarker?.isPending()==true) throw ClientFailure.SignedOut()
        require(store.backgroundDownloadSession()==mapping.systemSession && store.activeBackgroundDownloads().any {it.mapping==mapping})
        val work=store.resourceDownloads().first {it.work.id==mapping.download}.work
        val remaining=target.remainingLifetimeMillis(work.descriptor)
        require(target.authorization==mapping.authorization && resourceBackgroundOriginDigest(target.target.plan.url)==mapping.originDigest)
        files.prepareBackgroundDownloadSource(mapping)
        val admitted=SystemClock.elapsedRealtime();val lifetime=minOf(remaining,target.remainingLifetimeMillis(work.descriptor))
        val row=SystemDownloadRecord(mapping,store.resourceScope,target.target.plan,ResourceSystemUploadDriver.boot(context),admitted,Math.addExact(admitted,lifetime),exitMarker=exitMarker?.identifier)
        ResourceSystemDownloadJournal.install(context,row)
        val persisted=ResourceSystemDownloadJournal.records(context).first {it.mapping.task==mapping.task}
        if(persisted.cancelled) cancelLocked(mapping) else if(persisted.result==null) enqueue(persisted)
        Unit
    }
    private fun enqueue(row:SystemDownloadRecord) {
        val component=ComponentName(context,service);val info=context.packageManager.getServiceInfo(component,0)
        require(!info.exported && info.permission=="android.permission.BIND_JOB_SERVICE" && info.processName==context.applicationInfo.processName)
        val jobId=systemDownloadJobId(row.mapping.task);val old=scheduler.getPendingJob(jobId)
        if(old!=null) {require(old.extras.getString(TASK)==row.mapping.task && old.service==component);return}
        val extras=PersistableBundle().apply {putString(TASK,row.mapping.task)}
        val job=JobInfo.Builder(jobId,component).setExtras(extras).setPersisted(true)
            .setRequiredNetworkType(if(row.mapping.constraints.allowsExpensive) JobInfo.NETWORK_TYPE_ANY else JobInfo.NETWORK_TYPE_UNMETERED)
            .setEstimatedNetworkBytes(row.mapping.authorization.expectedBytes,0).build()
        check(scheduler.schedule(job)==JobScheduler.RESULT_SUCCESS) {"系统未接纳后台下载任务"}
    }
    suspend fun restore(session:String)=mutations.withLock {
        for(row in ResourceSystemDownloadJournal.records(context).filter {it.mapping.systemSession==session && it.result==null}) {
            if(SystemDownloadFlights.contains(row.mapping.task)) continue
            if(recoverReceivedSystemDownload(context,row)) continue
            if(row.cancelled || exitMarker?.isPending()==true || (row.exitMarker?.let {FileLocalExitMarker.forIdentifier(context,it).isPending()}==true) || row.boot!=ResourceSystemUploadDriver.boot(context) || SystemClock.elapsedRealtime() !in row.admittedElapsed until row.deadlineElapsed || requireNotNull(row.plan).expiresAt<=System.currentTimeMillis()) cancelLocked(row.mapping)
            else enqueue(row)
        }
    }
    suspend fun completions(session:String):PersistentList<ResourceBackgroundDownloadResult> = ResourceSystemDownloadJournal.records(context)
        .filter {it.mapping.systemSession==session}.mapNotNull {it.result}.toPersistentList()
    suspend fun cancelAndDrain(mapping:ResourceBackgroundDownloadMapping)=mutations.withLock {cancelLocked(mapping)}
    private suspend fun cancelLocked(mapping:ResourceBackgroundDownloadMapping):ResourceBackgroundDownloadResult? {
        ResourceSystemDownloadJournal.cancel(context,mapping)
        val id=systemDownloadJobId(mapping.task)
        if(scheduler.getPendingJob(id)?.let {it.extras.getString(TASK)==mapping.task && it.service==ComponentName(context,service)}==true) scheduler.cancel(id)
        SystemDownloadFlights.cancelAndDrain(mapping.task)
        ResourceSystemDownloadJournal.finish(context,mapping.task)
        return ResourceSystemDownloadJournal.records(context).firstOrNull {it.mapping==mapping}?.result
    }
    /** Successful bytes remain received until the account freshly authorizes publication and retires its mapping. */
    suspend fun reconcile(store:SqliteClientStore,files:ManagedResourceFiles,preparing:Set<String> = emptySet(),
        afterDrain:suspend (ResourceBackgroundDownloadMapping,ResourceBackgroundDownloadResult?)->Unit={_,_->}):Int=mutations.withLock {
        val session=store.backgroundDownloadSession();var count=0
        val records=ResourceSystemDownloadJournal.records(context).filter {it.mapping.systemSession==session}
        for(row in records.filter {it.result!=null}) {
            val result=cancelLocked(row.mapping)
            afterDrain(row.mapping,result)
            if(store.finishBackgroundDownload(row.mapping,result)) count++
            if(store.activeBackgroundDownloads().none {it.mapping==row.mapping}) {
                files.releaseBackgroundDownloadSource(row.mapping);ResourceSystemDownloadJournal.acknowledge(context,row.mapping)
            }
        }
        // Interrupted preparation may leave capacity and a mapping but no request. No worker can start without that request.
        for(snapshot in store.activeBackgroundDownloads().filter {s->s.mapping.id !in preparing && records.none {it.mapping==s.mapping}}) {
            val result=cancelLocked(snapshot.mapping)
            afterDrain(snapshot.mapping,result)
            if(store.finishBackgroundDownload(snapshot.mapping,null)) count++
            if(store.activeBackgroundDownloads().none {it.mapping==snapshot.mapping}) files.releaseBackgroundDownloadSource(snapshot.mapping)
        }
        count
    }
    companion object {internal const val TASK="task";private val mutations=Mutex()}
}
internal fun systemDownloadJobId(task:String):Int {
    require(UUID.fromString(task).toString().uppercase()==task)
    return (UUID.fromString(task).hashCode() and 0x1fffffff) or 0x20000000
}
/** The byte inbox is durable before the encrypted receipt. Recover that crash gap without replaying GET. */
internal suspend fun recoverReceivedSystemDownload(context:Context,row:SystemDownloadRecord):Boolean {
    if(row.result!=null || row.cancelled) return false
    if(!runCatching {ResourceBackgroundDownloadInbox(context,row.scope).hasReceived(row.mapping)}.getOrDefault(false)) return false
    ResourceSystemDownloadJournal.finish(context,row.mapping.task,ResourceBackgroundDownloadResult(row.mapping.id,row.mapping.task,200,null,row.mapping.authorization.expectedBytes,row.mapping.originDigest))
    return true
}
internal object SystemDownloadFlights {
    class Flight(val job:Job,val drained:CompletableDeferred<Unit> = CompletableDeferred(),@Volatile var stopped:Boolean=false)
    private val values=ConcurrentHashMap<String,Flight>()
    fun attach(task:String,value:Flight)=values.putIfAbsent(task,value)==null
    fun contains(task:String)=values.containsKey(task)
    fun remove(task:String,value:Flight) {values.remove(task,value);value.drained.complete(Unit)}
    fun stop(task:String) {values[task]?.let {it.stopped=true;it.job.cancel()}}
    fun cancel(task:String) {values[task]?.job?.cancel()}
    suspend fun cancelAndDrain(task:String) {values[task]?.let {it.job.cancel();it.drained.await()}}
}

/** The cold worker opens only the encrypted request log and pre-admitted inbox, never account SQLite or login state. */
open class ResourceDownloadJobService:JobService() {
    private val scope=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate);private val own=mutableSetOf<String>()
    protected open fun baseHttpClient()=okhttp3.OkHttpClient()
    override fun onStartJob(params:JobParameters):Boolean {
        val task=params.extras.getString(ResourceSystemDownloadDriver.TASK) ?: return false
        if(!runCatching {systemDownloadJobId(task)==params.jobId}.getOrDefault(false)) return false
        val job=scope.launch(Dispatchers.IO,start=CoroutineStart.LAZY) {
            try {execute(task,params)} catch(e:CancellationException) {throw e} catch(_:Exception) { /* Unreadable request storage remains recovery debt. Never log it. */ }
        }
        val flight=SystemDownloadFlights.Flight(job)
        if(!SystemDownloadFlights.attach(task,flight)) {job.cancel();return false}
        own.add(task)
        job.invokeOnCompletion {CoroutineScope(NonCancellable+Dispatchers.IO).launch {
            runCatching {
                ResourceSystemDownloadJournal.records(applicationContext).firstOrNull {it.mapping.task==task}?.let {recoverReceivedSystemDownload(applicationContext,it)}
                ResourceSystemDownloadJournal.finish(applicationContext,task)
            }
            SystemDownloadFlights.remove(task,flight)
            withContext(Dispatchers.Main.immediate) {own.remove(task);if(!flight.stopped) jobFinished(params,false)}
        }}
        job.start();return true
    }
    private suspend fun execute(task:String,params:JobParameters) {
        val saved=ResourceSystemDownloadJournal.records(applicationContext).firstOrNull {it.mapping.task==task} ?: return
        if(recoverReceivedSystemDownload(applicationContext,saved)) return
        val row=ResourceSystemDownloadJournal.start(applicationContext,task,ResourceSystemUploadDriver.boot(this),SystemClock.elapsedRealtime(),System.currentTimeMillis()) ?: return
        val plan=requireNotNull(row.plan);val mapping=row.mapping;val inbox=ResourceBackgroundDownloadInbox(this,row.scope)
        val diagnostics=ResourceTransferDiagnostics()
        fun observation()=diagnostics.snapshot().samples.singleOrNull()?.let(ResourceBackgroundTransferObservation::from)
        fun result(status:Int?=null,issue:ResourceDownloadIssue?=null,bytes:Long=0,retry:Long?=null)=ResourceBackgroundDownloadResult(mapping.id,task,status,issue,bytes,mapping.originDigest,retry,observation())
        try {
            withTimeout(minOf(120_000L,(row.deadlineElapsed-SystemClock.elapsedRealtime()).coerceAtLeast(1))) {slots.withPermit {
                if(inbox.hasReceived(mapping,waitForProbe=true)) {
                    ResourceSystemDownloadJournal.finish(applicationContext,task,result(200,bytes=mapping.authorization.expectedBytes));return@withPermit
                }
                val route=boundDownloadRoute(this@ResourceDownloadJobService,plan.url.toHttpUrl().host,params.network) ?: throw ResourceTransferFailure()
                if(!mapping.constraints.allows(route.state)) throw ResourceDownloadPolicyRestricted()
                val client=route.bind(baseHttpClient().newBuilder().dispatcher(okhttp3.Dispatcher()).connectionPool(okhttp3.ConnectionPool(0,1,TimeUnit.SECONDS))).build()
                try {
                    val now={maxOf(System.currentTimeMillis(),plan.expiresAt-(row.deadlineElapsed-SystemClock.elapsedRealtime()))}
                    val downloader=ResourceBackgroundDownloader(client,now)
                    var receipt:ResourceDownloadReceipt?=null
                    val key=SystemTransferProgressKey(row.scope,ResourceTransferKind.Download,mapping.id,task)
                    withContext(ResourceTransferProgressScope {systemTransferProgress.begin(key,it)}+ResourceTransferDiagnosticsScope(diagnostics)) {
                        inbox.receive(mapping,mapping.originDigest) {receipt=downloader.download(plan,it)}
                    }
                    val received=requireNotNull(receipt)
                    ResourceSystemDownloadJournal.finish(applicationContext,task,result(received.status,bytes=received.receivedBytes))
                } finally {client.connectionPool.evictAll();client.dispatcher.executorService.shutdown()}
            }}
        } catch(error:CancellationException) {
            withContext(NonCancellable) {ResourceSystemDownloadJournal.finish(applicationContext,task,row.unknown().copy(observation=observation()))}
            throw error
        }
        catch(error:ClientFailure.Http) {ResourceSystemDownloadJournal.finish(applicationContext,task,result(error.status,retry=resourceBackgroundRetryNotBefore(error.retryAfter,System.currentTimeMillis())))}
        catch(error:Exception) {
            val issue=when(error) {
                is ResourceDownloadPolicyRestricted->ResourceDownloadIssue.Policy
                is ResourceSourceUnavailable->ResourceDownloadIssue.Storage
                is MediaReadFailure->if(error.reason==MediaReadFailureReason.Expired) ResourceDownloadIssue.Interrupted else ResourceDownloadIssue.Integrity
                is java.io.IOException->ResourceDownloadIssue.Network
                else->ResourceDownloadIssue.Storage
            }
            ResourceSystemDownloadJournal.finish(applicationContext,task,result(issue=issue))
        } finally {diagnostics.close()}
    }
    override fun onNetworkChanged(params:JobParameters) {params.extras.getString(ResourceSystemDownloadDriver.TASK)?.let(SystemDownloadFlights::cancel)}
    override fun onStopJob(params:JobParameters):Boolean {params.extras.getString(ResourceSystemDownloadDriver.TASK)?.let(SystemDownloadFlights::stop);return false}
    override fun onDestroy() {own.toList().forEach(SystemDownloadFlights::stop);scope.cancel();super.onDestroy()}
    companion object {private val slots=Semaphore(2)}
}

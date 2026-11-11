package com.xmtx.im.platform

import android.app.job.*
import android.content.*
import android.os.PersistableBundle
import android.os.SystemClock
import android.provider.Settings
import android.system.Os
import android.system.OsConstants
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** Schedules only already-journaled delegated uploads. Parent business work is never executed here. */
class ResourceSystemUploadDriver(context:Context,private val service:Class<out ResourceUploadJobService> = ResourceUploadJobService::class.java,private val exitMarker:FileLocalExitMarker?=null) {
    private val context=context.applicationContext
    private val scheduler=this.context.getSystemService(JobScheduler::class.java)
    init {exitMarker?.requireContext(this.context)}
    suspend fun schedule(store:SqliteClientStore,files:ManagedResourceFiles,mapping:ResourceBackgroundUploadMapping,target:ResourceBackgroundUploadTarget) {
        if(exitMarker?.isPending()==true) throw ClientFailure.SignedOut()
        require(store.backgroundUploadSession()==mapping.systemSession && store.activeBackgroundUploads().any {it==mapping})
        val work=store.resourceUploads().first {it.id==mapping.upload}
        val remaining=target.remainingLifetimeMillis(requireNotNull(work.session),work.request)
        require(target.authorization==mapping.authorization && target.plan.range==mapping.range && target.plan.expectedBytes==mapping.expectedBytes && resourceBackgroundOriginDigest(target.plan.url)==mapping.originDigest)
        files.prepareBackgroundUploadSource(mapping)
        files.withBackgroundUploadSource(mapping) {
            val source=store.backgroundUploadSources().first {it.mapping==mapping && it.state==BackgroundSourceState.Ready}
            val admitted=SystemClock.elapsedRealtime();val lifetime=minOf(remaining,target.remainingLifetimeMillis(requireNotNull(work.session),work.request))
            val record=SystemUploadRecord(mapping,store.resourceScope,requireNotNull(source.checksum),target.plan,boot(context),admitted,Math.addExact(admitted,lifetime),exitMarker=exitMarker?.identifier)
            ResourceSystemUploadJournal.install(context,record)
            val persisted=ResourceSystemUploadJournal.records(context).first {it.mapping.task==mapping.task}
            if(persisted.cancelled) cancelAndDrain(mapping) else if(persisted.result==null) enqueue(persisted)
        }
    }
    private fun enqueue(row:SystemUploadRecord) {
        val info=context.packageManager.getServiceInfo(ComponentName(context,service),0)
        require(!info.exported && info.permission=="android.permission.BIND_JOB_SERVICE" && info.processName==context.applicationInfo.processName)

        val jobId=systemUploadJobId(row.mapping.task)
        val current=scheduler.getPendingJob(jobId)
        if(current!=null) {require(current.extras.getString(TASK)==row.mapping.task && current.service==ComponentName(context,service));return}
        val extras=PersistableBundle().apply {putString(TASK,row.mapping.task)}
        val job=JobInfo.Builder(jobId,ComponentName(context,service)).setExtras(extras)
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY).setEstimatedNetworkBytes(0,row.mapping.expectedBytes)
            .setPersisted(true).build()
        check(scheduler.schedule(job)==JobScheduler.RESULT_SUCCESS) {"系统未接纳后台上传任务"}
    }
    /** Restore interrupted enqueue, never replace a pending/running job or extend the grant lifetime. */
    suspend fun restore(systemSession:String) {
        for(row in ResourceSystemUploadJournal.records(context).filter {it.mapping.systemSession==systemSession && it.result==null}) {
            if(row.cancelled || exitMarker?.isPending()==true || (row.exitMarker?.let {FileLocalExitMarker.forIdentifier(context,it).isPending()}==true) || row.boot!=boot(context) || SystemClock.elapsedRealtime() !in row.admittedElapsed until row.deadlineElapsed || requireNotNull(row.plan).expiresAt<=System.currentTimeMillis()) cancelAndDrain(row.mapping)
            else enqueue(row)
        }
    }
    suspend fun completions(systemSession:String):PersistentList<ResourceBackgroundUploadResult> = ResourceSystemUploadJournal.records(context)
        .filter {it.mapping.systemSession==systemSession}.mapNotNull {it.result}.toPersistentList()
    suspend fun cancelAndDrain(mapping:ResourceBackgroundUploadMapping):ResourceBackgroundUploadResult? {
        ResourceSystemUploadJournal.cancel(context,mapping)
        val id=systemUploadJobId(mapping.task)
        if(scheduler.getPendingJob(id)?.extras?.getString(TASK)==mapping.task) scheduler.cancel(id)
        SystemUploadFlights.cancelAndDrain(mapping.task)
        // A late onStart sees the durable cancellation before any file/network work.
        ResourceSystemUploadJournal.finish(context,mapping.task)
        return ResourceSystemUploadJournal.records(context).firstOrNull {it.mapping==mapping}?.result
    }
    /** Write control-plane reconciliation intent before releasing the source and acknowledging the inbox. */
    suspend fun reconcile(store:SqliteClientStore,files:ManagedResourceFiles,afterDrain:suspend (ResourceBackgroundUploadMapping,ResourceBackgroundUploadResult?)->Unit={_,_->}):Int {
        val session=store.backgroundUploadSession();var count=0
        for(row in ResourceSystemUploadJournal.records(context).filter {it.mapping.systemSession==session && it.result!=null}) {
            val result=cancelAndDrain(row.mapping)
            afterDrain(row.mapping,result)
            if(result==null) continue
            store.completeBackgroundUpload(row.mapping,result)
            files.releaseBackgroundUploadSource(row.mapping)
            ResourceSystemUploadJournal.acknowledge(context,row.mapping);count++
        }
        return count
    }
    companion object {
        internal const val TASK="task"
        internal fun boot(context:Context)=Settings.Global.getInt(context.contentResolver,Settings.Global.BOOT_COUNT)
    }
}
internal fun systemUploadJobId(task:String):Int {
    require(UUID.fromString(task).toString().uppercase()==task)
    return (UUID.fromString(task).hashCode() and 0x3fffffff) or 0x40000000
}
/** One bounded lock file, byte-range lock per opaque task; no per-task lock-file accumulation. */
internal suspend fun <T> withSystemUploadSourceLock(context:Context,task:String,block:suspend ()->T):T=withContext(Dispatchers.IO) {
    val fd=Os.open(File(context.noBackupFilesDir.canonicalFile,"resource-system-upload.lock").path,OsConstants.O_RDWR or OsConstants.O_CREAT or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC,384)
    FileOutputStream(fd).use {stream->
        val lock=try {stream.channel.tryLock(systemUploadJobId(task).toLong(),1,false)} catch(_:java.nio.channels.OverlappingFileLockException) {null}
        check(lock!=null) {"后台上传文件仍在使用"}
        lock.use {block()}
    }
}
internal object SystemUploadFlights {
    class Flight(val job:Job,val drained:CompletableDeferred<Unit> = CompletableDeferred(),@Volatile var stopped:Boolean=false)
    private val values=ConcurrentHashMap<String,Flight>()
    fun attach(task:String,flight:Flight)=values.putIfAbsent(task,flight)==null
    fun remove(task:String,flight:Flight) {values.remove(task,flight);flight.drained.complete(Unit)}
    fun cancel(task:String) {values[task]?.job?.cancel()}
    fun stop(task:String) {values[task]?.let {it.stopped=true;it.job.cancel()}}
    suspend fun cancelAndDrain(task:String) {values[task]?.let {it.job.cancel();it.drained.await()}}
}

/** Can run in a freshly created app process: no ViewModel, login secret, or account database is required. */
open class ResourceUploadJobService:JobService() {
    private val scope=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate)
    private val own=mutableSetOf<String>()
    protected open fun uploader(params:JobParameters,now:()->Long):ResourcePlanUploader {
        val network=requireNotNull(params.network) {"系统尚未提供传输网络"}
        val bound=http.newBuilder().socketFactory(network.socketFactory).dns(object:okhttp3.Dns {override fun lookup(hostname:String)=network.getAllByName(hostname).toList()})
            .connectionPool(okhttp3.ConnectionPool(0,1,java.util.concurrent.TimeUnit.SECONDS)).build()
        return ResourcePlanUploader(bound,now)
    }
    override fun onStartJob(params:JobParameters):Boolean {
        val task=params.extras.getString(ResourceSystemUploadDriver.TASK) ?: return false
        if(runCatching {systemUploadJobId(task)==params.jobId}.getOrDefault(false).not()) return false
        val job=scope.launch(Dispatchers.IO,start=CoroutineStart.LAZY) {
            try {execute(task,params)} catch(error:CancellationException) {throw error} catch(_:Exception) { /* Keep the encrypted record for recovery; never log a capability or crypto error. */ }
        }
        val flight=SystemUploadFlights.Flight(job)
        if(!SystemUploadFlights.attach(task,flight)) {job.cancel();return false}
        own.add(task)
        job.invokeOnCompletion {
            // Also covers cancellation before the lazy coroutine reached its first instruction.
            CoroutineScope(NonCancellable+Dispatchers.IO).launch {
                // Unreadable storage remains owner-visible debt; do not create an unbounded system retry loop.
                runCatching {ResourceSystemUploadJournal.finish(applicationContext,task)}
                SystemUploadFlights.remove(task,flight)
                withContext(Dispatchers.Main.immediate) {own.remove(task);if(!flight.stopped) jobFinished(params,false)}
            }
        }
        job.start();return true
    }
    private suspend fun execute(task:String,params:JobParameters) {
        val row=ResourceSystemUploadJournal.start(applicationContext,task,ResourceSystemUploadDriver.boot(this),SystemClock.elapsedRealtime(),System.currentTimeMillis()) ?: return
        val plan=requireNotNull(row.plan)
        val diagnostics=ResourceTransferDiagnostics()
        fun observation()=diagnostics.snapshot().samples.singleOrNull()?.let(ResourceBackgroundTransferObservation::from)
        try {
            withTimeout(minOf(120_000L,(row.deadlineElapsed-SystemClock.elapsedRealtime()).coerceAtLeast(1))) {slots.withPermit {
                withSystemUploadSourceLock(applicationContext,task) {
                    currentCoroutineContext().ensureActive()
                    val root=File(noBackupFilesDir.canonicalFile,"resources-${row.scope}/background-uploads")
                    val file=File(root,row.mapping.id)
                    require(file.canonicalFile==file.absoluteFile && OsConstants.S_ISREG(Os.lstat(file.path).st_mode))
                    // Keep the persisted elapsed deadline binding even if the wall clock moves backwards.
                    val now={maxOf(System.currentTimeMillis(),plan.expiresAt-(row.deadlineElapsed-SystemClock.elapsedRealtime()))}
                    val key=SystemTransferProgressKey(row.scope,ResourceTransferKind.Upload,row.mapping.id,task)
                    val receipt=withContext(ResourceTransferProgressScope {systemTransferProgress.begin(key,it)}+ResourceTransferDiagnosticsScope(diagnostics)) {
                        uploader(params,now).uploadReceipt(file,plan,row.checksum)
                    }
                    ResourceSystemUploadJournal.finish(applicationContext,task,ResourceBackgroundUploadResult(row.mapping.id,task,receipt.status,null,receipt.sentBytes,receipt.originDigest,observation=observation()))
                }
            }}
        } catch(error:CancellationException) {
            withContext(NonCancellable) {ResourceSystemUploadJournal.finish(applicationContext,task,row.unknown().copy(observation=observation()))}
            throw error
        }
        catch(error:ClientFailure.Http) {
            ResourceSystemUploadJournal.finish(applicationContext,task,ResourceBackgroundUploadResult(row.mapping.id,task,error.status,null,0,row.mapping.originDigest,resourceBackgroundRetryNotBefore(error.retryAfter,System.currentTimeMillis()),observation()))
        } catch(_:Exception) {ResourceSystemUploadJournal.finish(applicationContext,task,row.unknown().copy(observation=observation()))}
        finally {diagnostics.close()}
    }
    override fun onNetworkChanged(params:JobParameters) {
        params.extras.getString(ResourceSystemUploadDriver.TASK)?.let(SystemUploadFlights::cancel)
    }
    override fun onStopJob(params:JobParameters):Boolean {
        params.extras.getString(ResourceSystemUploadDriver.TASK)?.let(SystemUploadFlights::stop)
        return false // After drain the owner reconciles the original session, rather than replaying an unknown PUT blindly.
    }
    override fun onDestroy() {own.toList().forEach(SystemUploadFlights::stop);scope.cancel();super.onDestroy()}
    companion object {private val slots=Semaphore(2);private val http by lazy {okhttp3.OkHttpClient()}}
}

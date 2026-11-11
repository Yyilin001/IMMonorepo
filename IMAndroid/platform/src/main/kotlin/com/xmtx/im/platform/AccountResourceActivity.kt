package com.xmtx.im.platform

import android.content.Context
import com.xmtx.im.client.*
import kotlinx.collections.immutable.PersistentList
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** One account owns its files; foreground and explicit background clients share one drained engine generation. */
class AccountResourceActivity(context: Context,private val store: SqliteClientStore,private val control: ResourceUploadControl,
    private val imports: ResourceImportControl?=null,download: (suspend (MediaDownloadTarget,java.io.File)->Unit)?=null,
    targets:MediaTargetResolving?=null,backgroundControl:ResourceBackgroundUploadControl?=control as? ResourceBackgroundUploadControl,
    systemUploads:ResourceSystemUploadDriver=ResourceSystemUploadDriver(context),
    systemDownloads:ResourceSystemDownloadDriver=ResourceSystemDownloadDriver(context),
    private val automaticNetwork:()->Boolean={automaticDownloadNetworkAllowed(context)},
    scheduler:AccountWorkScheduler?=null,
    private val bytes: (ManagedResourceFiles)->ResourceUploadBytes={ ManagedResourceUploadBytes(it) }) {
    private val diagnostics=scheduler?.networkDiagnostics
    val transferWaiting=ResourceTransferWaiting()
    private val nativeProgress=AccountNativeTransferProgress(store.resourceScope,transferWaiting)
    private val nativeAdmission=AccountSystemTransferAdmission(context,store.resourceScope,scheduler,nativeProgress)
    val files:ManagedResourceFiles=ManagedResourceFiles(context,store,download=download,scheduler=scheduler,beforeTransfer=::prepareNetworkTransfers)
    private val delegated=AccountSystemUploads(context,store,files,backgroundControl,systemUploads,nativeAdmission)
    private val delegatedDownloads=AccountSystemDownloads(context,store,files,targets,systemDownloads,nativeAdmission,transferWaiting)
    private val importService=imports?.let { ResourceImportService(store.resourceActor,store,it,waiting=transferWaiting) }
    @Volatile private var automaticForeground=false
    private val downloadService=targets?.let {resolving->ResourceDownloadService(store,automaticForeground={automaticForeground},automaticNetwork={automaticNetwork()},waiting=transferWaiting,automaticWaiting={automaticDownloadWaitingReason(context)}) download@{claim,complete->
        var initial:MediaDownloadTarget?=null
        val reader=MessageOriginalFiles({media,message,size->
            (initial ?: resolving.resolve(media,message,size)).also {target->
                if(target.preview!=null || target.plan.checksum!=claim.work.descriptor.checksum || target.plan.expectedBytes!=claim.work.descriptor.byteCount)
                    throw MediaReadFailure(MediaReadFailureReason.Integrity)
                initial=target
            }
        },store,files)
        try {
            if(delegatedDownloads.canDelegate()) {
                val cached=reader.withAuthorizedOriginal(claim.work.descriptor.key,cacheOnly=true,message=claim.work.message) {read,_->complete(read.evidence);true}
                if(cached==true || delegatedDownloads.delegate(claim,requireNotNull(initial))) return@download
            }
            reader.withAuthorizedOriginal(claim.work.descriptor.key,message=claim.work.message) {read,_->complete(read.evidence)}
        }
        finally {reader.close()}
    }}
    private class Generation(val task:Deferred<Unit>) {
        val clients=mutableMapOf<Job,Boolean>()
        var draining=false
    }
    private val mutex=Mutex();private val scope=CoroutineScope(SupervisorJob()+Dispatchers.IO)
    private var generation:Generation?=null;private var closed=false

    private val nativePreparation=Mutex();private var nativePrepared=false

    /** Call before exposing other byte clients (for example avatars) on this account scheduler. */
    suspend fun prepareNetworkTransfers():Unit=nativePreparation.withLock {
        if(!nativePrepared) {
            nativeAdmission.prepare()
            delegated.recover();delegatedDownloads.recover()
            scope.launch {nativeProgress.observe()}
            nativePrepared=true
        }
    }

    /** One foreground observer and one explicit background session share the same physical engines. */
    suspend fun runForeground(onSnapshot: (PersistentList<ResourceUploadWork>)->Unit = {}):Unit=withExecution(false) { task->coroutineScope {
        launch {store.resourceUploadChanges.collect {onSnapshot(store.resourceUploads())}}
        task.await()
    }}

    /** A bounded, interruptible execution lease. It neither persists credentials nor submits business changes. */
    suspend fun runBackground(maximumRunMillis:Long=15*60_000L):ResourceBackgroundRunResult {
        require(maximumRunMillis in 1..15*60_000L)
        return withExecution(true) {task->
            val complete=withTimeoutOrNull(maximumRunMillis) {coroutineScope {
                val watch=launch {task.await()}
                try {store.resourceTransferChanges.first { !hasRunnableWork() };true}
                finally {watch.cancelAndJoin()}
            }}
            if(complete==true) ResourceBackgroundRunResult.Completed else ResourceBackgroundRunResult.BudgetExpired
        }
    }
    private suspend fun hasRunnableWork():Boolean {
        if(store.resourceUploads().any {it.execution.backgroundPending || !it.terminal && !it.execution.attention && !it.execution.userPaused}) return true
        if(importService!=null && store.resourceImports().any {!it.terminal && !it.execution.attention && !it.execution.paused}) return true
        return downloadService!=null && store.resourceDownloads().any {val w=it.work;!w.terminal && w.requested && w.control==ResourceDownloadControl.Run}
    }
    private suspend fun <T> withExecution(background:Boolean,body:suspend (Deferred<Unit>)->T):T=coroutineScope {
        val client=currentCoroutineContext().job
        var selected:Generation?=null
        while(selected==null) {
            val waiting=mutex.withLock {
                check(!closed) {"资源活动已关闭"}
                val current=generation ?: Generation(scope.async(start=CoroutineStart.LAZY) {runEngines()}).also {generation=it}
                if(current.draining) current.task
                else {
                    check(current.clients.values.none {it==background}) {"资源执行会话已存在"}
                    if(background) {delegated.enable();delegatedDownloads.enable()}
                    current.clients[client]=background;if(!background) automaticForeground=true;selected=current;current.task.start();null
                }
            }
            if(selected==null) {
                waiting?.join();currentCoroutineContext().ensureActive()
                mutex.withLock {if(generation?.task===waiting && generation?.draining==true) generation=null}
            }
        }
        val current=requireNotNull(selected)
        try {body(current.task)} finally {withContext(NonCancellable) {
            var drain=false
            try {mutex.withLock {
                try {if(background) try {delegated.disableAndDrain()} finally {delegatedDownloads.disableAndDrain()}}
                finally {
                    current.clients.remove(client);if(!background) automaticForeground=false
                    if(current.clients.isEmpty()) {current.draining=true;current.task.cancel();drain=true}
                }
            }} finally {
                if(drain) {
                    current.task.join()
                    mutex.withLock {if(generation===current) generation=null}
                }
            }
        }}
    }
    private suspend fun runEngines():Unit=coroutineScope {
        val engine=ResourceUploadEngine(store,control,bytes(files),delegate=delegated::delegate,waiting=transferWaiting,diagnostics=diagnostics)
        try {coroutineScope {
            prepareNetworkTransfers()
            delegated.recover()
            delegatedDownloads.recover()
            engine.start()
            launch {delegated.observe()}
            launch {delegatedDownloads.observe()}
            launch {while(store.indexResourceProjectionBatch()) {ensureActive();yield()}}
            importService?.let {service->launch {service.runForeground()}}
            downloadService?.let {service->launch {service.runForeground()}}
            engine.state.first {it==ResourceEngineState.Failed || it==ResourceEngineState.Closed}
            error("资源任务恢复已暂停，请重新进入应用后重试")
        }} finally {withContext(NonCancellable) {try {engine.close()} finally {try {delegated.disableAndDrain()} finally {delegatedDownloads.disableAndDrain()}}}}
    }
    /** Cancels both execution leases and drains every actual I/O before releasing the file owner. */
    suspend fun close() = withContext(NonCancellable) {
        val (current,clients)=mutex.withLock {closed=true;generation to generation?.clients?.keys?.toList().orEmpty()}
        current?.task?.cancel();clients.forEach {it.cancel()}
        current?.task?.join();clients.forEach {it.join()}
        scope.coroutineContext.job.cancelAndJoin();nativeProgress.close();delegated.close();delegatedDownloads.close();files.close();transferWaiting.close()
    }
}

enum class ResourceBackgroundRunResult { Completed,BudgetExpired }

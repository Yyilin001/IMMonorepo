package com.xmtx.im.platform

import android.content.Context
import android.content.ContentResolver
import android.net.Uri
import android.os.CancellationSignal
import android.provider.OpenableColumns
import java.util.concurrent.atomic.AtomicReference
import android.os.StatFs
import android.system.Os
import android.system.OsConstants
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlin.coroutines.EmptyCoroutineContext
import java.io.*
import java.nio.channels.FileLock
import java.security.MessageDigest
import java.util.UUID

/** Account/device owner. Close and drain this owner before closing its SQLite store. */
class ManagedResourceFiles(context: Context,private val journal: SqliteClientStore,
    policy: ResourceOriginalPolicy=ResourceOriginalPolicy(),
    private val checkpoint: (PublicationCheckpoint)->Unit={},
    private val cleanupClock:()->Long=android.os.SystemClock::elapsedRealtime,
    download: (suspend (MediaDownloadTarget,File)->Unit)?=null,
    private val backgroundCheckpoint:(BackgroundSourceCheckpoint)->Unit={},
    private val scheduler:AccountWorkScheduler?=null,
    private val beforeTransfer:suspend ()->Unit={}): ResourceDownloadFiles,ResourceRetentionFiles,ResourceBatchRetentionFiles,ResourceUnavailableRetentionFiles,ResourceStorageFiles,ResourceCleanupFiles,ResourceSelectionCleanupFiles {
    private val download=download ?: PolicyMediaFileDownloader(context,journal)::download
    private val applicationContext=context.applicationContext
    private var policy=policy
    private var policyLoaded=false
    enum class BackgroundSourceCheckpoint { Reserved, Copied, Renamed, Ready, Deleting, Unlinked }
    enum class PublicationCheckpoint { Journaled, Copied, Renamed, Published }
    private val root=File(context.noBackupFilesDir.canonicalFile,"resources-${journal.resourceScope}")
    private val downloadInbox=ResourceBackgroundDownloadInbox(context,journal.resourceScope)
    private val files=File(root,"files");private val partials=File(root,"partials")
    private val backgrounds=File(root,"background-uploads");private val backgroundPartials=File(root,"background-partials")
    private val documents=File(root,"document-imports");private val documentReservations=mutableMapOf<String,Long>()
    private val parts=File(root,"upload-parts");private val partReservations=mutableMapOf<String,Long>();private var uploadOwner: String?=null
    private val mutex=Mutex();private var lockFile: FileOutputStream?=null;private var ownerLock: FileLock?=null
    private var recovered=false;private var closing=false;private val leases=mutableMapOf<String,String>()
    private val drained=CompletableDeferred<Unit>()
    private class DownloadFlight(val id: String,val task: Deferred<Unit>,val demand:ByteTransferDemand,var users: Int=0) { val drained=CompletableDeferred<Unit>() }
    private val downloadScope=CoroutineScope(SupervisorJob()+Dispatchers.IO)
    private val downloadSlots=kotlinx.coroutines.sync.Semaphore(2)
    private val downloads=mutableMapOf<String,DownloadFlight>()
    private class CleanupPreview(val plan:ResourceCleanupPlan,val created:Long,val records:PersistentList<ResourceLocalFile>) {
        val reused=mutableSetOf<String>()
    }
    private val cleanupPlans=mutableMapOf<String,CleanupPreview>()
    private fun invalidateCleanupCandidate(id:String) {cleanupPlans.values.forEach {preview->if(preview.records.any {it.id==id}) preview.reused.add(id)}}
    private fun signalDrain() { if(closing && leases.isEmpty() && uploadOwner==null && downloads.isEmpty()) drained.complete(Unit) }

    suspend fun importFile(source: File,displayName: String,contentType: String,purpose: ResourceUsage,maximumBytes: Long,
        id: String=UUID.randomUUID().toString().uppercase(),dimensions: ResourceDimensions?=null): ResourceLocalAsset = withContext(Dispatchers.IO) { mutex.withLock {
        prepare();require(maximumBytes>0)
        val normalized=resourceDisplayName(displayName)
        readRegular(source).use { input ->
            val size=Os.fstat(input.fd).st_size;require(size in 1..maximumBytes)
            val checksum=digest(input,size);input.channel.position(0)
            publishOriginal(input,size,checksum,normalized,contentType,purpose,id,dimensions)
        }
    } }
    /** Stream a one-time system document grant into account-owned originals. Provider metadata is advisory. */
    suspend fun importDocument(resolver: ContentResolver,uri: Uri,purpose: ResourceUsage,
        maximumBytes: Long=50L*1024*1024,id: String=UUID.randomUUID().toString().uppercase()): ResourceLocalAsset {
        require(uri.scheme==ContentResolver.SCHEME_CONTENT && maximumBytes in 1..50L*1024*1024)
        try { return withTimeout(60_000) { withContext(Dispatchers.IO) { mutex.withLock {
            prepare()
            val staging=managed(documents,id)
            try { coroutineScope {
                val signal=CancellationSignal();val active=AtomicReference<InputStream?>()
                val closer=launch(start=CoroutineStart.UNDISPATCHED) {
                    try { awaitCancellation() } finally { signal.cancel();runCatching { active.getAndSet(null)?.close() } }
                }
                try {
                    var name="附件";var advertised: Long?=null
                    resolver.query(uri,arrayOf(OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE),null,null,null,signal)?.use { rows ->
                        if(rows.moveToFirst()) {
                            val n=rows.getColumnIndex(OpenableColumns.DISPLAY_NAME);val size=rows.getColumnIndex(OpenableColumns.SIZE)
                            if(n>=0 && !rows.isNull(n)) name=rows.getString(n)
                            if(size>=0 && !rows.isNull(size)) advertised=rows.getLong(size).takeIf { it>=0 }
                        }
                    }
                    val normalized=resourceDisplayName(name)
                    val type=resolver.getType(uri)?.lowercase(java.util.Locale.ROOT)?.takeIf { runCatching { requireResourceContentType(it) }.isSuccess } ?: "application/octet-stream"
                    require(advertised==null || advertised!!<=maximumBytes) { "文件超过 50 MB 上限" }
                    val descriptor=resolver.openAssetFileDescriptor(uri,"r",signal) ?: throw IOException("无法读取文件")
                    val temporary=temporaryUsage()
                    var count=0L;val hash=MessageDigest.getInstance("SHA-256")
                    descriptor.use { asset ->
                        require(asset.length<0 || asset.length<=maximumBytes) { "文件超过 50 MB 上限" }
                        asset.createInputStream().use { input ->
                            active.set(input);currentCoroutineContext().ensureActive()
                            writeNew(staging).use { output ->
                                val buffer=ByteArray(64*1024)
                                while(true) {
                                    currentCoroutineContext().ensureActive()
                                    val read=input.read(buffer,0,minOf(buffer.size.toLong(),maximumBytes-count+1).toInt())
                                    if(read<0) break
                                    if(read==0) { yield();continue }
                                    require(read<=maximumBytes-count) { "文件超过 50 MB 上限" }
                                    trimCache(additionalManagedBytes=read.toLong(),enforceCache=false)
                                    requireFree(read.toLong());output.write(buffer,0,read);hash.update(buffer,0,read);count+=read
                                    documentReservations[id]=maxOf(count,allocated(staging));trimCache(enforceCache=false)
                                    check(temporary+2*allocated(staging)<=policy.maximumTemporaryBytes) { "附件临时空间不足" }
                                }
                                require(count>0) { "无法添加空文件" };output.fd.sync()
                            }
                        }
                    }
                    active.set(null)
                    val checksum=ResourceChecksum(hash.digest().joinToString("") { "%02x".format(it) })
                    readRegular(staging).use { publishOriginal(it,count,checksum,normalized,type,purpose,id,null) }
                } finally { closer.cancelAndJoin() }
            } } finally { remove(staging);documentReservations.remove(id);syncDirectory(documents) }
        } } } } catch(error: CancellationException) {
            withContext(NonCancellable+Dispatchers.IO) { mutex.withLock { journal.releaseResourceSelection(id) } }
            if(error is TimeoutCancellationException && currentCoroutineContext().isActive) throw IOException("读取文件超时，请重新选择",error)
            throw error
        }
    }
    /** Normalized pixels go directly into the account original; there is no untracked temporary disk copy. */
    suspend fun importPhoto(photo: NormalizedPhoto,purpose: ResourceUsage,id: String=UUID.randomUUID().toString().uppercase(),
        displayName: String=if(photo.contentType=="image/png") "图片.png" else "图片.jpg"): ResourceLocalAsset {
        try { return withContext(Dispatchers.IO) { mutex.withLock {
            prepare()
            val checksum=photo.data.newInput().use { digest(it,photo.byteCount) }
            photo.data.newInput().use { publishOriginal(it,photo.byteCount,checksum,resourceDisplayName(displayName),photo.contentType,purpose,id,photo.dimensions) }
        } } } catch(error: CancellationException) {
            // Also covers cancellation after publication while returning from the I/O dispatcher.
            withContext(NonCancellable+Dispatchers.IO) { mutex.withLock { journal.releaseResourceSelection(id) } }
            throw error
        }
    }
    private suspend fun publishOriginal(input: InputStream,size: Long,checksum: ResourceChecksum,normalized: String,
        contentType: String,purpose: ResourceUsage,id: String,dimensions: ResourceDimensions?): ResourceLocalAsset {
        val old=journal.resourceAssets().firstOrNull { it.id==id }
        if(old!=null) {
            require(old.availability==ResourceAssetAvailability.Local && old.selectionActive && old.checksum==checksum && old.byteCount==size && old.displayName==normalized && old.contentType==contentType && old.purpose==purpose && old.dimensions==dimensions)
            verify(requireNotNull(old.file),size,checksum);return old
        }
        var reusable: ResourceLocalFile?=null
        for(candidate in journal.resourceFiles().filter { it.state==ResourceFileState.Published && it.byteCount==size && it.checksum==checksum }) {
            try { verify(candidate.id,size,checksum);reusable=candidate;break } catch(_: InvalidResourceBytes) { journal.markResourceFile(candidate.id,ResourceFileState.Invalid) }
        }
        val fileId=reusable?.id ?: UUID.randomUUID().toString().uppercase()
        invalidateCleanupCandidate(fileId)
        if(reusable==null) {
            val originals=journal.resourceFiles().filter {it.kind==ResourceFileKind.Original}.fold(0L) {sum,row->Math.addExact(sum,row.chargedBytes)}
            check(size<=policy.maximumOriginalBytes && originals<=policy.maximumOriginalBytes-size) {"待发送原件额度不足"}
            trimCache(additionalManagedBytes=size,enforceCache=false);requireFree(size)
        }
        val asset=ResourceLocalAsset(id,fileId,null,normalized,contentType,size,checksum,purpose,dimensions,ResourceAssetAvailability.Importing,true,System.currentTimeMillis())
        try {
            journal.beginResourceImport(asset,policy)
            checkpoint(PublicationCheckpoint.Journaled)
            if(reusable==null) {
                val partial=managed(partials,fileId)
                writeNew(partial).use { output -> copyVerified(input,output,size,checksum);output.fd.sync() }
                trimCache(excluding=setOf(fileId),enforceCache=false)
                journal.reserveResourceAllocation(fileId,allocated(partial),policy)
                checkpoint(PublicationCheckpoint.Copied)
                currentCoroutineContext().ensureActive()
                val target=managed(files,fileId);check(!target.exists());Os.rename(partial.path,target.path);Os.chmod(target.path,256);syncDirectory(files);syncDirectory(partials)
                checkpoint(PublicationCheckpoint.Renamed)
            }
            val allocated=allocated(managed(files,fileId))
            val published=journal.publishResourceImport(id,fileId,allocated)
            checkpoint(PublicationCheckpoint.Published);return published
        } catch(error: Throwable) {
            recovered=false
            if(error is CancellationException) withContext(NonCancellable) { journal.releaseResourceSelection(id) }
            throw error
        }
    }
    /** One account file owner serves originals and cache bytes; cleanup excludes every active borrow. */
    override suspend fun <T> withDownloaded(target: MediaDownloadTarget,cacheOnly: Boolean,block: suspend (File)->T): T?=withContext(Dispatchers.IO) {
        val automatic=currentCoroutineContext()[AutomaticResourceDownload]
        val scoped=scheduler?.let {currentCoroutineContext().networkWorkFor(it)}
        val transferWait=currentCoroutineContext()[ResourceTransferWaitScope]
        val priority=if(automatic!=null) NetworkWorkPriority.Background else scoped?.priority ?: NetworkWorkPriority.Interactive
        var token: String?=null;var flight: DownloadFlight?=null;var fileId: String?=null
        try {
            while(true) {
            var draining: DownloadFlight?=null
            mutex.withLock {
                prepare();target.requireValid()
                val checksum=requireNotNull(target.plan.checksum);val bytes=target.plan.expectedBytes
                val matches=journal.resourceFiles().filter { it.checksum==checksum && it.byteCount==bytes }
                for(record in matches.filter { it.state==ResourceFileState.Published }) {
                    try { verify(record.id,bytes,checksum);fileId=record.id;break }
                    catch(_: InvalidResourceBytes) { journal.markResourceFile(record.id,ResourceFileState.Invalid) }
                }
                if(fileId==null && !cacheOnly) {
                    // A retained corrupt copy must not consume the only slot needed to replace itself.
                    // Other readers/downloads still own their bytes until their callbacks drain.
                    for(invalid in journal.resourceFiles().filter {it.kind==ResourceFileKind.Cache && it.checksum==checksum && it.byteCount==bytes &&
                        it.state in setOf(ResourceFileState.Invalid,ResourceFileState.Missing) && it.id !in leases.values && it.id !in downloads}) {
                        journal.retireResourceCache(invalid.id);removeRecord(invalid.id)
                    }
                    var pending=matches.firstOrNull { it.kind==ResourceFileKind.Cache && it.state==ResourceFileState.Publishing }
                    if(pending==null) {
                        val retained=journal.resourceBytesRetained(bytes,checksum)
                        trimCache(if(retained) 0 else bytes,if(retained) 0 else 1,additionalManagedBytes=bytes,enforceCache=!retained)
                        val promised=journal.resourceFiles().filter { it.state==ResourceFileState.Publishing }.fold(bytes) { sum,record -> Math.addExact(sum,maxOf(0,record.byteCount-record.allocatedBytes)) }
                        requireFree(promised)
                        pending=journal.beginResourceDownload(UUID.randomUUID().toString().uppercase(),bytes,checksum,policy)
                    }
                    val prior=downloads[pending.id]
                    if(prior!=null && prior.task.isCancelled) { draining=prior;return@withLock }
                    fileId=pending.id
                    invalidateCleanupCandidate(pending.id)
                    flight=downloads[pending.id] ?: run {
                        val record=pending;val admittedPolicy=journal.resourceDownloadAdmission(record.id,policy)
                        val demand=ByteTransferDemand(priority)
                        val work=scheduler?.let {NetworkWorkScope(it,NetworkWorkContext("mediaProvider",priority,NetworkWorkKind.Download,isRetry=scoped?.isRetry ?: false))}
                        val task=downloadScope.async((automatic ?: EmptyCoroutineContext)+(work ?: EmptyCoroutineContext)+(transferWait ?: EmptyCoroutineContext)+demand,start=CoroutineStart.LAZY) {
                            if(scheduler==null) downloadSlots.withPermit {performDownload(record,target,admittedPolicy)}
                            else performDownload(record,target,admittedPolicy)
                        }
                        DownloadFlight(record.id,task,demand).also { downloads[record.id]=it }
                    }
                    flight!!.demand.promote(priority)
                    flight!!.users++
                } else if(fileId!=null) {
                    invalidateCleanupCandidate(fileId!!)
                    token=UUID.randomUUID().toString();leases[token!!]=fileId!!
                    journal.touchResourceDownload(fileId!!)
                }
            }
            val waiting=draining
            if(waiting!=null) {
                waiting.drained.await()
                currentCoroutineContext().ensureActive();continue
            }
            break
            }
            val id=fileId ?: return@withContext null
            flight?.let { active ->
                active.task.start();active.task.await()
                mutex.withLock {
                    prepare();target.requireValid();verify(id,target.plan.expectedBytes,requireNotNull(target.plan.checksum))
                    token=UUID.randomUUID().toString();leases[token!!]=id;journal.touchResourceDownload(id)
                }
            }
            currentCoroutineContext().ensureActive();target.requireValid();block(managed(files,id))
        } finally { withContext(NonCancellable) {
            val abandoned=mutex.withLock {
                token?.let { leases.remove(it) }
                flight?.let { it.users--;if(it.users==0) { it.task.cancel();it } else null }.also { signalDrain() }
            }
            if(abandoned!=null) {
                abandoned.task.cancel();abandoned.task.join()
                mutex.withLock { if(downloads[abandoned.id]===abandoned && abandoned.users==0) { downloads.remove(abandoned.id);if(abandoned.task.isCancelled) recovered=false };abandoned.drained.complete(Unit);signalDrain() }
            }
        } }
    }
    private suspend fun performDownload(record: ResourceLocalFile,target: MediaDownloadTarget,admitted:ResourceOriginalPolicy) {
        val staging=managed(partials,record.id)
        try {
            beforeTransfer();target.requireValid();download(target,staging)
            mutex.withLock {
                currentCoroutineContext().ensureActive();check(!closing);target.requireValid()
                // A settings change cannot revoke the capacity already granted to this transfer.
                val completionPolicy=policy.copy(maximumCacheBytes=maxOf(policy.maximumCacheBytes,admitted.maximumCacheBytes),
                    maximumTemporaryBytes=maxOf(policy.maximumTemporaryBytes,admitted.maximumTemporaryBytes),maximumManagedBytes=if(policy.maximumManagedBytes==null || admitted.maximumManagedBytes==null) null else maxOf(requireNotNull(policy.maximumManagedBytes),requireNotNull(admitted.maximumManagedBytes)))
                verifyPath(staging,record.byteCount,record.checksum)
                val current=journal.resourceFiles().first {it.id==record.id}
                val cacheGrowth=if(current.retained) 0 else (maxOf(current.byteCount,allocated(staging))-current.chargedBytes).coerceAtLeast(0)
                trimCache(additionalBytes=cacheGrowth,excluding=setOf(record.id),admissionPolicy=completionPolicy,enforceCache=!current.retained,enforceEntries=false)
                journal.reserveResourceAllocation(record.id,allocated(staging),completionPolicy)
                checkpoint(PublicationCheckpoint.Copied)
                check(!exists(managed(files,record.id)));Os.rename(staging.path,managed(files,record.id).path)
                Os.chmod(managed(files,record.id).path,256);syncDirectory(files);syncDirectory(partials)
                checkpoint(PublicationCheckpoint.Renamed)
                journal.publishResourceDownload(record.id,allocated(managed(files,record.id)),completionPolicy)
                checkpoint(PublicationCheckpoint.Published)
            }
        } catch(error: Throwable) {
            withContext(NonCancellable) { mutex.withLock { recovered=false } }
            throw error
        }
    }
    private suspend fun recoverDownload(record: ResourceLocalFile) {
        if(record.id in downloads) return
        val published=managed(files,record.id);val staging=managed(partials,record.id)
        val candidate=when { exists(published)->published;exists(staging)->staging;else->return }
        try {
            verifyPath(candidate,record.byteCount,record.checksum)
            if(candidate==staging) { check(!exists(published));Os.rename(staging.path,published.path);syncDirectory(partials) }
            Os.chmod(published.path,256);syncDirectory(files)
            journal.recoverResourceDownload(record.id,allocated(published))
        } catch(_: InvalidResourceBytes) { journal.markResourceFile(record.id,ResourceFileState.Invalid) }
    }
    /** Eviction never deletes originals, retained bytes, active downloads, or borrowed files. */
    private suspend fun trimCache(additionalBytes:Long=0,additionalEntries:Int=0,bestEffort:Boolean=false,
        additionalManagedBytes:Long=0,excluding:Set<String> = emptySet(),admissionPolicy:ResourceOriginalPolicy=policy,enforceCache:Boolean=true,enforceEntries:Boolean=true) {
        require(additionalBytes>=0 && additionalManagedBytes>=0 && additionalBytes<=admissionPolicy.maximumCacheBytes && additionalEntries<=admissionPolicy.maximumCacheEntries)
        val maximum=admissionPolicy.maximumManagedBytes
        require(maximum==null || additionalManagedBytes<=maximum) {"托管文件总额度不足"}
        while(true) {
            val rows=journal.resourceFiles();val cache=rows.filter {it.kind==ResourceFileKind.Cache && !it.retained}
            val charge=cache.fold(0L) {sum,file->Math.addExact(sum,file.chargedBytes)}
            val managedFits=maximum==null || managedUsage(rows)<=maximum-additionalManagedBytes
            if((!enforceCache || charge<=admissionPolicy.maximumCacheBytes-additionalBytes && (!enforceEntries || cache.size<=admissionPolicy.maximumCacheEntries-additionalEntries)) && managedFits) return
            val victim=cache.filter {it.id !in leases.values && it.id !in downloads && it.id !in excluding}.minWithOrNull(compareBy<ResourceLocalFile> {it.lastUsed}.thenBy {it.id})
            if(victim==null) {if(bestEffort) return;error("资源额度不足，保留文件、原件或正在使用的文件无法自动释放")}
            journal.retireResourceCache(victim.id);removeRecord(victim.id)
        }
    }
    private fun allocatedIfPresent(file:File):Long=try {allocated(file)} catch(error:android.system.ErrnoException) {if(error.errno==OsConstants.ENOENT) 0 else throw error}
    /** A pending row owns its future file credit; rename publication does not add a second payload. */
    private suspend fun managedUsage(rows:List<ResourceLocalFile>):Long {
        var used=rows.fold(0L) {sum,row->Math.addExact(sum,maxOf(if(row.state==ResourceFileState.Missing) 0 else row.chargedBytes,cleanupAllocated(row.id)))}
        for((id,reserved) in documentReservations) used=Math.addExact(used,maxOf(reserved,allocatedIfPresent(managed(documents,id))))
        for((id,reserved) in partReservations) used=Math.addExact(used,maxOf(reserved,allocatedIfPresent(managed(parts,id))))
        return Math.addExact(used,backgroundReserved())
    }
    private suspend fun removeRecord(id: String) {
        remove(managed(files,id));remove(managed(partials,id))
        for(suffix in listOf(".range-part",".range-journal",".range-journal-new")) remove(File(partials,id+suffix))
        syncDirectory(files);syncDirectory(partials);journal.deleteResourceFile(id)
    }
    suspend fun selected(purpose: ResourceUsage): PersistentList<ResourceLocalAsset> = withContext(Dispatchers.IO) { mutex.withLock {
        prepare();journal.resourceAssets().filter { it.selectionActive && it.purpose==purpose }.toPersistentList()
    } }
    suspend fun discardSelection(id: String) = withContext(Dispatchers.IO) { mutex.withLock { prepare();journal.releaseResourceSelection(id) } }

    /** File handles never enter immutable UI snapshots. The callback owns the borrow until it drains. */
    suspend fun <T> withOriginal(selection: String?=null,upload: String?=null,profile: ProfileOriginalConsumer?=null,block: suspend (File)->T): T=withContext(Dispatchers.IO) {
        var token: String?=null
        try {
            val file=mutex.withLock {
                prepare();val asset=journal.resourceOriginal(selection,upload,profile);val id=requireNotNull(asset.file)
                invalidateCleanupCandidate(id)
                try { verify(id,asset.byteCount,asset.checksum) } catch(error: InvalidResourceBytes) { journal.markResourceFile(id,ResourceFileState.Invalid);throw error }
                token=UUID.randomUUID().toString();leases[token!!]=id;managed(files,id)
            }
            block(file)
        } finally { withContext(NonCancellable) { mutex.withLock { token?.let { leases.remove(it) };signalDrain() } } }
    }
    internal suspend fun downloadDemandCount()=mutex.withLock { downloads.values.sumOf { it.users } }
    override suspend fun planCacheCleanup()=withContext(Dispatchers.IO) {mutex.withLock {
        prepare();planCacheCleanupLocked(journal.resourceFiles())
    }}
    override suspend fun planSelectedCacheCleanup(resources:PersistentList<ResourceKey>)=withContext(Dispatchers.IO) {mutex.withLock {
        require(resources.size in 1..100);prepare()
        val selection=journal.resourceCleanupSelection(resources)
        // An explicit empty set remains empty, and never falls back to all files.
        val rows=journal.resourceFiles().filter {it.id in selection.files && it.state==ResourceFileState.Published}.toPersistentList()
        ResourceSelectionCleanupPlan(planCacheCleanupLocked(rows),selection.resources,selection.unavailable,selection.absent)
    }}
    private suspend fun planCacheCleanupLocked(rows:PersistentList<ResourceLocalFile>):ResourceCleanupPlan {
        currentCoroutineContext().ensureActive();val now=cleanupClock()
        cleanupPlans.entries.removeAll {now<it.value.created || now-it.value.created>=30_000}
        check(cleanupPlans.size<16) {"清理预览过多，请稍后重试"}
        val candidates=rows.filter {it.kind==ResourceFileKind.Cache && !it.retained && it.state!=ResourceFileState.Retiring && it.id !in leases.values && it.id !in downloads}.toPersistentList()
        var bytes=0L
        for(row in candidates) {currentCoroutineContext().ensureActive();bytes=Math.addExact(bytes,cleanupAllocated(row.id))}
        val plan=ResourceCleanupPlan(UUID.randomUUID().toString(),candidates.size,bytes,rows.size-candidates.size)
        cleanupPlans[plan.id]=CleanupPreview(plan,now,candidates);return plan
    }
    override suspend fun commitCacheCleanup(plan:ResourceCleanupPlan)=withContext(Dispatchers.IO) {mutex.withLock {
        prepare();currentCoroutineContext().ensureActive()
        val preview=cleanupPlans.remove(plan.id);val now=cleanupClock()
        check(preview!=null && preview.plan==plan && now>=preview.created && now-preview.created<30_000) {"清理预览已失效，请重新检查"}
        var deleted=0;var released=0L;var skipped=plan.skippedCount;var failed=0
        for(record in preview.records) {
            currentCoroutineContext().ensureActive()
            if(record.id in preview.reused || record.id in leases.values || record.id in downloads) {skipped++;continue}
            try {
                // Once retirement commits, complete this one unlink sequence even if the caller leaves the screen.
                withContext(NonCancellable) {
                    val bytes=cleanupAllocated(record.id)
                    if(journal.beginResourceCacheCleanup(record)) {removeRecord(record.id);deleted++;released=Math.addExact(released,bytes)} else skipped++
                }
            } catch(error:CancellationException) {throw error} catch(_:Exception) {failed++;recovered=false}
        }
        ResourceCleanupResult(deleted,released,skipped,failed)
    }}
    private fun cleanupAllocated(id:String):Long {
        val paths=listOf(managed(files,id),managed(partials,id))+listOf(".range-part",".range-journal",".range-journal-new").map {File(partials,id+it)}
        return paths.fold(0L) {sum,file->
            val bytes=try {allocated(file)} catch(error:android.system.ErrnoException) {if(error.errno==OsConstants.ENOENT) 0 else throw error}
            Math.addExact(sum,bytes)
        }
    }
    override suspend fun storageSnapshot()=withContext(Dispatchers.IO) {mutex.withLock {prepare();storageSnapshotLocked()}}
    override suspend fun setStoragePolicy(policy:ResourceOriginalPolicy)=withContext(Dispatchers.IO) {mutex.withLock {
        prepare();setStoragePolicyLocked(policy)
    }}
    override suspend fun setCacheLimit(maximumBytes:Long)=withContext(Dispatchers.IO) {mutex.withLock {
        prepare();setStoragePolicyLocked(policy.copy(maximumCacheBytes=maximumBytes))
    }}
    override suspend fun setManagedLimit(maximumBytes:Long?)=withContext(Dispatchers.IO) {mutex.withLock {
        prepare();setStoragePolicyLocked(policy.copy(maximumManagedBytes=maximumBytes))
    }}
    private suspend fun setStoragePolicyLocked(policy:ResourceOriginalPolicy):ResourceStoragePolicyResult {
        prepare();currentCoroutineContext().ensureActive()
        // Persist before changing admission or evicting bytes. Cancellation may discard the result, not the committed preference.
        withContext(NonCancellable) {journal.setResourceStoragePolicy(policy);this@ManagedResourceFiles.policy=policy}
        var deferred=false
        try {trimCache(bestEffort=true)} catch(error:CancellationException) {throw error} catch(_:Exception) {deferred=true}
        val snapshot=storageSnapshotLocked();return ResourceStoragePolicyResult(snapshot,deferred || snapshot.cacheOverLimit || snapshot.managedOverageBytes>0)
    }
    private suspend fun storageSnapshotLocked():ResourceStorageSnapshot {
        val rows=journal.resourceFiles();var cache=0L;var retained=0L;var original=0L;var transfer=0L
        fun disk(file:File):Long=try {allocated(file)} catch(error:android.system.ErrnoException) {if(error.errno==OsConstants.ENOENT) 0 else throw error}
        for(row in rows) {
            currentCoroutineContext().ensureActive();val bytes=disk(managed(files,row.id))
            when {row.state==ResourceFileState.Publishing->transfer=Math.addExact(transfer,bytes)
                row.kind==ResourceFileKind.Original->original=Math.addExact(original,bytes)
                row.retained->retained=Math.addExact(retained,bytes)
                else->cache=Math.addExact(cache,bytes)}
        }
        for(directory in listOf(partials,documents,parts,backgrounds,backgroundPartials)) for(file in requireNotNull(directory.listFiles())) {currentCoroutineContext().ensureActive();transfer=Math.addExact(transfer,disk(file))}
        for(source in journal.backgroundDownloadSources()) transfer=Math.addExact(transfer,downloadInbox.allocated(source.mapping))
        fun charge(predicate:(ResourceLocalFile)->Boolean)=rows.filter(predicate).fold(0L) {sum,row->Math.addExact(sum,row.chargedBytes)}
        return ResourceStorageSnapshot(policy,cache,retained,original,transfer,
            charge {it.kind==ResourceFileKind.Cache && !it.retained},charge {it.kind==ResourceFileKind.Cache && it.retained && it.state!=ResourceFileState.Missing},charge {it.kind==ResourceFileKind.Original},
            temporaryUsage(),rows.count {it.kind==ResourceFileKind.Cache && !it.retained},managedUsage(rows))
    }
    override suspend fun resourceVariants(resource:ResourceKey)=withContext(Dispatchers.IO) {mutex.withLock {prepare();journal.resourceVariants(resource)}}
    override suspend fun planUnavailableRetentionRelease()=withContext(Dispatchers.IO) {mutex.withLock {
        prepare();currentCoroutineContext().ensureActive();journal.planUnavailableRetentionRelease()
    }}
    override suspend fun releaseUnavailableRetention(plan:ResourceUnavailableRetentionPlan)=withContext(Dispatchers.IO) {mutex.withLock {
        prepare();currentCoroutineContext().ensureActive();journal.releaseUnavailableRetention(plan)
    }}
    override suspend fun setResourceRetained(key:ResourceVariantKey,retained:Boolean)=withContext(Dispatchers.IO) {mutex.withLock {
        prepare()
        if(retained) {
            val variant=journal.resourceVariant(key) ?: error("资源版本尚未确认")
            verifyRetentionBytes(variant)
        }
        journal.setResourceRetained(key,retained,policy)
    }}
    override suspend fun setResourcesRetained(resources:PersistentList<ResourceKey>,retained:Boolean)=withContext(Dispatchers.IO) {
        require(resources.size in 1..100)
        val results=persistentListOf<ResourceRetentionBatchItem>().builder()
        for(key in resources.distinct()) {
            currentCoroutineContext().ensureActive()
            val outcome=mutex.withLock {
                // A closed owner aborts the batch; it must not become a list of
                // retryable item failures for a retired account.
                prepare()
                try {
                    val variant=journal.resourceVariant(ResourceVariantKey(key))
                    if(variant==null) ResourceRetentionBatchOutcome.Unavailable
                    else {
                        if(retained && !variant.retained) verifyRetentionBytes(variant)
                        // Recheck visibility and current retention in the write
                        // transaction, including releases; authorization may have
                        // changed while the physical bytes were being inspected.
                        journal.setVisibleResourceOriginalRetained(key,retained,policy)
                    }
                } catch(error:CancellationException) {throw error}
                catch(_:ResourceRetentionCapacityExceeded) {ResourceRetentionBatchOutcome.LimitReached}
                catch(_:Exception) {ResourceRetentionBatchOutcome.Failed}
            }
            results.add(ResourceRetentionBatchItem(key,outcome))
        }
        currentCoroutineContext().ensureActive();ResourceRetentionBatchResult(retained,results.build())
    }
    private suspend fun verifyRetentionBytes(variant:ResourceVariantSnapshot) {
        for(record in journal.resourceFiles().filter {it.state==ResourceFileState.Published && it.checksum==variant.descriptor.checksum && it.byteCount==variant.descriptor.byteCount}) {
            try {verify(record.id,record.byteCount,record.checksum)} catch(_:InvalidResourceBytes) {journal.markResourceFile(record.id,ResourceFileState.Invalid)}
        }
    }
    /** Cache clearing drops unretained idle resume checkpoints; originals, retention and live users remain intact. */
    suspend fun clearDownloadCache()=withContext(Dispatchers.IO) { mutex.withLock {
        prepare()
        for(record in journal.resourceFiles().filter { it.kind==ResourceFileKind.Cache && !it.retained && it.id !in leases.values && it.id !in downloads }) {
            journal.retireResourceCache(record.id);removeRecord(record.id)
        }
    } }
    suspend fun cleanup() = withContext(Dispatchers.IO) { mutex.withLock {
        prepare()
        for(file in journal.retireResourceFiles((leases.values+downloads.keys).toPersistentSet())) removeRecord(file.id)
        trimCache()
    } }
    suspend fun close() = withContext(NonCancellable+Dispatchers.IO) {
        val active=mutex.withLock { closing=true;downloads.values.map { it.task }.also { signalDrain() } }
        active.forEach { it.cancel() };active.forEach { it.join() }
        drained.await();downloadScope.cancel()
        mutex.withLock { cleanupPlans.clear();ownerLock?.release();ownerLock=null;lockFile?.close();lockFile=null }
    }
    private suspend fun prepare() {
        check(!closing) { "资源文件所有者已关闭" }
        if(ownerLock==null) {
            directory(root);directory(files);directory(partials);directory(parts);directory(documents);directory(backgrounds);directory(backgroundPartials);syncDirectory(root);syncDirectory(requireNotNull(root.parentFile))
            val fd=openManaged(File(root,"owner.lock"),OsConstants.O_RDWR or OsConstants.O_CREAT,384)
            val stream=FileOutputStream(fd)
            try { val lock=stream.channel.tryLock() ?: error("同一资源目录已有活动所有者");lockFile=stream;ownerLock=lock }
            catch(error: Throwable) { stream.close();throw error }
        }
        if(!policyLoaded) {policy=journal.resourceStoragePolicy(policy);policyLoaded=true}
        if(!recovered) { recover();recovered=true }
    }
    private suspend fun recover() {
        recoverBackgroundSources()
        for(source in journal.backgroundDownloadSources().filter {it.deleting}) {
            downloadInbox.discard(source.mapping);journal.deleteBackgroundDownloadSource(source.mapping,true)
        }
        for(document in requireNotNull(documents.listFiles())) { managed(documents,document.name);remove(document) };syncDirectory(documents)
        for(part in requireNotNull(parts.listFiles())) if(part.name !in partReservations) { managed(parts,part.name);remove(part) }
        syncDirectory(parts)
        for(record in journal.resourceFiles()) {
            val file=managed(files,record.id);val partial=managed(partials,record.id)
            when(record.state) {
                ResourceFileState.Publishing -> {
                    if(record.kind==ResourceFileKind.Cache) { recoverDownload(record);continue }
                    if(exists(file)) {
                        try {
                            verify(record.id,record.byteCount,record.checksum);Os.chmod(file.path,256);syncDirectory(files)
                            val pending=journal.resourceAssets().filter { it.plannedFile==record.id && it.availability==ResourceAssetAvailability.Importing }
                            check(pending.isNotEmpty())
                            for(asset in pending) journal.publishResourceImport(asset.id,record.id,allocated(file))
                        } catch(_: InvalidResourceBytes) { journal.markResourceFile(record.id,ResourceFileState.Invalid) }
                    } else { remove(partial);syncDirectory(partials);journal.markResourceFile(record.id,ResourceFileState.Missing) }
                }
                ResourceFileState.Published -> if(!exists(file)) journal.markResourceFile(record.id,ResourceFileState.Missing)
                ResourceFileState.Retiring -> if(record.id !in leases.values) { removeRecord(record.id) }
                ResourceFileState.Missing,ResourceFileState.Invalid -> Unit
            }
        }
        for(asset in journal.resourceAssets().filter { it.availability==ResourceAssetAvailability.Importing }) {
            val candidate=journal.resourceFiles().firstOrNull { it.id==asset.plannedFile && it.state==ResourceFileState.Published }
            if(candidate==null) journal.markResourceAssetUnavailable(asset.id)
            else try { verify(candidate.id,candidate.byteCount,candidate.checksum);journal.publishResourceImport(asset.id,candidate.id,allocated(managed(files,candidate.id))) }
                catch(_: InvalidResourceBytes) { journal.markResourceFile(candidate.id,ResourceFileState.Invalid) }
        }
    }
    /** Reserve both the bounded OS inbox and its future publication before enabling any system writer. */
    suspend fun prepareBackgroundDownloadSource(mapping:ResourceBackgroundDownloadMapping)=withContext(Dispatchers.IO) {mutex.withLock {
        prepare();journal.requireBackgroundDownloadSourceActive(mapping)
        require(mapping.authorization.expiresAt>System.currentTimeMillis()) {"后台下载授权已过期"}
        val existing=journal.backgroundDownloadSources().firstOrNull {it.mapping.id==mapping.id}
        if(existing!=null) require(existing.mapping==mapping && !existing.deleting)
        else {
            val block=Os.statvfs(root.path).f_frsize;require(block in 1..65536)
            fun rounded(value:Long)=Math.multiplyExact(Math.addExact(value,block-1)/block,block)
            val raw=Math.addExact(rounded(mapping.authorization.expectedBytes),Math.multiplyExact(rounded(8192),2))
            val addition=Math.addExact(raw,mapping.authorization.expectedBytes);val temporary=temporaryUsage()
            require(temporary<=policy.maximumTemporaryBytes && addition<=policy.maximumTemporaryBytes-temporary) {"后台下载临时额度不足"}
            trimCache(additionalManagedBytes=addition,enforceCache=false);requireFree(addition)
            journal.beginBackgroundDownloadSource(mapping,raw,policy)
        }
        // A crash before the permit write retains capacity, and the same mapping can retry preparation.
        downloadInbox.prepare(mapping)
    }}
    /** Cache publication only. Callers still need a freshly authorized message borrow before exposing bytes or completing the job. */
    suspend fun publishBackgroundDownload(mapping:ResourceBackgroundDownloadMapping,target:MediaDownloadTarget)=withContext(Dispatchers.IO) {mutex.withLock {
        prepare();target.requireValid()
        require(target.preview==null && target.plan.expectedBytes==mapping.authorization.expectedBytes && target.plan.checksum==mapping.authorization.checksum)
        val source=journal.backgroundDownloadSources().first {it.mapping==mapping && !it.deleting}
        val admission=source.admission(policy)
        downloadInbox.withReceived(mapping) {raw->
            verifyPath(raw,mapping.authorization.expectedBytes,mapping.authorization.checksum)
            target.requireValid()
            var cached:ResourceLocalFile?=null
            for(row in journal.resourceFiles().filter {it.state==ResourceFileState.Published && it.byteCount==mapping.authorization.expectedBytes && it.checksum==mapping.authorization.checksum}) {
                try {verify(row.id,row.byteCount,row.checksum);cached=row;break}
                catch(_:InvalidResourceBytes) {journal.markResourceFile(row.id,ResourceFileState.Invalid)}
            }
            val pending=journal.resourceFiles().firstOrNull {it.id==source.publication && it.state==ResourceFileState.Publishing}
            require(pending==null || pending.id !in downloads) {"原件发布仍在使用"}
            val selected=pending ?: cached
            val retained=journal.resourceBytesRetained(mapping.authorization.expectedBytes,mapping.authorization.checksum)
            if(selected==null) trimCache(if(retained) 0 else mapping.authorization.expectedBytes,if(retained) 0 else 1,
                additionalManagedBytes=if(source.publication==null) 0 else mapping.authorization.expectedBytes,admissionPolicy=admission,enforceCache=!retained)
            val record=journal.beginBackgroundDownloadPublication(mapping,selected?.id ?: UUID.randomUUID().toString().uppercase(),selected?.state==ResourceFileState.Published,downloadInbox.allocated(mapping),policy)
            if(record.state==ResourceFileState.Published) {verify(record.id,record.byteCount,record.checksum);return@withReceived}
            val staging=managed(partials,record.id);val published=managed(files,record.id)
            try {
                checkpoint(PublicationCheckpoint.Journaled);require(!exists(published));remove(staging)
                readRegular(raw).use {input->writeNew(staging).use {output->copyVerified(input,output,record.byteCount,record.checksum);output.fd.sync()}}
                target.requireValid();journal.requireBackgroundDownloadSourceActive(mapping)
                val completion=journal.resourceDownloadAdmission(record.id,admission)
                val growth=(maxOf(record.byteCount,allocated(staging))-record.chargedBytes).coerceAtLeast(0)
                trimCache(additionalBytes=if(record.retained) 0 else growth,excluding=setOf(record.id),admissionPolicy=completion,enforceCache=!record.retained,enforceEntries=false)
                journal.reserveResourceAllocation(record.id,allocated(staging),completion);checkpoint(PublicationCheckpoint.Copied)
                Os.rename(staging.path,published.path);Os.chmod(published.path,256);syncDirectory(files);syncDirectory(partials);checkpoint(PublicationCheckpoint.Renamed)
                journal.publishResourceDownload(record.id,allocated(published),completion);checkpoint(PublicationCheckpoint.Published)
            } catch(error:Throwable) {recovered=false;throw error}
        }
    }}
    /** Only an inactive mapping proves the OS operation drained. Revoke its permit before releasing capacity. */
    suspend fun releaseBackgroundDownloadSource(mapping:ResourceBackgroundDownloadMapping)=withContext(Dispatchers.IO) {mutex.withLock {
        prepare()
        val source=journal.backgroundDownloadSources().firstOrNull {it.mapping.id==mapping.id} ?: return@withLock
        require(source.mapping==mapping)
        journal.deleteBackgroundDownloadSource(mapping,false)
        try {downloadInbox.discard(mapping);journal.deleteBackgroundDownloadSource(mapping,true)} catch(error:Throwable) {recovered=false;throw error}
    }}
    /** Prepare once before starting the physical task. No URL, credential or path is journaled. */
    suspend fun prepareBackgroundUploadSource(mapping:ResourceBackgroundUploadMapping)=withContext(Dispatchers.IO) {
        val ready=mutex.withLock {
            prepare();journal.requireBackgroundSourceActive(mapping)
            journal.backgroundUploadSources().firstOrNull {it.mapping.id==mapping.id}?.let {record->
                require(record.mapping==mapping && record.state==BackgroundSourceState.Ready)
                verifyPath(managed(backgrounds,mapping.id),mapping.expectedBytes,requireNotNull(record.checksum));true
            } ?: false
        }
        if(!ready) withOriginal(upload=mapping.upload) {source->mutex.withLock {
            prepare();journal.requireBackgroundSourceActive(mapping)
            // Another preparer may have completed while this caller acquired the original lease.
            val existing=journal.backgroundUploadSources().firstOrNull {it.mapping.id==mapping.id}
            if(existing!=null) {
                require(existing.mapping==mapping && existing.state==BackgroundSourceState.Ready)
                verifyPath(managed(backgrounds,mapping.id),mapping.expectedBytes,requireNotNull(existing.checksum))
                return@withLock
            }
            val addition=Math.multiplyExact(mapping.expectedBytes,2);val temporary=temporaryUsage()
            require(temporary<=policy.maximumTemporaryBytes && addition<=policy.maximumTemporaryBytes-temporary) {"后台传输临时额度不足"}
            trimCache(additionalManagedBytes=addition,enforceCache=false);requireFree(addition)
            val partial=managed(backgroundPartials,mapping.id);val target=managed(backgrounds,mapping.id)
            try {
                journal.beginBackgroundUploadSource(mapping,policy);backgroundCheckpoint(BackgroundSourceCheckpoint.Reserved)
                readRegular(source).use {input->
                    val range=mapping.range ?: ResourceRange(0,mapping.expectedBytes-1)
                    require(range.upper<Os.fstat(input.fd).st_size && range.byteCount==mapping.expectedBytes)
                    input.channel.position(range.lower)
                    writeNew(partial).use {output->
                        val buffer=ByteArray(65536);var remaining=mapping.expectedBytes
                        while(remaining>0) {
                            currentCoroutineContext().ensureActive()
                            val count=input.read(buffer,0,minOf(remaining,buffer.size.toLong()).toInt());if(count<0) throw InvalidResourceBytes()
                            requireFree(count.toLong());output.write(buffer,0,count);remaining-=count
                        }
                        output.fd.sync()
                    }
                }
                val checksum=readRegular(partial).use {digest(it,mapping.expectedBytes)}
                (mapping.authorization.scope as? ResourceBackgroundUploadScope.Whole)?.let {require(it.checksum==checksum)}
                check(temporaryUsage()<=policy.maximumTemporaryBytes);trimCache(enforceCache=false)
                backgroundCheckpoint(BackgroundSourceCheckpoint.Copied);currentCoroutineContext().ensureActive()
                check(!exists(target));Os.rename(partial.path,target.path);Os.chmod(target.path,256)
                syncDirectory(backgrounds);syncDirectory(backgroundPartials);backgroundCheckpoint(BackgroundSourceCheckpoint.Renamed)
                journal.finishBackgroundUploadSource(mapping,checksum,allocated(target),policy)
                backgroundCheckpoint(BackgroundSourceCheckpoint.Ready)
            } catch(error:Throwable) {recovered=false;throw error}
        }}
    }
    /** Borrow until the actual network/file operation has drained, including cancellation callbacks. */
    suspend fun <T> withBackgroundUploadSource(mapping:ResourceBackgroundUploadMapping,block:suspend (File)->T):T=withContext(Dispatchers.IO) {
        var token:String?=null
        try {
            val file=mutex.withLock {
                prepare();journal.requireBackgroundSourceActive(mapping)
                val record=journal.backgroundUploadSources().first {it.mapping==mapping}
                require(record.state==BackgroundSourceState.Ready)
                val path=managed(backgrounds,mapping.id);verifyPath(path,mapping.expectedBytes,requireNotNull(record.checksum))
                token=UUID.randomUUID().toString();leases[token!!]="background:${mapping.id}";path
            }
            currentCoroutineContext().ensureActive();block(file)
        } finally {withContext(NonCancellable) {mutex.withLock {token?.let {leases.remove(it)};signalDrain()}}}
    }
    /** Retire only after journal completion proves the physical task drained. Active borrows also fence deletion. */
    suspend fun releaseBackgroundUploadSource(mapping:ResourceBackgroundUploadMapping)=withContext(Dispatchers.IO) {mutex.withLock {
        prepare();require("background:${mapping.id}" !in leases.values)
        val record=journal.backgroundUploadSources().firstOrNull {it.mapping.id==mapping.id} ?: return@withLock
        require(record.mapping==mapping)
        try {withSystemUploadSourceLock(applicationContext,mapping.task) {removeBackgroundSource(record)}} catch(error:Throwable) {recovered=false;throw error}
    }}
    private suspend fun removeBackgroundSource(record:BackgroundUploadSource,recoverPreparing:Boolean=false) {
        journal.deleteBackgroundUploadSource(record.mapping,false,recoverPreparing)
        backgroundCheckpoint(BackgroundSourceCheckpoint.Deleting)
        remove(managed(backgrounds,record.mapping.id));remove(managed(backgroundPartials,record.mapping.id))
        syncDirectory(backgrounds);syncDirectory(backgroundPartials);backgroundCheckpoint(BackgroundSourceCheckpoint.Unlinked)
        journal.deleteBackgroundUploadSource(record.mapping,true)
    }
    private suspend fun recoverBackgroundSources() {
        for(record in journal.backgroundUploadSources()) when(record.state) {
            BackgroundSourceState.Preparing->removeBackgroundSource(record,true)
            BackgroundSourceState.Deleting->{
                remove(managed(backgrounds,record.mapping.id));remove(managed(backgroundPartials,record.mapping.id))
                syncDirectory(backgrounds);syncDirectory(backgroundPartials);journal.deleteBackgroundUploadSource(record.mapping,true)
            }
            BackgroundSourceState.Ready->Unit // Driver must adopt or prove drain; ordinary recovery cannot decide ownership.
        }
        val known=journal.backgroundUploadSources().map {it.mapping.id}.toSet()
        for(directory in listOf(backgrounds,backgroundPartials)) {
            for(file in requireNotNull(directory.listFiles())) if(file.name !in known) {managed(directory,file.name);remove(file)}
            syncDirectory(directory)
        }
    }
    private suspend fun backgroundReserved():Long {
        val received=journal.backgroundDownloadSources().fold(0L) {sum,row->Math.addExact(sum,
            Math.addExact(maxOf(row.rawBudget,row.allocated,downloadInbox.allocated(row.mapping)),if(row.publication==null) row.mapping.authorization.expectedBytes else 0))}
        return journal.backgroundUploadSources().fold(received) {sum,row->
        val disk=Math.addExact(allocatedIfPresent(managed(backgrounds,row.mapping.id)),allocatedIfPresent(managed(backgroundPartials,row.mapping.id)))
        Math.addExact(sum,Math.addExact(maxOf(row.mapping.expectedBytes,row.allocatedBytes,disk),row.mapping.expectedBytes))
        }
    }
    private suspend fun temporaryUsage():Long {
        var used=journal.resourceFiles().filter {it.state==ResourceFileState.Publishing}.fold(backgroundReserved()) {sum,row->Math.addExact(sum,row.chargedBytes)}
        for((id,reserved) in documentReservations) used=Math.addExact(used,maxOf(reserved,allocatedIfPresent(managed(documents,id))))
        for((id,reserved) in partReservations) used=Math.addExact(used,maxOf(reserved,allocatedIfPresent(managed(parts,id))))
        return used
    }
    internal suspend fun acquireUploads(owner: String) = withContext(Dispatchers.IO) { mutex.withLock {
        prepare();check(uploadOwner==null) { "同一文件所有者已有上传引擎" };uploadOwner=owner
    } }
    internal suspend fun releaseUploads(owner: String) = withContext(NonCancellable+Dispatchers.IO) { mutex.withLock {
        require(uploadOwner==owner);uploadOwner=null;signalDrain()
    } }
    internal suspend fun transfer(owner: String,work: ResourceUploadWork,plan: ResourceTransferPlan,uploader: ResourcePlanUploader):Unit=
        withContext(scheduler?.let {NetworkWorkScope(it,NetworkWorkContext("mediaProvider",NetworkWorkPriority.Recovery,NetworkWorkKind.Upload))} ?: EmptyCoroutineContext) {
        beforeTransfer()
        mutex.withLock { check(uploadOwner==owner && !closing) }
        withOriginal(upload=work.id) { source ->
            if(plan.mode==ResourceTransferMode.Put) uploader.upload(source,plan,work.request.checksum)
            else {
                require(plan.mode==ResourceTransferMode.PartPut);val range=requireNotNull(plan.range);require(range.upper<work.request.byteCount)
                val id=UUID.randomUUID().toString().uppercase();val file=managed(parts,id)
                try {
                    withContext(Dispatchers.IO) { mutex.withLock {
                        check(uploadOwner==owner && !closing)
                        val publishing=temporaryUsage()
                        check(publishing<=policy.maximumTemporaryBytes && range.byteCount<=policy.maximumTemporaryBytes-publishing) { "临时分片空间不足" }
                        trimCache(additionalManagedBytes=range.byteCount,enforceCache=false);requireFree(range.byteCount);partReservations[id]=range.byteCount
                        readRegular(source).use { input -> input.channel.position(range.lower);writeNew(file).use { output ->
                            val buffer=ByteArray(65536);var remaining=range.byteCount
                            while(remaining>0) { currentCoroutineContext().ensureActive();val count=input.read(buffer,0,minOf(buffer.size.toLong(),remaining).toInt());if(count<0) throw InvalidResourceBytes();requireFree(count.toLong());output.write(buffer,0,count);remaining-=count }
                            output.fd.sync()
                        } }
                        val charge=maxOf(range.byteCount,allocated(file));check(charge<=policy.maximumTemporaryBytes-publishing);partReservations[id]=charge;trimCache(enforceCache=false)
                    } }
                    uploader.upload(file,plan)
                } finally { withContext(NonCancellable+Dispatchers.IO) { mutex.withLock { remove(file);syncDirectory(parts);partReservations.remove(id) } } }
            }
        }
    }
    private fun directory(file: File) {
        if(!file.exists()) check(file.mkdir())
        check(OsConstants.S_ISDIR(Os.lstat(file.path).st_mode)) { "资源目录类型无效" }
    }
    private fun managed(directory: File,id: String): File { require(UUID.fromString(id).toString().uppercase()==id);return File(directory,id) }
    private fun exists(file: File): Boolean = try { Os.lstat(file.path);true } catch(error: android.system.ErrnoException) { if(error.errno==OsConstants.ENOENT) false else throw error }
    private fun openManaged(file:File,flags:Int,mode:Int):FileDescriptor =
        Os.open(file.path,flags or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC,mode)
    private fun readRegular(file: File): FileInputStream {
        val fd=openManaged(file,OsConstants.O_RDONLY,0)
        try { check(OsConstants.S_ISREG(Os.fstat(fd).st_mode)) { "资源必须是普通文件" };return FileInputStream(fd) }
        catch(error: Throwable) { Os.close(fd);throw error }
    }
    private fun writeNew(file: File) = FileOutputStream(openManaged(file,OsConstants.O_WRONLY or OsConstants.O_CREAT or OsConstants.O_EXCL,384))
    private suspend fun digest(input: InputStream,bytes: Long): ResourceChecksum {
        val hash=MessageDigest.getInstance("SHA-256");val buffer=ByteArray(65536);var count=0L
        while(true) { currentCoroutineContext().ensureActive();val read=input.read(buffer);if(read<0) break;if(count>bytes-read) throw InvalidResourceBytes();count+=read;hash.update(buffer,0,read) }
        if(count!=bytes) throw InvalidResourceBytes();return ResourceChecksum(hash.digest().joinToString("") { "%02x".format(it) })
    }
    private suspend fun copyVerified(input: InputStream,output: FileOutputStream,bytes: Long,checksum: ResourceChecksum) {
        val hash=MessageDigest.getInstance("SHA-256");val buffer=ByteArray(65536);var count=0L
        while(true) {
            currentCoroutineContext().ensureActive();val read=input.read(buffer);if(read<0) break
            if(count>bytes-read) throw InvalidResourceBytes();requireFree(read.toLong());output.write(buffer,0,read);count+=read;hash.update(buffer,0,read)
        }
        if(count!=bytes || ResourceChecksum(hash.digest().joinToString("") { "%02x".format(it) })!=checksum) throw InvalidResourceBytes()
    }
    private suspend fun verify(id: String,bytes: Long,checksum: ResourceChecksum)=verifyPath(managed(files,id),bytes,checksum)
    private suspend fun verifyPath(file: File,bytes: Long,checksum: ResourceChecksum) {
        if(!exists(file)) throw InvalidResourceBytes()
        if(!OsConstants.S_ISREG(Os.lstat(file.path).st_mode)) throw InvalidResourceBytes()
        readRegular(file).use { if(Os.fstat(it.fd).st_size!=bytes || digest(it,bytes)!=checksum) throw InvalidResourceBytes() }
    }
    private fun allocated(file: File): Long = Os.lstat(file.path).let { check(OsConstants.S_ISREG(it.st_mode));Math.multiplyExact(it.st_blocks,512L) }
    private fun requireFree(addition: Long) { val available=StatFs(root.path).availableBytes;check(available>=policy.minimumFreeBytes && addition<=available-policy.minimumFreeBytes) { "设备剩余空间不足" } }
    private fun remove(file: File) {
        if(!exists(file)) return
        // Unlink a corrupt symlink itself; never traverse its target or an unexpected directory.
        val mode=Os.lstat(file.path).st_mode;check(OsConstants.S_ISREG(mode) || OsConstants.S_ISLNK(mode));Os.remove(file.path)
    }
    private fun syncDirectory(directory: File) { val fd=openManaged(directory,OsConstants.O_RDONLY,0);try { check(OsConstants.S_ISDIR(Os.fstat(fd).st_mode));Os.fsync(fd) } finally { Os.close(fd) } }
}
class InvalidResourceBytes: ResourceSourceUnavailable()

class ManagedResourceUploadBytes(private val files: ManagedResourceFiles,private val uploader: ResourcePlanUploader=ResourcePlanUploader()): ResourceUploadBytes {
    override suspend fun acquire(owner: String) = files.acquireUploads(owner)
    override suspend fun release(owner: String) = files.releaseUploads(owner)
    override suspend fun transfer(owner: String,work: ResourceUploadWork,plan: ResourceTransferPlan) = files.transfer(owner,work,plan,uploader)
}

package com.xmtx.im.platform

import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.os.StatFs
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collectLatest
import java.io.File
import java.io.FileNotFoundException
import java.security.MessageDigest
import java.util.UUID

/** A scoped, read-only provider. FileProvider handles canonical paths; live registrations fence old URI grants. */
class ResourcePresentationProvider: FileProvider() {
    override fun openFile(uri: Uri,mode: String): ParcelFileDescriptor=synchronized(PresentationRegistry) {
        if(mode!="r") throw SecurityException("Read only")
        PresentationRegistry.current(uri);requireNotNull(super.openFile(uri,mode))
    }
    override fun getType(uri: Uri): String=synchronized(PresentationRegistry) { PresentationRegistry.current(uri).read.evidence.descriptor.contentType }
    override fun query(uri: Uri,projection: Array<out String>?,selection: String?,selectionArgs: Array<out String>?,sortOrder: String?): Cursor=synchronized(PresentationRegistry) {
        val entry=PresentationRegistry.current(uri);val columns=(projection ?: arrayOf(OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE)).filter { it==OpenableColumns.DISPLAY_NAME || it==OpenableColumns.SIZE }
        MatrixCursor(columns.toTypedArray()).apply { addRow(columns.map { if(it==OpenableColumns.DISPLAY_NAME) entry.read.evidence.descriptor.displayName else entry.read.evidence.descriptor.byteCount }) }
    }
    override fun delete(uri: Uri,selection: String?,selectionArgs: Array<out String>?): Int=throw SecurityException("Read only")
}
private object PresentationRegistry {
    class Entry(val file: File,val read: AuthorizedOriginalRead)
    val reserved=mutableMapOf<File,Long>()
    val entries=mutableMapOf<Uri,Entry>()
    fun current(uri: Uri): Entry=entries[uri]?.takeIf { it.read.deadlineNanos-System.nanoTime()>0 } ?: throw FileNotFoundException("Temporary file unavailable")
}

/** Not UI state: the owner retains the mutable lifecycle; only URI/metadata strings cross to Compose. */
class TemporaryResourceLease internal constructor(val uri: Uri,val read: AuthorizedOriginalRead,private val task: Job) {
    suspend fun release()=withContext(NonCancellable) { task.cancelAndJoin() }
    suspend fun awaitReleased() { task.join() }
    val active get()=task.isActive && read.deadlineNanos-System.nanoTime()>0
}

/** Account owner. A launched share outlives its source row, but never account close or its read permit. */
class TemporaryResourceFiles(private val context: Context,parent: CoroutineScope,private val changes: Flow<Long>,
    private val current: suspend (MessageResourceRead)->Boolean) {
    private val owner=SupervisorJob(parent.coroutineContext[Job]);private val scope=CoroutineScope(parent.coroutineContext+owner)
    private val lock=Any();private var closed=false;private val preparations=mutableSetOf<Job>()
    suspend fun prepare(read: AuthorizedOriginalRead,source: File): TemporaryResourceLease=coroutineScope {
        val job=currentCoroutineContext().job
        synchronized(lock) { check(!closed && owner.isActive);preparations.add(job) }
        var file:File?=null;var uri:Uri?=null;var lease:TemporaryResourceLease?=null;var returned=false
        try {
            suspend fun validate() {
                currentCoroutineContext().ensureActive();check(read.deadlineNanos-System.nanoTime()>0)
                synchronized(lock) { check(!closed && owner.isActive) }
                if(!current(read.evidence)) throw MediaReadFailure(MediaReadFailureReason.SourceChanged)
            }
            validate()
            withContext(Dispatchers.IO) {
                val root=File(context.cacheDir,"resource-presentations-v1").apply { check(isDirectory || mkdirs()) }
                val descriptor=read.evidence.descriptor;require(descriptor.byteCount in 1..512L*1024*1024)
                val extension=android.webkit.MimeTypeMap.getSingleton().getExtensionFromMimeType(descriptor.contentType)?.takeIf { it.matches(Regex("[A-Za-z0-9]{1,16}")) } ?: "bin"
                val target=File(root,UUID.randomUUID().toString()+"."+extension)
                synchronized(PresentationRegistry) {
                    root.listFiles()?.filter { it !in PresentationRegistry.reserved }?.forEach { check(it.delete()) }
                    check(PresentationRegistry.reserved.size<4 && PresentationRegistry.reserved.values.sum()+descriptor.byteCount<=512L*1024*1024) { "临时文件空间不足，请关闭其他文件后重试" }
                    check(StatFs(root.path).availableBytes>=descriptor.byteCount+16L*1024*1024)
                    PresentationRegistry.reserved[target]=descriptor.byteCount;file=target
                }
                source.inputStream().use { input -> target.outputStream().use { output ->
                    val digest=MessageDigest.getInstance("SHA-256");val buffer=ByteArray(64*1024);var count=0L
                    while(true) {
                        validate();val n=input.read(buffer);if(n<0) break
                        count+=n;if(count>descriptor.byteCount) throw MediaReadFailure(MediaReadFailureReason.Integrity)
                        digest.update(buffer,0,n);output.write(buffer,0,n)
                    }
                    if(count!=descriptor.byteCount || digest.digest().joinToString("") { "%02x".format(it) }!=descriptor.checksum?.value) throw MediaReadFailure(MediaReadFailureReason.Integrity)
                } }
                validate()
                uri=FileProvider.getUriForFile(context,"${context.packageName}.presentations",target)
                synchronized(PresentationRegistry) { PresentationRegistry.entries[uri!!]=PresentationRegistry.Entry(target,read) }
            }
            validate()
            val destination=requireNotNull(uri);val target=requireNotNull(file)
            val task=scope.launch(start=CoroutineStart.UNDISPATCHED) {
                try {
                    val millis=((read.deadlineNanos-System.nanoTime()+999999)/1_000_000).coerceAtLeast(1)
                    withTimeout(millis) { changes.collectLatest { if(!current(read.evidence)) throw MediaReadFailure(MediaReadFailureReason.SourceChanged) } }
                } catch(_: CancellationException) { }
                catch(_: Exception) { }
                finally { remove(target,destination) }
            }
            lease=TemporaryResourceLease(destination,read,task)
            currentCoroutineContext().ensureActive();check(lease.active);returned=true;lease
        } finally {
            synchronized(lock) { preparations.remove(job) }
            if(!returned) { lease?.release();file?.let { remove(it,uri) } }
        }
    }
    private suspend fun remove(file: File,uri: Uri?)=withContext(NonCancellable+Dispatchers.IO) {
        synchronized(PresentationRegistry) {
            if(uri!=null) {
                PresentationRegistry.entries.remove(uri)
                runCatching { context.revokeUriPermission(uri,Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION) }
            }
            file.delete();PresentationRegistry.reserved.remove(file)
        }
    }
    suspend fun close()=withContext(NonCancellable) {
        val pending=synchronized(lock) { closed=true;preparations.toList() }
        pending.forEach { it.cancel() };pending.forEach { it.join() };owner.cancelAndJoin()
    }
    companion object {
        suspend fun cleanup(context: Context)=withContext(Dispatchers.IO) {
            synchronized(PresentationRegistry) {
                File(context.cacheDir,"resource-presentations-v1").listFiles()?.filter { it !in PresentationRegistry.reserved }?.forEach { check(it.delete()) }
            }
        }
    }
}

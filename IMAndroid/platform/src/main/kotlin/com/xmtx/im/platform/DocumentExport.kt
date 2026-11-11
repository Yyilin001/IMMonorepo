package com.xmtx.im.platform

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicReference

/** Only accepts the newly created destination returned by ACTION_CREATE_DOCUMENT. Never retains a grant. */
object DocumentExport {
    suspend fun copy(resolver: ContentResolver,destination: Uri,source: File,descriptor: ResourceDescriptor,
        deadlineNanos: Long,validate: suspend ()->Unit)=withTimeout(120_000) { withContext(Dispatchers.IO) { coroutineScope {
        require(destination.scheme==ContentResolver.SCHEME_CONTENT)
        require(descriptor.byteCount in 1..512L*1024*1024 && descriptor.checksum!=null)
        suspend fun checkAccess() {
            currentCoroutineContext().ensureActive()
            if(deadlineNanos-System.nanoTime()<=0) throw MediaReadFailure(MediaReadFailureReason.Expired)
            validate();currentCoroutineContext().ensureActive()
        }
        checkAccess()
        val signal=CancellationSignal();val active=AtomicReference<ParcelFileDescriptor?>()
        val closer=launch(start=CoroutineStart.UNDISPATCHED) {
            try { awaitCancellation() } finally { signal.cancel();runCatching { active.getAndSet(null)?.close() } }
        }
        try {
            val fd=resolver.openFileDescriptor(destination,"wt",signal) ?: throw IOException("无法写入所选文件")
            active.set(fd)
            fd.use {
                checkAccess()
                ParcelFileDescriptor.AutoCloseOutputStream(fd).use { output -> source.inputStream().use { input ->
                    var count=0L;val hash=MessageDigest.getInstance("SHA-256");val buffer=ByteArray(64*1024)
                    while(true) {
                        checkAccess();val n=input.read(buffer);if(n<0) break
                        count+=n;if(count>descriptor.byteCount) throw MediaReadFailure(MediaReadFailureReason.Integrity)
                        hash.update(buffer,0,n);output.write(buffer,0,n)
                    }
                    if(count!=descriptor.byteCount || hash.digest().joinToString("") { "%02x".format(it) }!=requireNotNull(descriptor.checksum).value) throw MediaReadFailure(MediaReadFailureReason.Integrity)
                    checkAccess();output.flush()
                } }
                active.compareAndSet(fd,null)
            }
            checkAccess()
        } finally { withContext(NonCancellable) { closer.cancelAndJoin() } }
    } } }

    /** Best effort: some providers cannot delete. Never delete an already successful user export. */
    suspend fun discard(context: Context,destination: Uri): Boolean=withContext(NonCancellable+Dispatchers.IO) {
        if(destination.scheme!=ContentResolver.SCHEME_CONTENT) return@withContext false
        try {
            if(DocumentsContract.isDocumentUri(context,destination)) DocumentsContract.deleteDocument(context.contentResolver,destination)
            else context.contentResolver.delete(destination,null,null)>0
        } catch(_: Exception) { false }
    }
}

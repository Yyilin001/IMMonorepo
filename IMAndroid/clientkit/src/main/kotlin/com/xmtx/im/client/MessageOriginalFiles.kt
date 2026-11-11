package com.xmtx.im.client

import kotlinx.coroutines.*
import java.io.File

/** Physical borrow only. The callback must not retain the path or an open descriptor after returning. */
interface ResourceDownloadFiles {
    suspend fun <T> withDownloaded(target: MediaDownloadTarget,cacheOnly: Boolean=false,block: suspend (File)->T): T?
}

/** Presentation metadata only; physical file ownership exists solely during the borrow callback. */
data class AuthorizedOriginalRead(val evidence: MessageResourceRead,val deadlineNanos: Long)

/** Each caller authorizes independently, including cache hits; byte sharing conveys no message authority. */
class MessageOriginalFiles(private val resolver: MediaTargetResolving,private val store: MessageResourceReadStore,private val files: ResourceDownloadFiles) {
    private val lock=Any();private var closed=false;private val jobs=mutableSetOf<Job>()
    private fun open() { synchronized(lock) { if(closed) throw MediaReadFailure(MediaReadFailureReason.SourceChanged) } }
    private suspend fun current(read: MessageResourceRead) {
        currentCoroutineContext().ensureActive();open()
        if(!store.isMessageResourceCurrent(read)) throw MediaReadFailure(MediaReadFailureReason.SourceChanged)
        open()
    }
    /** Decode/export inside the borrow. Presentation owners still remove results on access or lifecycle changes. */
    suspend fun <T> withOriginal(key: ResourceKey,cacheOnly: Boolean=false,message: MediaMessageLocation?=null,block: suspend (MessageResourceRead,File)->T): T? =
        withAuthorizedOriginal(key,cacheOnly,message) { read,file -> block(read.evidence,file) }
    suspend fun <T> withAuthorizedOriginal(key: ResourceKey,cacheOnly: Boolean=false,message: MediaMessageLocation?=null,block: suspend (AuthorizedOriginalRead,File)->T): T?=coroutineScope {
        val job=currentCoroutineContext().job;synchronized(lock) { open();jobs.add(job) }
        try {
            val read=if(message==null) store.selectMessageResource(key) else store.selectMessageResource(key,message);
            if(message!=null && (read.source.room!=message.room || read.source.message!=message.message)) throw MediaReadFailure(MediaReadFailureReason.SourceChanged)
            require(read.descriptor.key==key);current(read)
            val target=resolver.resolve(key.media,MediaMessageLocation(read.source.room,read.source.message),null)
            current(read);target.requireValid()
            if(target.preview!=null || target.plan.checksum!=read.descriptor.checksum || target.plan.expectedBytes!=read.descriptor.byteCount) throw MediaReadFailure(MediaReadFailureReason.Integrity)
            store.observeResourceVariant(read,target)
            val duration=((target.remainingNanos()+999999)/1000000).coerceAtLeast(1)
            val result=withTimeout(duration) {
                files.withDownloaded(target,cacheOnly) { file ->
                    current(read);target.requireValid()
                    val value=block(AuthorizedOriginalRead(read,target.deadlineNanos),file)
                    current(read);target.requireValid();value
                }
            }
            current(read);target.requireValid();result
        } finally { synchronized(lock) { jobs.remove(job) } }
    }
    suspend fun close()=withContext(NonCancellable) {
        val pending=synchronized(lock) { closed=true;jobs.toList() }
        pending.forEach { it.cancel() };pending.forEach { it.join() }
    }
}

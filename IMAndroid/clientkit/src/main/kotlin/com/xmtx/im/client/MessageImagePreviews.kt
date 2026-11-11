package com.xmtx.im.client

import com.google.protobuf.ByteString
import kotlinx.coroutines.*
import java.security.MessageDigest

/** Page presentation only: the owner must remove it on source, access-generation or lifecycle changes. */
data class MessagePreviewBytes(val read: MessageResourceRead,val variant: ResourceVariantDescriptor,val encoded: ByteString,val deadlineNanos: Long) {
    init { require(variant.key.resource==read.descriptor.key && variant.key.rendition is ResourceRendition.Derived && variant.byteCount==encoded.size().toLong() && variant.byteCount<=2L*1024*1024) }
    fun valid(nowNanos: Long=System.nanoTime())=deadlineNanos-nowNanos>0
    override fun toString()="MessagePreviewBytes(key=${variant.key}, bytes=<redacted>)"
}
/** Account-owned verified RAM cache. Every caller obtains fresh message authorization, including cache hits. */
class MessageImagePreviews(private val resolver: MediaTargetResolving,private val store: MessageResourceReadStore,
    private val fetch: suspend (MediaDownloadTarget)->ByteString=MediaPreviewDownloader()::download,
    private val maximumBytes: Long=16L*1024*1024,private val maximumEntries: Int=64) {
    private data class Family(val resource: ResourceKey,val variant: String)
    private val lock=Any();private var closed=false;private var bytes=0L
    private val entries=LinkedHashMap<ResourceVariantDescriptor,ByteString>(16,0.75f,true)
    private val versions=LinkedHashMap<Family,ResourceVariantDescriptor>(16,0.75f,true)
    private val jobs=mutableSetOf<Job>()
    init { require(maximumBytes in 1..64L*1024*1024 && maximumEntries in 1..256) }
    private fun open() { synchronized(lock) { if(closed) throw MediaReadFailure(MediaReadFailureReason.SourceChanged) } }
    private suspend fun current(read: MessageResourceRead) { currentCoroutineContext().ensureActive();open();if(!store.isMessageResourceCurrent(read)) throw MediaReadFailure(MediaReadFailureReason.SourceChanged);open() }
    suspend fun read(key: ResourceKey,size: MediaImagePreviewSize=MediaImagePreviewSize.Thumbnail,message: MediaMessageLocation?=null): MessagePreviewBytes=coroutineScope {
        val job=currentCoroutineContext().job;synchronized(lock) { open();jobs.add(job) }
        try {
            val read=if(message==null) store.selectMessageResource(key) else store.selectMessageResource(key,message);
            if(message!=null && (read.source.room!=message.room || read.source.message!=message.message)) throw MediaReadFailure(MediaReadFailureReason.SourceChanged)
            require(read.descriptor.key==key && read.descriptor.contentType.startsWith("image/"));current(read)
            val target=resolver.resolve(key.media,MediaMessageLocation(read.source.room,read.source.message),size)
            current(read);target.requireValid();store.observeResourceVariant(read,target)
            val variant=requireNotNull(target.preview);require(variant.key.resource==key)
            val cached=synchronized(lock) { open();acceptVersion(variant);entries[variant] }
            val data=cached ?: fetch(target).also { data ->
                current(read);target.requireValid()
                withContext(Dispatchers.Default) {
                    if(data.size().toLong()!=variant.byteCount || MessageDigest.getInstance("SHA-256").digest(data.toByteArray()).joinToString("") { "%02x".format(it) }!=variant.checksum.value) throw MediaReadFailure(MediaReadFailureReason.Integrity)
                }
                current(read);target.requireValid()
                synchronized(lock) {
                    open();acceptVersion(variant)
                    if(variant.byteCount<=maximumBytes && entries[variant]==null) {
                        entries[variant]=data;bytes+=data.size()
                        while(bytes>maximumBytes || entries.size>maximumEntries) { val iterator=entries.entries.iterator();bytes-=iterator.next().value.size();iterator.remove() }
                    }
                }
            }
            current(read);target.requireValid();synchronized(lock) { open();acceptVersion(variant) }
            MessagePreviewBytes(read,variant,data,target.deadlineNanos)
        } finally { synchronized(lock) { jobs.remove(job) } }
    }
    private fun acceptVersion(value: ResourceVariantDescriptor) {
        val rendition=value.key.rendition as ResourceRendition.Derived;val family=Family(value.key.resource,rendition.id)
        val prior=versions[family]
        if(prior!=null && ((prior.key.rendition as ResourceRendition.Derived).version>rendition.version || (prior.key.rendition as ResourceRendition.Derived).version==rendition.version && prior!=value)) throw MediaReadFailure(MediaReadFailureReason.Integrity)
        versions[family]=value
        val iterator=entries.entries.iterator()
        while(iterator.hasNext()) { val entry=iterator.next();val old=entry.key.key.rendition as ResourceRendition.Derived
            if(entry.key.key.resource==family.resource && old.id==family.variant && entry.key!=value) { bytes-=entry.value.size();iterator.remove() }
        }
        while(versions.size>512) { val oldest=versions.entries.iterator();oldest.next();oldest.remove() }
    }
    suspend fun close()=withContext(NonCancellable) {
        val pending=synchronized(lock) { closed=true;entries.clear();versions.clear();bytes=0;jobs.toList() }
        pending.forEach { it.cancel() };pending.forEach { it.join() }
    }
}

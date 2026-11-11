package com.xmtx.im.client

import com.google.protobuf.ByteString
import kotlinx.coroutines.*
import java.security.MessageDigest

/** Immutable pixels ready for a page. Consumers still enforce page/generation visibility and this frozen deadline. */
data class AvatarPresentationBytes(val content: AvatarContent,val encoded: ByteString,val deadlineNanos: Long) {
    init { require(encoded.size().toLong()==content.byteCount) }
    fun valid(nowNanos: Long=System.nanoTime())=deadlineNanos-nowNanos>0
    override fun toString()="AvatarPresentationBytes(content=$content, bytes=<redacted>)"
}

/** Account-activation-owned, bounded RAM cache. A hit never replaces a current display grant. */
class AvatarCache(private val actor: UserId,private val device: DeviceId,
    private val fetch: suspend (AvatarReadGrant)->AvatarDownloadedBytes=AvatarDownloader()::download,
    private val maximumBytes: Long=16L*1024*1024,private val maximumEntries: Int=64) {
    private data class Family(val home: ResourceHome,val media: String,val variant: String)
    private data class Key(val family: Family,val content: AvatarContent)
    private val lock=Any();private var closed=false
    private val entries=LinkedHashMap<Key,ByteString>(16,0.75f,true)
    private val versions=LinkedHashMap<Family,AvatarContent>(16,0.75f,true)
    private val jobs=mutableSetOf<Job>();private var bytes=0L
    init { require(maximumBytes in 1..64L*1024*1024 && maximumEntries in 1..256) }
    suspend fun read(grant: AvatarReadGrant): AvatarDownloadedBytes=coroutineScope {
        val job=currentCoroutineContext().job
        val content=grant.content;val family=Family(grant.home,content.media,content.variant);val key=Key(family,content)
        synchronized(lock) { check(!closed);require(grant.actor==actor && grant.device==device);jobs.add(job) }
        try {
            grant.requireValid()
            val cached=synchronized(lock) {
                check(!closed);acceptVersion(family,content);entries[key]
            }
            if(cached!=null) { grant.requireValid();return@coroutineScope borrowed(cached,grant) }
            val data=fetch(grant).read();currentCoroutineContext().ensureActive();grant.requireValid()
            withContext(Dispatchers.Default) {
                if(data.size().toLong()!=content.byteCount || MessageDigest.getInstance("SHA-256").digest(data.toByteArray()).joinToString("") { "%02x".format(it) }!=content.checksum.value) throw AvatarIntegrityFailure()
            }
            synchronized(lock) {
                check(!closed);acceptVersion(family,content)
                if(content.byteCount<=maximumBytes && entries[key]==null) {
                    entries[key]=data;bytes+=data.size()
                    while(bytes>maximumBytes || entries.size>maximumEntries) {
                        val iterator=entries.entries.iterator();bytes-=iterator.next().value.size();iterator.remove()
                    }
                }
            }
            grant.requireValid();borrowed(data,grant)
        } finally { synchronized(lock) { jobs.remove(job) } }
    }
    private fun borrowed(data: ByteString,grant: AvatarReadGrant)=AvatarDownloadedBytes(data,grant) {
        synchronized(lock) { if(closed) throw AvatarAccessFailure() }
    }
    private fun acceptVersion(family: Family,content: AvatarContent) {
        val previous=versions[family]
        if(previous!=null && (content.version<previous.version || content.version==previous.version && content!=previous)) throw AvatarAccessFailure()
        versions[family]=content
        val iterator=entries.entries.iterator()
        while(iterator.hasNext()) { val entry=iterator.next();if(entry.key.family==family && entry.key.content!=content) { bytes-=entry.value.size();iterator.remove() } }
        while(versions.size>512) { val oldest=versions.entries.iterator();oldest.next();oldest.remove() }
    }
    suspend fun close()=withContext(NonCancellable) {
        val pending=synchronized(lock) { closed=true;entries.clear();versions.clear();bytes=0;jobs.toList() }
        pending.forEach { it.cancel() };pending.forEach { it.join() }
    }
}

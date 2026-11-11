package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.serialization.SerializationException

/** Location is explicit; a resource ID alone must not silently borrow another message's authority. */
data class MediaMessageLocation(val room: RoomId,val message: MessageId) {
    init { uuidId(room.value);uuidId(message.value) }
}
enum class MediaImagePreviewSize(val pixels: Int) { Thumbnail(320),Large(1280) }
enum class MediaReadFailureReason { AuthorizationUnavailable,Denied,Unavailable,InvalidResponse,Expired,Integrity,SourceChanged }
class MediaReadFailure(val reason: MediaReadFailureReason,val status: Int?=null,val retryAfter: String?=null): Exception("Media read $reason")
/** Ephemeral GET capability; no serialization, URL logging or saved-state representation. */
class MediaDownloadTarget internal constructor(val plan: ResourceTransferPlan,val preview: ResourceVariantDescriptor?,val deadlineNanos: Long,private val nanoTime: ()->Long) {
    init {
        require(plan.mode==ResourceTransferMode.Get && plan.checksum!=null && plan.expectedBytes in 0..512L*1024*1024)
        preview?.let { require(it.key.rendition is ResourceRendition.Derived && it.checksum==plan.checksum && it.byteCount==plan.expectedBytes && it.byteCount<=2L*1024*1024) }
    }
    internal fun remainingNanos()=deadlineNanos-nanoTime()
    fun requireValid() { if(remainingNanos()<=0) throw MediaReadFailure(MediaReadFailureReason.Expired) }
    override fun toString()="MediaDownloadTarget(preview=$preview, target=<redacted>)"
}
fun interface MediaTargetResolving {
    suspend fun resolve(media: String,message: MediaMessageLocation?,size: MediaImagePreviewSize?): MediaDownloadTarget
}
class MediaDownloadTargetClient(private val api: AuthenticatedTransport,private val now: ()->Long=System::currentTimeMillis,private val nanoTime: ()->Long=System::nanoTime): MediaTargetResolving {
    override suspend fun resolve(media: String,message: MediaMessageLocation?,size: MediaImagePreviewSize?): MediaDownloadTarget=withTimeout(15000) {
        require(uuidId(media)==media && (size==null || message!=null))
        val query=buildMap { message?.let { put("room_id",it.room.value);put("message_id",it.message.value) };size?.let { put("image_size",it.pixels.toString()) } }
        val wall=now();val monotonic=nanoTime()
        val response=try { api.mediaTarget("/v2/media/$media",query,512*1024) }
        catch(_: ClientFailure.Protocol) { throw MediaReadFailure(MediaReadFailureReason.InvalidResponse) }
        catch(_: SerializationException) { throw MediaReadFailure(MediaReadFailureReason.InvalidResponse) }
        currentCoroutineContext().ensureActive()
        if(response.status!=200) throw MediaReadFailure(when(response.status) {
            401->MediaReadFailureReason.AuthorizationUnavailable
            403,404->MediaReadFailureReason.Denied
            429,in 500..599->MediaReadFailureReason.Unavailable
            else->MediaReadFailureReason.InvalidResponse
        },response.status,response.retryAfter)
        try {
            val plan=ResourceTransferPlan.decode(response.body.resourceObject("plan"))
            val preview=response.body.resourceOptionalObject("preview")?.let(ResourceVariantDescriptor::decode)
            if(size==null) require(preview==null) else require(preview!=null && preview.key.resource==ResourceKey(ResourceHome.Room(requireNotNull(message).room),media))
            val remaining=Math.subtractExact(plan.expiresAt,wall).coerceAtMost(900000)
            if(remaining<=0) throw MediaReadFailure(MediaReadFailureReason.Expired)
            MediaDownloadTarget(plan,preview,monotonic+remaining*1_000_000,nanoTime).also { it.requireValid() }
        } catch(error: MediaReadFailure) { throw error }
        catch(error: CancellationException) { throw error }
        catch(_: Exception) { throw MediaReadFailure(MediaReadFailureReason.InvalidResponse) }
    }
}
/** Read evidence includes a local access generation so a revoke/regrant cannot revive an old in-flight result. */
data class MessageResourceRead(val descriptor: ResourceDescriptor,val source: MessageResourceSource,val generation: String) {
    init { require(descriptor.state==ResourceState.Ready && descriptor.key.home==ResourceHome.Room(source.room) && generation.matches(Regex("[0-9A-F]{32}"))) }
    override fun toString()="MessageResourceRead(key=${descriptor.key}, source=$source, generation=<redacted>)"
}
interface MessageResourceReadStore {
    suspend fun observeResourceVariant(read:MessageResourceRead,target:MediaDownloadTarget) {}
    suspend fun resourceReadGeneration(): String
    suspend fun selectMessageResource(key: ResourceKey): MessageResourceRead
    suspend fun selectMessageResource(key: ResourceKey,location: MediaMessageLocation): MessageResourceRead = selectMessageResource(key).also {
        if(it.source.room!=location.room || it.source.message!=location.message) throw MediaReadFailure(MediaReadFailureReason.SourceChanged)
    }
    suspend fun isMessageResourceCurrent(read: MessageResourceRead): Boolean
}

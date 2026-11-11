package com.xmtx.im.client

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.*
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder

/** A source context requests fresh server authorization; it contains no download capability. */
sealed interface ResourceImportSource {
    val media: String
    data class Message(val room: RoomId,val message: MessageId,override val media: String,val variant: String?=null): ResourceImportSource {
        init { uuidId(room.value);uuidId(message.value);require(uuidId(media)==media);variant?.let { require(uuidId(it)==it) } }
    }
    data class Avatar(val key: ProfileKey,override val media: String,val variant: String): ResourceImportSource {
        init { require(uuidId(media)==media && uuidId(variant)==variant) }
    }
    fun payload()=buildJsonObject { when(val source=this@ResourceImportSource) {
        is Message -> put("message",buildJsonObject {
            put("location",buildJsonObject { put("roomID",wireId(source.room.value));put("messageID",wireId(source.message.value)) })
            put("mediaID",wireId(source.media));source.variant?.let { put("variantID",wireId(it)) }
        })
        is Avatar -> put("avatar",buildJsonObject { put("key",source.key.payload());put("mediaID",wireId(source.media));put("variantID",wireId(source.variant)) })
    } }
    companion object { fun decode(value: JsonObject): ResourceImportSource {
        require(value.size==1);val kind=value.keys.single();val fields=value.resourceObject(kind)
        return when(kind) {
            "message" -> { val location=fields.resourceObject("location");Message(RoomId(location.resourceId("roomID")),MessageId(location.resourceId("messageID")),fields.resourceId("mediaID"),fields.resourceOptionalObject("variantID")?.let { uuidId(it.resourceString("rawValue")) }) }
            "avatar" -> Avatar(ProfilePresentationClient.decodeKey(fields.resourceObject("key")),fields.resourceId("mediaID"),fields.resourceId("variantID"))
            else -> throw ClientFailure.Protocol()
        }
    } }
}
@Serializable(with=ResourceImportRequestSerializer::class)
data class ResourceImportRequest(val operation: String,val source: ResourceImportSource,val targetUsage: ResourceUsage,val targetMedia: String) {
    init { require(uuidId(operation)==operation && uuidId(targetMedia)==targetMedia && source.media!=targetMedia) }
    fun locator(actor: UserId)=ResourceImportLocator(targetUsage.home(actor),operation)
    fun payload()=buildJsonObject { put("operationID",wireId(operation));put("source",source.payload());put("targetUsage",targetUsage.payload());put("targetMediaID",wireId(targetMedia)) }
    companion object { fun decode(value: JsonObject)=ResourceImportRequest(value.resourceId("operationID"),ResourceImportSource.decode(value.resourceObject("source")),ResourceUsage.decode(value.resourceObject("targetUsage")),value.resourceId("targetMediaID")) }
}
data class ResourceImportLocator(val home: ResourceHome,val operation: String) {
    init { require(uuidId(operation)==operation) }
    fun payload()=buildJsonObject { put("home",home.payload());put("operationID",wireId(operation)) }
    companion object { fun decode(value: JsonObject)=ResourceImportLocator(ResourceHome.decode(value.resourceObject("home")),value.resourceId("operationID")) }
}
enum class ResourceImportState(val wire: String) { Pending("pending"),Copying("copying"),Processing("processing"),Ready("ready"),Cancelled("cancelled"),Failed("failed");
    val terminal get()=this in setOf(Ready,Cancelled,Failed)
}
/** Logical progress only; Ready is not a byte-read grant or evidence of business attachment. */
data class ResourceImportStatus(val locator: ResourceImportLocator,val media: String,val state: ResourceImportState,val bindableUntil: Long?=null) {
    init { require(uuidId(media)==media && (state==ResourceImportState.Ready)==(bindableUntil!=null)) }
    fun bindable(now: Long)=state==ResourceImportState.Ready && requireNotNull(bindableUntil)>now
    fun boundTo(request: ResourceImportRequest,actor: UserId) { require(locator==request.locator(actor) && media==request.targetMedia) }
    fun payload()=buildJsonObject { put("locator",locator.payload());put("mediaID",wireId(media));put("state",state.wire);bindableUntil?.let { put("bindableUntilUnixMilliseconds",it) } }
    companion object { fun decode(value: JsonObject)=ResourceImportStatus(ResourceImportLocator.decode(value.resourceObject("locator")),value.resourceId("mediaID"),
        ResourceImportState.entries.firstOrNull { it.wire==value.resourceString("state") } ?: throw ClientFailure.Protocol(),value.resourceOptionalNumber("bindableUntilUnixMilliseconds")) }
}
interface ResourceImportControl {
    suspend fun create(request: ResourceImportRequest): ResourceImportStatus
    suspend fun status(locator: ResourceImportLocator): ResourceImportStatus
    suspend fun cancel(locator: ResourceImportLocator): ResourceImportStatus
}
class ResourceImportClient(private val api: AuthenticatedTransport,private val actor: UserId): ResourceImportControl {
    init { uuidId(actor.value) }
    override suspend fun create(request: ResourceImportRequest)=send("/v2/resource-imports",request.payload()).also { it.boundTo(request,actor) }
    override suspend fun status(locator: ResourceImportLocator)=located("status",locator)
    override suspend fun cancel(locator: ResourceImportLocator)=located("cancel",locator)
    private suspend fun located(action: String,locator: ResourceImportLocator): ResourceImportStatus {
        if(locator.home is ResourceHome.Account) require(locator.home.user==actor)
        return send("/v2/resource-imports/$action",locator.payload()).also { require(it.locator==locator) }
    }
    private suspend fun send(path: String,payload: JsonObject)=withTimeout(30000) {
        val response=api.requestWithoutReplay(path,payload,64*1024);currentCoroutineContext().ensureActive()
        if(response.status!=200) throw response.failure()
        ResourceImportStatus.decode(response.body)
    }
}

/** Durable encoding uses the same frozen Swift-compatible wire request. */
object ResourceImportRequestSerializer: KSerializer<ResourceImportRequest> {
    override val descriptor=buildClassSerialDescriptor("ResourceImportRequest")
    override fun serialize(encoder: Encoder,value: ResourceImportRequest)=(encoder as JsonEncoder).encodeJsonElement(value.payload())
    override fun deserialize(decoder: Decoder)=ResourceImportRequest.decode((decoder as JsonDecoder).decodeJsonElement().jsonObject)
}

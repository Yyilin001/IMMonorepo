package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.serialization.json.*
import java.text.Normalizer

sealed interface ResourceHome {
    data class Account(val user: UserId): ResourceHome { init { uuidId(user.value) } }
    data class Room(val room: RoomId): ResourceHome { init { uuidId(room.value) } }
    fun payload() = buildJsonObject { when(this@ResourceHome) {
        is Account -> put("account",buildJsonObject { put("_0",wireId(user.value)) })
        is Room -> put("room",buildJsonObject { put("_0",wireId(room.value)) })
    } }
    companion object { fun decode(value: JsonObject): ResourceHome {
        require(value.size == 1);return when(val key = value.keys.single()) {
            "account" -> Account(UserId(value.resourceObject(key).resourceId("_0")))
            "room" -> Room(RoomId(value.resourceObject(key).resourceId("_0")))
            else -> throw ClientFailure.Protocol()
        }
    } }
}
sealed interface ResourceUsage {
    data class Attachment(val room: RoomId): ResourceUsage { init { uuidId(room.value) } }
    data object UserAvatar: ResourceUsage
    data class GroupAvatar(val room: RoomId): ResourceUsage { init { uuidId(room.value) } }
    val wireName get() = when(this) { is Attachment -> "messageAttachment";UserAvatar -> "userAvatar";is GroupAvatar -> "groupAvatar" }
    fun home(actor: UserId): ResourceHome = when(this) { is Attachment -> ResourceHome.Room(room);UserAvatar -> ResourceHome.Account(actor);is GroupAvatar -> ResourceHome.Room(room) }
    fun payload() = buildJsonObject { put(wireName,buildJsonObject { when(this@ResourceUsage) {
        is Attachment -> put("_0",wireId(room.value));UserAvatar -> Unit;is GroupAvatar -> put("_0",wireId(room.value))
    } }) }
    companion object { fun decode(value: JsonObject): ResourceUsage {
        require(value.size == 1);return when(val key=value.keys.single()) {
            "messageAttachment" -> Attachment(RoomId(value.resourceObject(key).resourceId("_0")))
            "groupAvatar" -> GroupAvatar(RoomId(value.resourceObject(key).resourceId("_0")))
            "userAvatar" -> { require(value.resourceObject(key).isEmpty());UserAvatar }
            else -> throw ClientFailure.Protocol()
        }
    } }
}
data class ResourceChecksum(val value: String) {
    init { require(value.matches(Regex("[0-9a-f]{64}"))) }
    fun payload() = buildJsonObject { put("algorithm","sha256");put("value",value) }
    companion object { fun decode(value: JsonObject): ResourceChecksum { require(value.resourceString("algorithm") == "sha256");return ResourceChecksum(value.resourceString("value")) } }
}
data class ResourceRange(val lower: Long,val upper: Long) {
    init { require(lower >= 0 && upper >= lower && upper-lower < Long.MAX_VALUE) }
    val byteCount get() = upper-lower+1
    fun payload() = buildJsonObject { put("lowerBound",lower);put("upperBound",upper) }
}
enum class ResourceTransferMode(val wire: String,val method: String,val upload: Boolean) {
    Put("http_put","PUT",true),FormPost("http_form_post","POST",true),PartPut("http_part_put","PUT",true),Get("http_get","GET",false),RangeGet("http_range_get","GET",false);
    companion object { fun decode(raw: String) = entries.firstOrNull { it.wire == raw } ?: throw ClientFailure.Protocol() }
}
data class ResourceDimensions(val width: Int,val height: Int) {
    init { require(width in 1..16384 && height in 1..16384 && width <= 40_000_000/height) }
    fun payload() = buildJsonObject { put("width",width);put("height",height) }
}
data class ResourceUploadRequest(val operation: String,val media: String,val usage: ResourceUsage,val contentType: String,val byteCount: Long,
    val checksum: ResourceChecksum,val modes: PersistentList<ResourceTransferMode> = persistentListOf(ResourceTransferMode.Put),val displayName: String = "附件",val dimensions: ResourceDimensions? = null) {
    init {
        require(uuidId(operation) == operation && uuidId(media) == media);requireResourceContentType(contentType);require(byteCount > 0)
        require(modes.isNotEmpty() && modes.size <= ResourceTransferMode.entries.size && modes.distinct().size == modes.size && modes.all { it.upload })
        require(dimensions == null || contentType.startsWith("image/"));require(resourceDisplayName(displayName) == displayName)
    }
    fun payload() = buildJsonObject {
        put("operationID",wireId(operation));put("mediaID",wireId(media));put("usage",usage.payload());put("contentType",contentType);put("byteCount",byteCount)
        put("checksum",checksum.payload());put("clientModes",JsonArray(modes.sortedBy { it.wire }.map { JsonPrimitive(it.wire) }));put("displayName",displayName)
        dimensions?.let { put("clientImageDimensions",it.payload()) }
    }
    // Swift canonicalizes client modes. Input order cannot change a frozen upload's identity.
    override fun equals(other: Any?) = other is ResourceUploadRequest && payload()==other.payload()
    override fun hashCode() = payload().hashCode()
    companion object { fun decode(value: JsonObject) = ResourceUploadRequest(value.resourceId("operationID"),value.resourceId("mediaID"),ResourceUsage.decode(value.resourceObject("usage")),
        value.resourceString("contentType"),value.resourceNumber("byteCount"),ResourceChecksum.decode(value.resourceObject("checksum")),value.resourceArray("clientModes").map { ResourceTransferMode.decode(it.resourceText()) }.toPersistentList(),
        value.resourceString("displayName"),value.resourceOptionalObject("clientImageDimensions")?.let { ResourceDimensions(Math.toIntExact(it.resourceNumber("width")),Math.toIntExact(it.resourceNumber("height"))) }) }
}
data class ResourceUploadLocator(val home: ResourceHome,val session: String) {
    init { require(uuidId(session) == session) }
    fun payload() = buildJsonObject { put("home",home.payload());put("sessionID",wireId(session)) }
    companion object { fun decode(value: JsonObject) = ResourceUploadLocator(ResourceHome.decode(value.resourceObject("home")),value.resourceId("sessionID")) }
}
data class ResourceUploadPart(val number: Int,val byteCount: Long,val checksum: ResourceChecksum? = null,val receipt: String? = null) {
    init { require(number in 1..10000 && byteCount > 0);receipt?.let { require(it.isNotEmpty() && it.toByteArray().size <= 4096 && it.codePoints().allMatch { n -> n >= 32 && n != 127 }) } }
    override fun toString() = "ResourceUploadPart(number=$number, byteCount=$byteCount, receipt=<redacted>)"
    fun payload() = buildJsonObject { put("number",number);put("byteCount",byteCount);checksum?.let { put("checksum",it.payload()) };receipt?.let { put("receipt",it) } }
    companion object { fun decode(value: JsonObject) = ResourceUploadPart(Math.toIntExact(value.resourceNumber("number")),value.resourceNumber("byteCount"),value.resourceOptionalObject("checksum")?.let(ResourceChecksum::decode),value.resourceOptionalString("receipt")) }
}
enum class ResourceSessionState(val wire: String) { Created("created"),Uploading("uploading"),Finalizing("finalizing"),Completed("completed"),Cancelled("cancelled"),Expired("expired"),Failed("failed") }
enum class ResourceState(val wire: String) { Pending("pending"),Verifying("verifying"),Scanning("scanning"),Processing("processing"),Ready("ready"),Rejected("rejected"),DeletionPending("deletion_pending"),Deleted("deleted") }
data class ResourceUploadSession(val locator: ResourceUploadLocator,val media: String,val generation: Long,val state: ResourceSessionState,
    val resourceState: ResourceState,val expiresAt: Long,val bindableUntil: Long?,val parts: PersistentList<ResourceUploadPart>,val retryNotBefore: Long?) {
    init {
        require(uuidId(media) == media && generation > 0 && parts.size <= 10000 && parts.map { it.number }.distinct().size == parts.size)
        require(resourceState != ResourceState.Ready || state == ResourceSessionState.Completed && bindableUntil != null)
        if(state in setOf(ResourceSessionState.Cancelled,ResourceSessionState.Expired,ResourceSessionState.Failed)) require(resourceState != ResourceState.Ready && bindableUntil == null)
    }
    fun bindable(now: Long) = state == ResourceSessionState.Completed && resourceState == ResourceState.Ready && bindableUntil?.let { it > now } == true
    fun payload() = buildJsonObject {
        put("locator",locator.payload());put("mediaID",wireId(media));put("generation",generation);put("state",state.wire);put("resourceState",resourceState.wire);put("expiresAtUnixMilliseconds",expiresAt)
        bindableUntil?.let { put("bindableUntilUnixMilliseconds",it) };put("confirmedParts",JsonArray(parts.sortedBy { it.number }.map { it.payload() }));retryNotBefore?.let { put("retryNotBeforeUnixMilliseconds",it) }
    }
    override fun equals(other: Any?) = other is ResourceUploadSession && payload()==other.payload()
    override fun hashCode() = payload().hashCode()
    companion object { fun decode(value: JsonObject) = ResourceUploadSession(ResourceUploadLocator.decode(value.resourceObject("locator")),value.resourceId("mediaID"),value.resourceNumber("generation"),
        ResourceSessionState.entries.firstOrNull { it.wire == value.resourceString("state") } ?: throw ClientFailure.Protocol(),ResourceState.entries.firstOrNull { it.wire == value.resourceString("resourceState") } ?: throw ClientFailure.Protocol(),
        value.resourceNumber("expiresAtUnixMilliseconds"),value.resourceOptionalNumber("bindableUntilUnixMilliseconds"),value.resourceArray("confirmedParts").also { require(it.size <= 10000) }.map { ResourceUploadPart.decode(it.jsonObject) }.sortedBy { it.number }.toPersistentList(),value.resourceOptionalNumber("retryNotBeforeUnixMilliseconds")) }
}
data class ResourceCapabilities(val modes: PersistentList<ResourceTransferMode>,val maximumBytes: Long,val maximumImageBytes: Long?,val usages: PersistentSet<String>,val maximumParts: Int,val background: Boolean) {
    init {
        require(modes.isNotEmpty() && modes.all { it.upload } && modes.distinct().size == modes.size && maximumBytes > 0)
        require(maximumImageBytes == null || maximumImageBytes in 1..maximumBytes);require(usages.isNotEmpty() && usages.all { it in setOf("messageAttachment","userAvatar","groupAvatar") })
        require(maximumParts in 0..10000 && (maximumParts == 0 || ResourceTransferMode.PartPut in modes))
    }
    fun allows(request: ResourceUploadRequest) = request.usage.wireName in usages && request.modes.any { it in modes } && request.byteCount <= maximumBytes &&
        (!request.contentType.startsWith("image/") || maximumImageBytes == null || request.byteCount <= maximumImageBytes)
    companion object { fun decode(value: JsonObject): ResourceCapabilities {
        require(value.resourceNumber("version") == 2L);val usages = value.resourceArray("allowedUsages").map { it.resourceText() };require(usages.distinct().size == usages.size)
        return ResourceCapabilities(value.resourceArray("uploadModes").map { ResourceTransferMode.decode(it.resourceText()) }.toPersistentList(),value.resourceNumber("maximumBytes"),value.resourceOptionalNumber("maximumImageBytes"),usages.toPersistentSet(),Math.toIntExact(value.resourceNumber("maximumParts")),value["backgroundTransfer"]?.jsonPrimitive?.takeUnless { it.isString }?.booleanOrNull ?: throw ClientFailure.Protocol())
    } }
}
fun resourceDisplayName(raw: String): String {
    val component = raw.replace('\\','/').split('/').lastOrNull { it.isNotEmpty() }.orEmpty()
    val normalized = Normalizer.normalize(component,Normalizer.Form.NFC)
    val value = buildString { normalized.codePoints().forEach { if(!Character.isISOControl(it) && Character.getType(it) != Character.FORMAT.toInt()) appendCodePoint(it) } }.trim { it.isWhitespace() }
    require(value.isNotEmpty() && value !in setOf(".","..") && value.toByteArray().size <= 255);return value
}
fun requireResourceContentType(value: String) { require(value.length <= 127 && value.matches(Regex("[a-z0-9!#\u0024&.\\^_+\\-]+/[a-z0-9!#\u0024&.\\^_+\\-]+"))) }
internal fun JsonElement.resourceText() = (this as? JsonPrimitive)?.takeIf { it.isString }?.content ?: throw ClientFailure.Protocol()
internal fun JsonObject.resourceString(key: String) = get(key)?.resourceText() ?: throw ClientFailure.Protocol()
internal fun JsonObject.resourceNumber(key: String) = (get(key) as? JsonPrimitive)?.takeUnless { it.isString }?.longOrNull ?: throw ClientFailure.Protocol()
internal fun JsonObject.resourceObject(key: String) = get(key) as? JsonObject ?: throw ClientFailure.Protocol()
internal fun JsonObject.resourceArray(key: String) = get(key) as? JsonArray ?: throw ClientFailure.Protocol()
internal fun JsonObject.resourceId(key: String) = uuidId(resourceObject(key).resourceString("rawValue"))
internal fun JsonObject.resourceOptionalObject(key: String) = when(val v = get(key)) { null,JsonNull -> null;is JsonObject -> v;else -> throw ClientFailure.Protocol() }
internal fun JsonObject.resourceOptionalNumber(key: String) = when(get(key)) { null,JsonNull -> null;else -> resourceNumber(key) }
internal fun JsonObject.resourceOptionalString(key: String) = when(get(key)) { null,JsonNull -> null;else -> resourceString(key) }

package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.serialization.json.*

/** Disposable connection controls, never room authorization or a durable delivery cursor. */
data class AuthorPresentationStart(val stream: String,val view: String,val messageRooms: PersistentList<RoomId>) {
    init { authorIdentity(stream,view);require(messageRooms.size<=8 && messageRooms.distinct().size==messageRooms.size);messageRooms.forEach {uuidId(it.value)} }
}
data class AuthorPresentationInterests(val stream: String,val view: String,val sequence: Long,val keys: PersistentList<ProfileKey>) {
    init { authorIdentity(stream,view);require(sequence>0 && keys.size<=128 && keys.distinct().size==keys.size) }
}
data class AuthorPresentationReceipt(val stream: String,val view: String,val sequence: Long,val keys: PersistentList<ProfileKey>,
    val minimumRemainingMillis: Long) {
    init { authorIdentity(stream,view);require(sequence>0 && keys.size in 1..16 && keys.distinct().size==keys.size && minimumRemainingMillis in 0..300_000) }
}
private fun authorIdentity(stream: String,view: String) { require(uuidId(stream)==stream && uuidId(view)==view) }

sealed interface AuthorPresentationEntry {
    val key: ProfileKey
    data class Available(val profile: AuthorizedProfile,val avatar: AvatarAccess?=null): AuthorPresentationEntry {
        override val key get()=profile.lease.key
        init {require(avatar==null || profile.view.state==ProfileState.Active && profile.view.avatarMediaId==avatar.content.media)}
    }
    data class Unavailable(val denial: ProfileReadResult.Unavailable): AuthorPresentationEntry {override val key get()=denial.key}
    data class Retryable(override val key: ProfileKey): AuthorPresentationEntry
}

/** Validated Swift JSON value. No JSON object, byte array, serializer or persistence API escapes. */
@ConsistentCopyVisibility
data class AuthorPresentationDelta internal constructor(val stream: String,val view: String,val sequence: Long,
    val actor: UserId,val device: DeviceId,val serverViewAgeMillis: Long,val serverNowMillis: Long,
    val entries: PersistentList<AuthorPresentationEntry>,val retryAfterMillis: Long?) {
    init {
        authorIdentity(stream,view);uuidId(actor.value);uuidId(device.value)
        require(sequence>0 && serverViewAgeMillis in 0 until MaximumViewAgeMillis && entries.size in 1..MaximumEntries)
        require(entries.map {it.key}.distinct().size==entries.size)
        require(entries.any {it is AuthorPresentationEntry.Retryable}==(retryAfterMillis!=null))
        require(retryAfterMillis==null || retryAfterMillis in 100..60_000)
        entries.filterIsInstance<AuthorPresentationEntry.Available>().forEach {entry->
            val lease=entry.profile.lease
            require(lease.actor==actor && lease.device==device && lease.observedAt<=serverNowMillis && lease.validUntil>serverNowMillis)
            entry.avatar?.plan?.let {require(it.expiresAt>serverNowMillis && it.expiresAt<=lease.validUntil)}
        }
    }
    companion object {
        const val MaximumEntries=16
        const val MaximumViewAgeMillis=30_000L
        const val MaximumEncodedBytes=32*1024
        const val MaximumFrameBytes=33*1024
        fun decode(bytes: ByteArray): AuthorPresentationDelta = try {
            require(bytes.size<=MaximumEncodedBytes)
            val raw=Json.parseToJsonElement(bytes.decodeToString(throwOnInvalidSequence=true)).jsonObject
            val batch=raw.objectValue("batch")
            val entries=(batch["results"] as? JsonArray ?: throw ClientFailure.Protocol()).map {element->
                val entry=element as? JsonObject ?: throw ClientFailure.Protocol()
                if(entry.size!=1) throw ClientFailure.Protocol()
                val value=entry.objectValue(entry.keys.single())
                when(entry.keys.single()) {
                    "presentation"->AuthorPresentationEntry.Available(ProfilePresentationClient.decodeProfile(value.objectValue("_0")),value.authorOptionalObject("avatar")?.let(AvatarAccess::decode))
                    "unavailable"->value.objectValue("_0").let {AuthorPresentationEntry.Unavailable(ProfileReadResult.Unavailable(
                        ProfilePresentationClient.decodeKey(it.objectValue("key")),ProfilePresentationClient.decodeAuthority(it.objectValue("authorityVersion"))))}
                    "retryable"->AuthorPresentationEntry.Retryable(ProfilePresentationClient.decodeKey(value.objectValue("_0")))
                    else->throw ClientFailure.Protocol()
                }
            }.toPersistentList()
            AuthorPresentationDelta(uuidId(raw.authorString("streamID")),uuidId(raw.authorString("viewID")),raw.authorNumber("sequence"),
                UserId(uuidId(raw.objectValue("actorUserID").authorString("rawValue"))),DeviceId(uuidId(raw.objectValue("deviceID").authorString("rawValue"))),
                raw.authorNumber("serverViewAgeMilliseconds"),batch.authorNumber("serverNowUnixMilliseconds"),entries,
                if(raw["retryAfterMilliseconds"]==null || raw["retryAfterMilliseconds"]==JsonNull) null else raw.authorNumber("retryAfterMilliseconds"))
        } catch(_: IllegalArgumentException) {throw ClientFailure.Protocol()}
          catch(_: ArithmeticException) {throw ClientFailure.Protocol()}
          catch(_: java.nio.charset.CharacterCodingException) {throw ClientFailure.Protocol()}
    }
}
private fun JsonObject.authorString(key: String)=(get(key) as? JsonPrimitive)?.takeIf {it.isString}?.content ?: throw ClientFailure.Protocol()
private fun JsonObject.authorNumber(key: String)=(get(key) as? JsonPrimitive)?.takeUnless {it.isString}?.longOrNull ?: throw ClientFailure.Protocol()
private fun JsonObject.authorOptionalObject(key: String): JsonObject?=when(val value=get(key)) {null,JsonNull->null;is JsonObject->value;else->throw ClientFailure.Protocol()}

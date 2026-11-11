package com.xmtx.im.client

import kotlinx.serialization.*
import kotlinx.serialization.descriptors.*
import kotlinx.serialization.encoding.*

/** Owned persistence shape, independent of the public-directory HTTP Codable envelope. */
object PublicIdentitySerializer : KSerializer<PublicIdentity> {
    @Serializable private data class Stored(val user: UserId, val handle: String, val name: String, val kind: AccountKind)
    override val descriptor: SerialDescriptor = Stored.serializer().descriptor
    override fun serialize(encoder: Encoder, value: PublicIdentity) =
        encoder.encodeSerializableValue(Stored.serializer(), Stored(value.user, value.handle.value, value.displayName, value.kind))
    override fun deserialize(decoder: Decoder): PublicIdentity {
        val value = decoder.decodeSerializableValue(Stored.serializer())
        val handle = PublicHandle(value.handle)
        require(handle.value == value.handle)
        return PublicIdentity(value.user, handle, value.name, value.kind)
    }
}

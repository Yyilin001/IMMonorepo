package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.PersistentList
import kotlinx.serialization.json.*
import java.util.UUID

internal fun recoveryEpoch(raw: String): String = try {
    UUID.fromString(raw).also { require(it.toString().equals(raw,true)) }.toString().uppercase()
} catch (_: IllegalArgumentException) { throw ClientFailure.Protocol() }

/** Coverage boundary only; READY does not acknowledge directory or message recovery. */
class AccountRoomChangesClient(private val transport: EnvelopeTransport) {
    suspend fun start(): String {
        val response=transport.request(Envelope.newBuilder().setAccountRoomChangesStart(AccountRoomChangesStart.getDefaultInstance()))
        if(!response.hasAccountRoomChangesReady()) throw ClientFailure.Protocol()
        return recoveryEpoch(response.accountRoomChangesReady.connectionEpoch)
    }
}

/** Retained in the same transaction as personal sync progress. Never a membership grant. */
data class AccountRoomHead(val room: RoomId, val sequence: Long, val membershipRevision: Long) {
    init { require(UUID.fromString(room.value).toString().equals(room.value,true) && sequence > 0 && membershipRevision >= 0) }
    fun merging(newer: AccountRoomHead): AccountRoomHead {
        if(room != newer.room) throw ClientFailure.Protocol()
        if(newer.sequence < sequence) return this
        if(newer.sequence == sequence) {
            if(newer.membershipRevision != membershipRevision) throw ClientFailure.Protocol()
            return this
        }
        if(newer.membershipRevision < membershipRevision) throw ClientFailure.Protocol()
        return newer
    }
    companion object {
        fun decode(value: JsonObject): AccountRoomHead = try {
            fun number(key: String) = value[key]?.jsonPrimitive?.takeUnless {it.isString}?.longOrNull ?: throw ClientFailure.Protocol()
            val room=value["room_id"]?.jsonPrimitive?.takeIf {it.isString}?.content ?: throw ClientFailure.Protocol()
            AccountRoomHead(RoomId(room),number("room_sequence"),number("membership_revision"))
        } catch (_: IllegalArgumentException) {throw ClientFailure.Protocol()}
    }
}
interface AccountRoomHeadStore {
    /** Stable cyclic scan of still-unapplied heads, excluding currently denied rooms. */
    suspend fun pendingRoomHeads(after: RoomId? = null, limit: Int = 32): PersistentList<AccountRoomHead>
}

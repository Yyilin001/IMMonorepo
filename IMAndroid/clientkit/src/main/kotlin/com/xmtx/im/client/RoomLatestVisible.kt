package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.serialization.Serializable
import java.util.UUID

private fun summaryId(value: String): Boolean = value.length == 36 && runCatching {UUID.fromString(value).toString().equals(value,true)}.getOrDefault(false)
@Serializable data class LatestVisibleMessage(val id: MessageId,val sender: UserId,val sequence: Long,val revision: Long,
    val preview: String,val mediaCount: Long,val createdAt: Long)
@Serializable data class LatestVisibleSnapshot(val room: RoomId,val owner: Long,val membership: Long,val head: Long,val latest: LatestVisibleMessage?) {
    val previewText: String get() = latest?.let {if(it.preview.isEmpty() && it.mediaCount>0) "[附件]" else it.preview} ?: "暂无消息"
    fun validate() {
        if(!summaryId(room.value) || owner < 0 || membership < 0 || head < 0 || latest?.let {
            !summaryId(it.id.value) || !summaryId(it.sender.value) || it.sequence !in 1..head || it.revision <= 0 ||
                it.preview.toByteArray().size > 512 || it.mediaCount !in 0..0xffff_ffffL
        } == true) throw ClientFailure.Protocol()
    }
}
sealed interface LatestVisibleResult {
    data class Snapshot(val value: LatestVisibleSnapshot): LatestVisibleResult
    data class Retry(val afterMillis: Long): LatestVisibleResult
    data object Unavailable: LatestVisibleResult
}
class RoomLatestVisibleClient(private val transport: EnvelopeTransport) {
    suspend fun fetch(rooms: PersistentList<RoomId>): PersistentMap<RoomId,LatestVisibleResult> {
        require(rooms.size in 1..100 && rooms.all {summaryId(it.value)})
        val ids=rooms.toSet()
        val response=transport.request(Envelope.newBuilder().setRoomLatestVisibleBatch(RoomLatestVisibleBatch.newBuilder().addAllRoomIds(ids.map {it.value}.sorted())))
        if(!response.hasRoomLatestVisibleBatchResult() || response.roomLatestVisibleBatchResult.roomsCount != ids.size) throw ClientFailure.Protocol()
        val results=mutableMapOf<RoomId,LatestVisibleResult>()
        for(item in response.roomLatestVisibleBatchResult.roomsList) {
            val room=RoomId(item.roomId)
            if(room !in ids || room in results) throw ClientFailure.Protocol()
            results[room]=when {
                item.hasUnavailable() -> LatestVisibleResult.Unavailable
                item.hasRetry() -> LatestVisibleResult.Retry(maxOf(1,Integer.toUnsignedLong(item.retry.retryAfterSeconds))*1_000)
                item.hasSnapshot() -> item.snapshot.let {s ->
                    val latest=if(s.hasLatest()) s.latest.let {LatestVisibleMessage(MessageId(it.messageId),UserId(it.senderUserId),it.roomSequence,it.messageRevision,it.preview,Integer.toUnsignedLong(it.mediaCount),it.createdAtMs)} else null
                    LatestVisibleResult.Snapshot(LatestVisibleSnapshot(room,s.ownerEpoch,s.viewerMembershipRevision,s.head,latest).also {it.validate()})
                }
                else -> throw ClientFailure.Protocol()
            }
        }
        return results.toPersistentMap()
    }
}
data class LatestVisibleRequest(val scope: String,val generation: Long)
data class LatestVisibleCommit(val work: RoomDirectoryWork,val snapshot: LatestVisibleSnapshot)
interface RoomLatestVisibleStore {
    suspend fun ensureLatestVisible(scope: String,rooms: PersistentList<RoomId>)
    suspend fun beginLatestVisible(scope: String): LatestVisibleRequest
    /** Display-only transaction, never a room cursor or delivery/read acknowledgement. */
    suspend fun commitLatestVisible(request: LatestVisibleRequest,work: RoomDirectoryWork,snapshot: LatestVisibleSnapshot): Boolean
    /** One transaction; stale observations may be rejected independently, while failures roll back the batch. */
    suspend fun commitLatestVisibleBatch(request: LatestVisibleRequest,entries: PersistentList<LatestVisibleCommit>): PersistentSet<RoomId>
}

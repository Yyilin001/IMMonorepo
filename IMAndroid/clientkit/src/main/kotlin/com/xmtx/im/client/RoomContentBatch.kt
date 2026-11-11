package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import java.util.UUID

/** Captured before network I/O; a later grant cannot authorize this request's old body. */
data class RoomMembershipFence(val revision: Long,val source: String,val active: Boolean)
data class RoomContentFence(val cursor: RoomCursor,val owner: Long,val membership: Long,val member: RoomMembershipFence?)
data class RoomContentRequest(val scope: String,val generation: Long,val fences: PersistentMap<RoomId,RoomContentFence>)
data class RoomContentRead(val cursor: RoomCursor,val pageSize: Int)
data class RoomContentResponse(val pages: PersistentMap<RoomId,GroupEventPage>,val unavailable: PersistentSet<RoomId>)
interface RoomContentStore {
    suspend fun beginRoomContent(scope: String,work: PersistentList<RoomDirectoryWork>): RoomContentRequest
    /** All fences, pages and denials are checked and committed in one transaction. No network acknowledgments here. */
    suspend fun commitRoomContent(request: RoomContentRequest,response: RoomContentResponse): PersistentMap<RoomId,RoomCursor>
}

class RoomContentClient(private val transport: EnvelopeTransport) {
    suspend fun fetch(reads: PersistentMap<RoomId,RoomContentRead>): RoomContentResponse {
        require(reads.size in 1..16 && reads.all {(room,read) ->
            runCatching {UUID.fromString(room.value).toString().equals(room.value,true)}.getOrDefault(false) &&
                read.cursor.sequence>=0 && read.pageSize in 1..32
        })
        val batch=GroupEventPullBatch.newBuilder()
        fun pull(room: RoomId,read: RoomContentRead)=GroupEventPull.newBuilder().setRoomId(room.value)
            .setAfterRoomSequence(read.cursor.sequence).setPageSize(read.pageSize)
        reads.forEach {(room,read) -> batch.addRooms(pull(room,read))}
        val response=transport.request(Envelope.newBuilder().setGroupEventPullBatch(batch))
        if(!response.hasGroupEventPageBatch()) throw ClientFailure.Protocol()
        val entries=response.groupEventPageBatch.roomsList
        if(entries.size!=reads.size || entries.map {RoomId(it.roomId)}.toSet()!=reads.keys) throw ClientFailure.Protocol()
        val pages=linkedMapOf<RoomId,GroupEventPage>();val denied=linkedSetOf<RoomId>();val singles=mutableListOf<RoomId>()
        fun accept(room: RoomId,page: GroupEventPage) {
            val read=reads.getValue(room)
            RoomSyncEngine.validateBatchPage(room,read.cursor,page,read.pageSize)
            pages[room]=page
        }
        fun failure(room: RoomId,error: GatewayFailure) {
            if(error.code=="FORBIDDEN" && !error.retryable) denied+=room else throw error
        }
        // Validate the whole batch before a size fallback performs further I/O.
        for(entry in entries) {
            val room=RoomId(entry.roomId)
            when {
                entry.hasPage() -> accept(room,entry.page)
                entry.hasError() -> if(entry.error.code=="BATCH_PAGE_REQUIRES_SINGLE_PULL") singles+=room
                    else failure(room,GatewayFailure(entry.error.code,entry.error.retryable,entry.error.retryAfterSeconds))
                else -> throw ClientFailure.Protocol()
            }
        }
        for(room in singles) try {
            val single=transport.request(Envelope.newBuilder().setGroupEventPull(pull(room,reads.getValue(room))))
            if(!single.hasGroupEventPage()) throw ClientFailure.Protocol()
            accept(room,single.groupEventPage)
        } catch(e: GatewayFailure) {failure(room,e)}
        return RoomContentResponse(pages.toPersistentMap(),denied.toPersistentSet())
    }
}

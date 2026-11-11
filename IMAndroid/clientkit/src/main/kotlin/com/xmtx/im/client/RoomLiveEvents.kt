package com.xmtx.im.client

import com.google.protobuf.ByteString
import com.xmtx.imclientkit.generated.im.realtime.v2.GroupEventAvailable
import kotlinx.collections.immutable.*
import java.util.UUID

/** Immutable optional acceleration value. A notification never grants room access. */
data class RoomLiveEvent(val source: String, val sequence: Long, val kind: String, val payload: ByteString)

internal object RoomLiveEvents {
    const val maximumCount = 500
    const val maximumBytes = 1_048_576L
    const val inboxBytes = 16 * maximumBytes
    fun bytes(events: Iterable<RoomLiveEvent>) = events.sumOf { it.payload.size().toLong()+128 }
    private fun valid(event: RoomLiveEvent, head: Long): Boolean = event.sequence in 1..head &&
        event.kind.isNotEmpty() && !event.payload.isEmpty && runCatching {
            event.source.length == 36 && UUID.fromString(event.source).toString().equals(event.source,true)
        }.getOrDefault(false)

    /** Invalid optional bodies degrade to the original metadata-only hint. */
    fun decode(hint: GroupEventAvailable): PersistentList<RoomLiveEvent> {
        if(hint.liveEventsCount > maximumCount) return persistentListOf()
        val events = if(hint.liveEventsCount > 0) hint.liveEventsList.map {
            RoomLiveEvent(it.sourceEventId.uppercase(),it.roomSequence,it.projectionKind,it.payload)
        } else listOf(RoomLiveEvent(hint.sourceEventId.uppercase(),hint.roomSequence,hint.projectionKind,hint.eventPayload))
        if(events.any {!valid(it,hint.highWatermark)} || bytes(events) > maximumBytes ||
            events.zipWithNext().any {(a,b) -> a.sequence == Long.MAX_VALUE || b.sequence != a.sequence+1}) return persistentListOf()
        return events.toPersistentList()
    }
    /** Sparse batches may be filled by later notifications with an unchanged head. */
    fun merge(head: Long, old: PersistentList<RoomLiveEvent>, incoming: PersistentList<RoomLiveEvent>): PersistentList<RoomLiveEvent> {
        val bySequence=sortedMapOf<Long,RoomLiveEvent>()
        for(event in old+incoming) {
            if(!valid(event,head)) return persistentListOf()
            val prior=bySequence.put(event.sequence,event)
            if(prior != null && prior != event) return persistentListOf()
        }
        var bytes=0L
        val newest=mutableListOf<RoomLiveEvent>()
        for(event in bySequence.values.reversed()) {
            val size=event.payload.size().toLong()+128
            if(newest.size == maximumCount || bytes+size > maximumBytes) break
            newest+=event;bytes+=size
        }
        return newest.asReversed().toPersistentList()
    }
}

/** Implementations check authorization and cursor equality inside the projection transaction. */
interface LiveRoomStore : RoomStore {
    suspend fun commitLiveRoom(page: com.xmtx.imclientkit.generated.im.realtime.v2.GroupEventPage, expected: RoomCursor): Boolean
}

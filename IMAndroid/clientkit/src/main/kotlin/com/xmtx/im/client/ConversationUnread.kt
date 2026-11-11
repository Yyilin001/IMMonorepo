package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.PersistentMap
import kotlinx.collections.immutable.persistentListOf

/** Local reading position, including pending/archived intents. This is not a server receipt. */
interface RoomReadWatermarkReading {
    /** At most 128 requested rooms; missing rooms have no entry. Duplicates are harmless. */
    suspend fun roomReadWatermarks(rooms: PersistentList<RoomId>): PersistentMap<RoomId, Long>
    suspend fun roomReadWatermark(room: RoomId): Long? = roomReadWatermarks(persistentListOf(room))[room]
}

object ConversationUnread {
    /** Local evidence can reduce the authoritative count, never increase it. */
    fun displayedUnread(serverUnread: Long, head: Long, localWatermark: Long?): Long {
        require(serverUnread >= 0 && head >= 0 && (localWatermark == null || localWatermark >= 0))
        val watermark = localWatermark ?: 0
        return minOf(serverUnread, if (head > watermark) head - watermark else 0)
    }
}

data class ConversationUnreadRow(val room: RoomId, val head: Long, val serverUnread: Long, val localReadWatermark: Long?) {
    val displayedUnread: Long = ConversationUnread.displayedUnread(serverUnread, head, localReadWatermark)
}

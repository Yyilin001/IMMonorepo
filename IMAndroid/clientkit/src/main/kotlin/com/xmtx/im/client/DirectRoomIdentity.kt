package com.xmtx.im.client

/** Device-owned creation context. Neither a server projection nor current room permission. */
data class DirectRoomIdentity(val room: RoomId, val publicIdentity: PublicIdentity,
    val roomCreatedAt: Long, val updatedAt: Long) {
    init { require(roomCreatedAt >= 0 && updatedAt >= 0) }
}

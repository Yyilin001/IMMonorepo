package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.coroutines.flow.StateFlow
import java.util.UUID

/** A local operation identity is never a server room identity. */
sealed interface DirectConversationDestination {
    data class Room(val room: RoomId) : DirectConversationDestination
    data class Pending(val operation: String) : DirectConversationDestination {
        init { require(uuidId(operation) == operation) }
    }
}
data class LocalDirectMessage(val id: String, val operation: String, val text: String, val createdAt: Long) {
    init {
        require(uuidId(id) == id && uuidId(operation) == operation && createdAt >= 0)
        require(text.isNotBlank() && text == text.trim() && text.toByteArray(Charsets.UTF_8).size <= 65_536)
    }
    companion object {
        fun create(operation: String, text: String, now: Long = System.currentTimeMillis()) =
            LocalDirectMessage(UUID.randomUUID().toString().uppercase(), operation, text.trim(), now)
    }
}
interface LocalDirectMessageStore {
    val localDirectMessageChanges: StateFlow<Long>
    suspend fun existingDirectRoom(actor: UserId, target: UserId): RoomId?
    suspend fun saveLocalDirectMessage(actor: UserId, message: LocalDirectMessage)
    suspend fun localDirectMessages(actor: UserId, operation: String? = null): PersistentList<LocalDirectMessage>
    /** One transaction freezes one ready send with the same ID and removes its local row. */
    suspend fun prepareNextLocalDirectMessage(actor: UserId, now: Long): Boolean
}

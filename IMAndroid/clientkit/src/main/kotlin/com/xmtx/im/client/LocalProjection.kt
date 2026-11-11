package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.persistentListOf

/** Local text only: no media URL/capability, profile lease, command or read-receipt evidence. */
data class LocalConversation(val room: RoomId, val title: String, val preview: String, val updatedAt: Long)
data class LocalConversationCursor(val updatedAt: Long, val room: RoomId)
data class LocalConversationPage(val entries: PersistentList<LocalConversation>, val next: LocalConversationCursor?)
data class LocalTextMessage(val id: MessageId, val sender: UserId, val text: String, val createdAt: Long,
    val withdrawn: Boolean, val attachment: Boolean, val senderName: String? = null)
data class LocalMessagePage(val room: RoomId, val entries: PersistentList<LocalTextMessage>,
    val older: TimelineCursor?, val available: Boolean)
data class LocalProjectionSnapshot(val active: Boolean = true,
    val conversations: PersistentList<LocalConversation> = persistentListOf(),
    val nextConversations: LocalConversationCursor? = null,
    val messages: LocalMessagePage? = null)

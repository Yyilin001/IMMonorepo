package com.xmtx.im.client

import kotlinx.collections.immutable.*

sealed interface MessageSearchScope {
    data object All : MessageSearchScope
    data class Room(val room: RoomId) : MessageSearchScope
    data class Sender(val sender: UserId) : MessageSearchScope
}
enum class MessageSearchContent { All, Media, Image, Video, File, Audio }
data class MessageSearchRequest(val query: String, val scope: MessageSearchScope = MessageSearchScope.All,
    val content: MessageSearchContent = MessageSearchContent.All, val sender: UserId? = null,
    val limit: Int = 50, val cursor: MessageSearchCursor? = null)
/** Local, process-bound continuation. Never serialize this as a server cursor or navigation route. */
data class MessageSearchContext(val instance: String, val viewer: UserId, val generation: Long, val indexGeneration: Long,
    val scope: MessageSearchScope, val content: MessageSearchContent, val sender: UserId?, val phrase: String)
data class MessageSearchCursor(val context: MessageSearchContext, val watermark: Long, val order: Long, val message: MessageId)
data class MessageSearchRange(val offset: Int, val length: Int) {
    init { require(offset >= 0 && length > 0) }
}
data class MessageSearchPreview(val text: String, val ranges: PersistentList<MessageSearchRange> = persistentListOf())
data class MessageSearchHit(val message: MessageId, val room: RoomId, val sender: UserId, val roomSequence: Long,
    val createdAt: Long, val revision: Long, val preview: MessageSearchPreview)
data class MessageSearchPage(val hits: PersistentList<MessageSearchHit> = persistentListOf(),
    val next: MessageSearchCursor? = null, val catchingUp: Boolean = false)
data class MessageSearchProgress(val ready: Boolean, val pending: Int, val sourceSequence: Long, val generation: Long)
sealed class MessageSearchFailure : Exception() {
    class Building : MessageSearchFailure()
    class InvalidContinuation : MessageSearchFailure()
    class EmptyQuery : MessageSearchFailure()
}
interface MessageSearchStore {
    suspend fun searchMessages(viewer: UserId, request: MessageSearchRequest): MessageSearchPage
    suspend fun processMessageSearchIndex(limit: Int = 64): MessageSearchProgress
    suspend fun messageSearchProgress(): MessageSearchProgress
    suspend fun rebuildMessageSearchIndex()
}

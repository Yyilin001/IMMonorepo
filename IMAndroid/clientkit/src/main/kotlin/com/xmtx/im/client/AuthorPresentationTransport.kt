package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList

interface AuthorPresentationSource {
    fun beginAuthorPresentationView(messageRooms: PersistentList<RoomId>): AuthorPresentationView
    fun endAuthorPresentationView(view: AuthorPresentationView)
    suspend fun nextAuthorPresentationDelta(view: AuthorPresentationView): ReceivedAuthorPresentationDelta
}
interface AuthorPresentationCommands {
    suspend fun start(value: AuthorPresentationStart)
    suspend fun end(value: AuthorPresentationStart)
    suspend fun interests(value: AuthorPresentationInterests)
    suspend fun receipt(value: AuthorPresentationReceipt)
}

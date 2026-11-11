package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentMap
import kotlinx.collections.immutable.PersistentSet
import kotlinx.collections.immutable.persistentSetOf

/** A bounded read of current, accepted message sources from one local database snapshot.
 * Missing, withdrawn, redacted, inaccessible and foreign-account sources are all omitted.
 * Accepts zero to 100 unique IDs; oversized requests fail before reading.
 * Legacy accepted projections with an unknown room-log position remain readable.
 * No pending outbox items or surrounding history are included. The returned revision is
 * evidence for preparing an operation, not a lock or proof of server acceptance. */
interface MessageSourceStore {
    suspend fun messageSources(room: RoomId, viewer: UserId,
        ids: PersistentSet<MessageId>): PersistentMap<MessageId, Message>
}

suspend fun MessageSourceStore.messageSource(room: RoomId, viewer: UserId, id: MessageId): Message? =
    messageSources(room, viewer, persistentSetOf(id))[id]

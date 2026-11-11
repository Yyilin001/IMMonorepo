package com.xmtx.im.client

import kotlinx.collections.immutable.*

/** Local ordering coordinate, independent of room-log ACK/read-receipt positions. */
data class TimelineCursor(val sequence: Long, val message: MessageId,val kind:TimelineItemKind=TimelineItemKind.Message) {
    init { require(sequence > 0) }
}

sealed interface TimelineSelection {
    data object Latest : TimelineSelection
    data class Before(val cursor: TimelineCursor) : TimelineSelection
    data class After(val cursor: TimelineCursor) : TimelineSelection
    /** Inclusive upper bound used to refresh a history window without following incoming messages. */
    data class Through(val cursor: TimelineCursor) : TimelineSelection
}

/** All values, including reply previews and decorations, come from one local read transaction.
 * Messages are oldest first. Boundaries remain useful after their source rows are deleted.
 * Reply sources are one level deep and never become timeline rows or read-receipt evidence. */
data class ConversationTimelineWindow(
    val messages: PersistentList<Message> = persistentListOf(),
    val olderCursor: TimelineCursor? = null,
    val newerBoundary: TimelineCursor? = null,
    val replySources: PersistentMap<MessageId, Message> = persistentMapOf(),
    val reactions: PersistentList<MessageReactionSummary> = persistentListOf(),
    val pinned: PersistentSet<MessageId> = persistentSetOf(),
    val checkpoint: RoomReadCheckpoint? = null,
    val directRead: DirectReadProjection? = null,
    val available: Boolean = true,
    val outbox: PersistentList<Message> = persistentListOf(),
    val latest: Boolean = newerBoundary==null,
    val activities:PersistentList<TimelineActivity> = persistentListOf(),
) {
    init { require(messages.size+activities.size <= 200 && replySources.size <= messages.size+outbox.size && outbox.size<=40) }
    val entries:PersistentList<ConversationTimelineEntry> = (messages.map {ConversationTimelineEntry.MessageEntry(it)}+activities.map {ConversationTimelineEntry.ActivityEntry(it)})
        .sortedWith(compareBy<ConversationTimelineEntry> {when(it) {is ConversationTimelineEntry.MessageEntry->it.message.timelineSequence;is ConversationTimelineEntry.ActivityEntry->it.activity.sequence}}.thenBy {when(it) {is ConversationTimelineEntry.MessageEntry->it.message.id.value;is ConversationTimelineEntry.ActivityEntry->it.activity.sourceEvent}}.thenBy {if(it is ConversationTimelineEntry.MessageEntry) 0 else 1}).toPersistentList()
}

sealed interface TimelineLocation {
    data class Found(val window: ConversationTimelineWindow) : TimelineLocation
    data object Withdrawn : TimelineLocation
    /** Missing, inaccessible, another room or another account intentionally share one result. */
    data object Unavailable : TimelineLocation
}

interface ConversationTimelineStore {
    suspend fun conversationTimeline(room: RoomId, viewer: UserId,
        selection: TimelineSelection = TimelineSelection.Latest, limit: Int = 120): ConversationTimelineWindow
    suspend fun locateTimelineMessage(room: RoomId, viewer: UserId, message: MessageId,
        before: Int = 59, after: Int = 60): TimelineLocation
    suspend fun locateTimelineActivity(room:RoomId,viewer:UserId,source:String,before:Int=59,after:Int=60):TimelineLocation = TimelineLocation.Unavailable
}

fun Message.timelineCursor(): TimelineCursor = TimelineCursor(timelineSequence, id)

package com.xmtx.im.client

import kotlinx.serialization.json.*

enum class TimelineActivityKind(val wire:String) {
    DirectMessageRestricted("direct_message_restricted"),SystemAccountReadOnly("system_account_read_only")
}
/** Private display reason, never a message or evidence for a room-log read receipt. */
data class TimelineActivity(val sourceEvent:String,val room:RoomId,val sequence:Long,val kind:TimelineActivityKind,val createdAt:Long) {
    init {require(sourceEvent==canonicalId(sourceEvent) && sequence>0 && createdAt>=0)}
    val key:String get()="activity:$sourceEvent"
    fun cursor()=TimelineCursor(sequence,MessageId(sourceEvent),TimelineItemKind.Activity)
    companion object {
        fun decode(source:String,value:JsonObject):TimelineActivity {
            fun string(key:String):String {
                val field=value[key] as? JsonPrimitive ?: throw ClientFailure.Protocol()
                if(!field.isString) throw ClientFailure.Protocol()
                return field.content
            }
            fun number(key:String):Long {
                val field=value[key] as? JsonPrimitive ?: throw ClientFailure.Protocol()
                if(field.isString) throw ClientFailure.Protocol()
                return field.longOrNull ?: throw ClientFailure.Protocol()
            }
            val kind=TimelineActivityKind.entries.firstOrNull {it.wire==string("event_type")} ?: throw ClientFailure.Protocol()
            return TimelineActivity(canonicalId(source),RoomId(canonicalId(string("room_id"))),number("timeline_sequence"),kind,number("server_created_at_ms"))
        }
    }
}
enum class TimelineItemKind {Message,Activity}
sealed interface ConversationTimelineEntry {
    val cursor:TimelineCursor
    val key:String
    data class MessageEntry(val message:Message):ConversationTimelineEntry {
        override val cursor get()=message.timelineCursor()
        override val key get()=message.id.value
    }
    data class ActivityEntry(val activity:TimelineActivity):ConversationTimelineEntry {
        override val cursor get()=activity.cursor()
        override val key get()=activity.key
    }
}
val timelineCursorOrder:Comparator<TimelineCursor> = compareBy<TimelineCursor> {it.sequence}.thenBy {it.message.value}.thenBy {it.kind.ordinal}

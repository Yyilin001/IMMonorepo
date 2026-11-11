package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*
import kotlin.test.*

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class TimelineActivityTests {
    private val room=RoomId("room")
    private fun value(sequence:String="1",time:String="0",kind:String="direct_message_restricted")=Json.parseToJsonElement("""{"room_id":"room","event_type":"$kind","timeline_sequence":$sequence,"server_created_at_ms":$time}""").jsonObject
    @Test fun `private reasons accept only known positive positions and numeric timestamps`() {
        assertEquals(TimelineActivityKind.DirectMessageRestricted,TimelineActivity.decode("event",value()).kind)
        assertEquals(TimelineActivityKind.SystemAccountReadOnly,TimelineActivity.decode("event",value(kind="system_account_read_only")).kind)
        for(wire in listOf(value("0"),value("-1"),value("\"1\""),value(time="-1"),value(time="\"0\""),value(kind="peer_blocked_you")))
            assertFails {TimelineActivity.decode("event",wire)}
        assertFails {TimelineActivity.decode("event",JsonObject(value()+ ("room_id" to JsonPrimitive(12))))}
    }
    @Test fun `same identity and sequence retain two distinct typed entries without inventing messages`() {
        val message=Message(MessageId("same"),room,UserId("viewer"),"text",1,roomSequence=1)
        val activity=TimelineActivity("same",room,1,TimelineActivityKind.DirectMessageRestricted,1)
        val window=ConversationTimelineWindow(messages=persistentListOf(message),activities=persistentListOf(activity))
        assertEquals(listOf("same","activity:same"),window.entries.map {it.key})
        assertTrue(timelineCursorOrder.compare(message.timelineCursor(),activity.cursor())<0)
        assertEquals(listOf(message),window.messages);assertTrue(window.replySources.isEmpty())
    }
    @Test fun `activity only windows page restore and refresh using activity coordinates`()=runTest {
        val activities=(1..8).map {TimelineActivity("event$it",room,it.toLong(),TimelineActivityKind.DirectMessageRestricted,1)}
        val selections=mutableListOf<TimelineSelection>()
        val store=object:ConversationTimelineStore {
            override suspend fun conversationTimeline(room:RoomId,viewer:UserId,selection:TimelineSelection,limit:Int):ConversationTimelineWindow {
                selections+=selection
                val selected=when(selection) {
                    TimelineSelection.Latest->activities.takeLast(limit)
                    is TimelineSelection.Before->activities.filter {timelineCursorOrder.compare(it.cursor(),selection.cursor)<0}.takeLast(limit)
                    is TimelineSelection.After->activities.filter {timelineCursorOrder.compare(it.cursor(),selection.cursor)>0}.take(limit)
                    is TimelineSelection.Through->activities.filter {timelineCursorOrder.compare(it.cursor(),selection.cursor)<=0}.takeLast(limit)
                }
                return ConversationTimelineWindow(activities=selected.toPersistentList(),olderCursor=selected.firstOrNull()?.takeIf {it.sequence>1}?.cursor(),newerBoundary=selected.lastOrNull()?.takeIf {it.sequence<8}?.let {activities[it.sequence.toInt()].cursor()})
            }
            override suspend fun locateTimelineMessage(room:RoomId,viewer:UserId,message:MessageId,before:Int,after:Int)=TimelineLocation.Unavailable
            override suspend fun locateTimelineActivity(room:RoomId,viewer:UserId,source:String,before:Int,after:Int)=TimelineLocation.Found(conversationTimeline(room,viewer,TimelineSelection.Through(activities.first {it.sourceEvent==source}.cursor()),before+after+1))
        }
        ConversationTimelineSession(store,room,UserId("viewer"),this,limit=4).use {page->
            page.latest();runCurrent();assertEquals(listOf(5L,6,7,8),page.state.value.window.activities.map {it.sequence})
            page.older();runCurrent();assertEquals(listOf(3L,4,5,6),page.state.value.window.activities.map {it.sequence})
            page.newer();runCurrent();assertEquals(listOf(5L,6,7,8),page.state.value.window.activities.map {it.sequence})
            page.locateActivity("event3");runCurrent();assertEquals("activity:event3",page.state.value.navigation?.itemKey);assertFalse(page.state.value.navigation!!.highlight)
            page.refresh();runCurrent();assertEquals(TimelineItemKind.Activity,(selections.last() as TimelineSelection.Through).cursor.kind)
            assertTrue(page.state.value.window.messages.isEmpty())
        }
    }
}

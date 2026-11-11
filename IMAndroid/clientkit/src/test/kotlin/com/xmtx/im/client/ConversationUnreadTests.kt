package com.xmtx.im.client

import kotlin.test.*

class ConversationUnreadTests {
    @Test fun `local reading only reduces authoritative unread and handles absent evidence`() {
        assertEquals(7,ConversationUnread.displayedUnread(7,20,null))
        assertEquals(7,ConversationUnread.displayedUnread(7,20,2))
        assertEquals(3,ConversationUnread.displayedUnread(7,20,17))
        assertEquals(0,ConversationUnread.displayedUnread(7,20,20))
        assertEquals(0,ConversationUnread.displayedUnread(7,20,25))
        assertEquals(0,ConversationUnread.displayedUnread(0,20,2))
    }
    @Test fun `large watermarks do not overflow or truncate to UI integer range`() {
        assertEquals(Long.MAX_VALUE,ConversationUnread.displayedUnread(Long.MAX_VALUE,Long.MAX_VALUE,null))
        assertEquals(1,ConversationUnread.displayedUnread(Long.MAX_VALUE,Long.MAX_VALUE,Long.MAX_VALUE-1))
        assertEquals(0,ConversationUnread.displayedUnread(Long.MAX_VALUE,0,Long.MAX_VALUE))
        val row=ConversationUnreadRow(RoomId("room"),100,20,90)
        assertEquals(10,row.displayedUnread)
        assertEquals(20,row.copy(localReadWatermark=null).displayedUnread)
        assertEquals(10,row.displayedUnread)
    }
    @Test fun `negative values are rejected before arithmetic`() {
        assertFailsWith<IllegalArgumentException> {ConversationUnread.displayedUnread(-1,0,null)}
        assertFailsWith<IllegalArgumentException> {ConversationUnread.displayedUnread(0,-1,null)}
        assertFailsWith<IllegalArgumentException> {ConversationUnread.displayedUnread(0,0,-1)}
    }
}

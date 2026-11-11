package com.xmtx.im.client

import kotlinx.serialization.json.*
import kotlin.test.*

class DirectProfileTests {
    private val room = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private val peer = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    private fun value(name: String = "好友",handle: String = "friend") = buildJsonObject {
        put("room_id",room);put("target_user_id",peer);put("display_name",name);put("public_handle",handle);put("account_kind","regular")
        put("revision",2);put("updated_at_ms",1234);put("room_created_at_ms",1000)
    }
    @Test fun `discovery keeps only stable identity metadata and canonical content digest`() {
        val result = DirectProfileDescriptor.decode(value())
        assertEquals(AccountKind.Regular,result.accountKind)
        assertEquals(AccountKind.System,DirectProfileDescriptor.decode(JsonObject(value()+("account_kind" to JsonPrimitive("system")))).accountKind)
        assertEquals(RoomId(room),result.room);assertEquals(UserId(peer),result.peer);assertEquals(2L,result.revision)
        assertFalse(result.toString().contains("好友"));assertFalse(result.toString().contains("friend"))
        assertEquals(result,DirectProfileDescriptor.decode(value(" 好友 ","@FRIEND")))
        assertNotEquals(result.contentDigest,DirectProfileDescriptor.decode(value("新名称")).contentDigest)
    }
    @Test fun `projection rejects malformed identity versions times and public data`() {
        for((key,invalid) in listOf("revision" to JsonPrimitive("2"),"revision" to JsonPrimitive(0),"updated_at_ms" to JsonPrimitive(-1),
            "room_created_at_ms" to JsonPrimitive("1000"),"target_user_id" to JsonPrimitive("friend"),"account_kind" to JsonPrimitive("owner"),"display_name" to JsonPrimitive("\u0000")))
            assertFails { DirectProfileDescriptor.decode(JsonObject(value()+ (key to invalid))) }
        assertFails { DirectProfileDescriptor.decode(JsonObject(value()-"room_created_at_ms")) }
    }
}

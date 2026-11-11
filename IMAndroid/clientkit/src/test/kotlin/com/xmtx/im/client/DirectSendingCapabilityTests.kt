package com.xmtx.im.client

import kotlinx.serialization.json.*
import kotlin.test.*

class DirectSendingCapabilityTests {
    @Test fun `system classification overrides positive or missing availability without restricting support accounts`() {
        for(allowed in listOf(null,true,false)) {
            val policy=ConversationSendingPolicy(allowed,AccountKind.System)
            assertFalse(policy.allowsNewContent);assertEquals("此系统账号仅用于发送通知",policy.restriction)
        }
        for(kind in listOf(null,AccountKind.Regular,AccountKind.CustomerSupport)) {
            assertTrue(ConversationSendingPolicy(null,kind).allowsNewContent)
            assertTrue(ConversationSendingPolicy(true,kind).allowsNewContent)
            assertEquals("当前无法向此会话发送消息",ConversationSendingPolicy(false,kind).restriction)
        }
    }
    private val wire=Json.parseToJsonElement("""{"room_id":"ROOM","can_send":false,"state_version":1,"updated_at_ms":0,"internal_reason":"never exposed"}""").jsonObject
    @Test fun `strict personal capability exposes only safe immutable fields`() {
        assertEquals(DirectSendingCapability(RoomId("ROOM"),false,1,0),DirectSendingCapability.decode(wire))
        assertTrue(DirectSendingCapability.decode(JsonObject(wire+("can_send" to JsonPrimitive(true)))).canSend)
    }
    @Test fun `missing stringified overflowing negative and fractional fields fail`() {
        for(key in listOf("room_id","can_send","state_version","updated_at_ms")) assertFails {DirectSendingCapability.decode(JsonObject(wire-key))}
        for((key,value) in listOf("room_id" to "1","can_send" to "\"false\"","can_send" to "1","can_send" to "null",
            "state_version" to "0","state_version" to "-1","state_version" to "1.5","state_version" to "\"1\"","state_version" to "9223372036854775808",
            "updated_at_ms" to "-1","updated_at_ms" to "\"0\""))
            assertFails {DirectSendingCapability.decode(JsonObject(wire+(key to Json.parseToJsonElement(value))))}
    }
}

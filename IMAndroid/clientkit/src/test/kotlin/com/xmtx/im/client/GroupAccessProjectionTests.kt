package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.serialization.json.*
import kotlin.test.*

class GroupAccessProjectionTests {
    private val room = RoomId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA");private val actor = UserId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB");private val target = UserId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
    private fun policy(role: String = "admin",permissions: List<String> = listOf("send_messages","mute_members")) = buildJsonObject {
        put("event_type","group.role_permissions_changed");put("room_id",room.value);put("role",role);put("revision",3);put("permissions",JsonArray(permissions.map(::JsonPrimitive)))
    }
    private fun member(type: String = "group.member_role_changed") = buildJsonObject {
        put("event_type",type);put("room_id",room.value);put("target_user_id",target.value);put("membership_revision",7);put("role","admin")
    }
    @Test fun `partial policies preserve explicit empty sets without inventing defaults`() {
        val effect = RolePolicyEffect.decode("event",policy(permissions = emptyList()),room,4)
        assertEquals(MemberRole.Admin,effect.role);assertTrue(effect.permissions.isEmpty());assertEquals(3L,effect.revision);assertNull(effect.actor);assertNull(effect.created)
        assertEquals(effect,Json.decodeFromString<RolePolicyEffect>(Json.encodeToString(effect)))
    }
    @Test fun `policy identity normalizes UUIDs and ignores permission order and extension fields`() {
        val first = JsonObject(policy()+mapOf("actor_user_id" to JsonPrimitive(actor.value),"server_created_at_ms" to JsonPrimitive(5)))
        val reordered = JsonObject(first+mapOf("room_id" to JsonPrimitive(room.value.lowercase()),"actor_user_id" to JsonPrimitive(actor.value.lowercase()),"permissions" to JsonArray(listOf(JsonPrimitive("mute_members"),JsonPrimitive("send_messages"))),"private_extension" to JsonPrimitive("ignored")))
        assertEquals(RolePolicyEffect.decode("event",first,room,4),RolePolicyEffect.decode("event",reordered,room,4))
    }
    @Test fun `invalid policies fail closed for owner duplicates unknown names and strict field types`() {
        for(value in listOf(policy("owner"),policy(permissions = listOf("send_messages","send_messages")),policy(permissions = listOf("future_permission")),
            JsonObject(policy()+mapOf("revision" to JsonPrimitive("3"))),JsonObject(policy()+mapOf("revision" to JsonPrimitive(0))),
            JsonObject(policy()+mapOf("server_created_at_ms" to JsonPrimitive(-1))),JsonObject(policy()+mapOf("room_sequence" to JsonPrimitive(5)))))
            assertFailsWith<ClientFailure.Protocol> { RolePolicyEffect.decode("event",value,room,4) }
        assertFailsWith<ClientFailure.Protocol> { RolePolicyEffect.decode("event",policy(),RoomId(actor.value),4) }
    }
    @Test fun `role facts bind target version independently of viewer and envelope sequence`() {
        val value = MemberAccessEffect.decode("event","group_capability",member(),room,4).single()
        assertEquals(target,value.user);assertEquals(7L,value.revision);assertEquals(4L,value.sequence);assertEquals(MemberRole.Admin,value.role)
        assertTrue(value.sameMeaning(value.copy(sequence = null)));assertFalse(value.sameMeaning(value.copy(source = "other")))
        assertFailsWith<ClientFailure.Protocol> { MemberAccessEffect.decode("event","group_capability",JsonObject(member()+mapOf("room_sequence" to JsonPrimitive(5))),room,4) }
        assertFailsWith<ClientFailure.Protocol> { MemberAccessEffect.decode("event","group_capability",JsonObject(member()+mapOf("role" to JsonPrimitive("owner"))),room,4) }
    }
    @Test fun `member add and remove keep fences without assigning a guessed role`() {
        for(action in listOf("add","remove")) {
            val value = JsonObject(member("membership_changed")+mapOf("action" to JsonPrimitive(action)))
            val effect = MemberAccessEffect.decode("event","membership",value,room).single()
            assertNull(effect.role);assertNull(effect.sequence);assertEquals(if(action == "add") MemberEffectAction.Add else MemberEffectAction.Remove,effect.action)
            assertFailsWith<ClientFailure.Protocol> { MemberAccessEffect.decode("event","group_capability",value,room,2) }
        }
    }
    @Test fun `ownership transfer emits both exact roles and validates previous owner authority`() {
        val value = buildJsonObject {
            put("event_type","group.ownership_transferred");put("action","transfer");put("room_id",room.value);put("membership_revision",9)
            put("previous_owner_user_id",actor.value);put("owner_user_id",target.value);put("actor_user_id",actor.value)
        }
        val effects = MemberAccessEffect.decode("event","membership",value,room,5)
        assertEquals(listOf(actor,target),effects.map { it.user });assertEquals(listOf(MemberRole.Member,MemberRole.Owner),effects.map { it.role })
        assertFailsWith<ClientFailure.Protocol> { MemberAccessEffect.decode("event","membership",JsonObject(value+mapOf("actor_user_id" to JsonPrimitive(target.value))),room,5) }
        assertFailsWith<ClientFailure.Protocol> { MemberAccessEffect.decode("event","membership",JsonObject(value+mapOf("owner_user_id" to JsonPrimitive(actor.value))),room,5) }
    }
}

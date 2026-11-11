package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class GroupAccessStorageTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val actor = UserId(UUID.randomUUID().toString());private val target = UserId(UUID.randomUUID().toString())
    private val device = DeviceId(UUID.randomUUID().toString());private val room = RoomId(UUID.randomUUID().toString())
    private fun id() = UUID.randomUUID().toString().uppercase()
    private fun store() = SqliteClientStore(context,actor,device)
    private suspend fun ready(store: SqliteClientStore) = store.acceptState(room,RoomSyncState.newBuilder().setViewerMembershipRevision(10).setHead(100).build())
    private fun policy(role: String,revision: Long,permissions: List<String>) = buildJsonObject {
        put("event_type","group.role_permissions_changed");put("room_id",room.value);put("role",role);put("revision",revision);put("permissions",JsonArray(permissions.map(::JsonPrimitive)))
    }
    private fun member(action: String,revision: Long) = buildJsonObject {
        put("event_type",if(action == "role") "group.member_role_changed" else "membership_changed");put("room_id",room.value);put("membership_revision",revision)
        put("target_user_id",target.value);put("action",action);if(action == "role") put("role","admin");put("title","group")
    }
    private suspend fun apply(store: SqliteClientStore,sequence: Long,value: JsonObject,source: String = id(),kind: String = "group_capability") = store.commitRoom(
        GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(sequence).addEvents(GroupEvent.newBuilder().setRoomSequence(sequence).setSourceEventId(source).setProjectionKind(kind).setPayload(ByteString.copyFromUtf8(value.toString()))).build(),store.roomCursor(room))
    private suspend fun personal(store: SqliteClientStore,value: JsonObject,source: String) {
        val cursor = store.cursor();val sequence = cursor.sequence+1
        store.commit(SyncBatch.newBuilder().setGeneration(maxOf(1,cursor.generation)).setNextSyncToken("token-$sequence").setSyncReceipt("receipt-$sequence")
            .addRecords(SyncRecord.newBuilder().setUserSyncSequence(sequence).setSourceEventId(source).setProjectionKind("membership").setPayload(ByteString.copyFromUtf8(value.toString()))).build(),cursor)
    }
    @Test fun independentRolePoliciesRetainEmptySetsAndRejectChangedSourceOrCurrentRevision() = runBlocking {
        var store = store();try {
            ready(store);val source = id()
            apply(store,1,policy("admin",5,listOf("mute_members")),source)
            apply(store,2,policy("member",2,emptyList()))
            store.close();store = store();val policies = store.snapshot().rolePolicies
            assertEquals(2,policies.size);assertTrue(policies.first { it.role == MemberRole.Member }.permissions.isEmpty())
            assertEquals(persistentSetOf(GroupPermission.Mute),policies.first { it.role == MemberRole.Admin }.permissions)
            try { apply(store,3,policy("admin",5,listOf("mute_members")),source);fail("source moved") } catch(_: ClientFailure.Protocol) { }
            try { apply(store,3,policy("admin",5,emptyList()));fail("same revision changed") } catch(_: ClientFailure.Protocol) { }
            assertEquals(2L,store.roomCursor(room).sequence)
            apply(store,3,policy("admin",1,listOf("send_messages")));assertEquals(policies,store.snapshot().rolePolicies)
            store.unavailable(room);assertTrue(store.snapshot().rolePolicies.isEmpty())
        } finally { store.close() }
    }
    @Test fun targetRemovalFencesOldRolesDespiteHigherViewerRevisionAndSurvivesReopen() = runBlocking {
        var store = store();try {
            ready(store);apply(store,1,member("role",2));apply(store,2,member("remove",3),kind = "membership")
            store.close();store = store();assertEquals(MemberEffectAction.Remove,store.snapshot().memberAccess.single().action)
            try { apply(store,3,member("role",2));fail("historical revision reused") } catch(_: ClientFailure.Protocol) { }
            apply(store,3,member("role",1));assertNull(store.snapshot().memberAccess.single().role)
            apply(store,4,member("role",4));assertEquals(MemberRole.Admin,store.snapshot().memberAccess.single().role)
            apply(store,5,member("add",5),kind = "membership");assertNull(store.snapshot().memberAccess.single().role)
            assertEquals(5L,store.snapshot().memberAccess.single().revision)
        } finally { store.close() }
    }
    @Test fun personalAndRoomTransfersMergeSequenceWithoutInventingViewerMembership() = runBlocking {
        var store = store();try {
            ready(store);val source = id();val transfer = buildJsonObject {
                put("event_type","group.ownership_transferred");put("action","transfer");put("room_id",room.value);put("membership_revision",11);put("title","group")
                put("previous_owner_user_id",actor.value);put("owner_user_id",target.value);put("actor_user_id",actor.value)
            }
            personal(store,transfer,source);assertTrue(store.snapshot().memberAccess.all { it.sequence == null })
            apply(store,1,transfer,source,"membership");store.close();store = store()
            val effects = store.snapshot().memberAccess;assertEquals(2,effects.size);assertTrue(effects.all { it.sequence == 1L })
            assertEquals(MemberRole.Owner,effects.first { it.user == target }.role);assertEquals(MemberRole.Member,effects.first { it.user == actor }.role)
            personal(store,transfer,source);assertEquals(effects,store.snapshot().memberAccess)
            try { apply(store,2,transfer,source,"membership");fail("source sequence moved") } catch(_: ClientFailure.Protocol) { }
            val revoked = JsonObject(member("remove",12)+mapOf("target_user_id" to JsonPrimitive(actor.value)))
            personal(store,revoked,id());assertTrue(store.snapshot().memberAccess.isEmpty())
        } finally { store.close() }
    }
    @Test fun snapshotPreservesAccessHistoryOnlyForUnchangedViewerGrant() = runBlocking {
        val store = store();try {
            ready(store);apply(store,1,member("role",2));apply(store,2,member("remove",3),kind = "membership");apply(store,3,policy("member",3,emptyList()))
            fun items(revision: Long) = persistentListOf(SnapshotItem("room","room:${room.value}","snapshot",1,ByteString.copyFromUtf8(buildJsonObject {
                put("event_type","room.created");put("room_id",room.value);put("membership_revision",revision);put("title","group")
                put("viewer_membership_revision",revision);put("viewer_is_member",true);put("viewer_membership_source_event_id","grant-$revision")
            }.toString())))
            val manifest = SnapshotManifest.newBuilder().setGeneration(2).setBaseUserSyncSequence(1).setNextSyncToken("snapshot").build()
            store.validateSnapshot(items(10));assertEquals(MemberEffectAction.Remove,store.snapshot().memberAccess.single().action)
            store.activateFixture(manifest,items(10));assertEquals(MemberEffectAction.Remove,store.snapshot().memberAccess.single().action);assertEquals(1,store.snapshot().rolePolicies.size)
            store.acceptState(room,RoomSyncState.newBuilder().setViewerMembershipRevision(10).setHead(100).build())
            try { apply(store,1,member("role",2));fail("snapshot forgot member history") } catch(_: ClientFailure.Protocol) { }
            store.activateFixture(manifest,items(11));assertTrue(store.snapshot().memberAccess.isEmpty());assertTrue(store.snapshot().rolePolicies.isEmpty())
        } finally { store.close() }
    }
    @Test fun legacyRoomRecordsRebuildEffectsAndMissingOuterSequenceSchedulesLogReplay() = runBlocking {
        var store = store();try {
            ready(store);store.close()
            val digest = MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") { "%02x".format(it) }
            SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$digest.db").path,null,SQLiteDatabase.OPEN_READWRITE).use { db ->
                db.execSQL("DELETE FROM projection_migrations WHERE name='group_access_v1'")
                val legacy = listOf(JsonObject(policy("admin",5,listOf("mute_members"))+mapOf("room_sequence" to JsonPrimitive(1))),JsonObject(member("role",2)+mapOf("room_sequence" to JsonPrimitive(2))),policy("member",6,emptyList()))
                legacy.forEach { db.execSQL("INSERT INTO records VALUES (?,?,?,?)",arrayOf(id(),"group_capability",it.toString().toByteArray(),room.value)) }
                db.execSQL("UPDATE room_cursors SET sequence=3")
            }
            store = store();assertEquals(MemberRole.Admin,store.snapshot().memberAccess.single().role);assertEquals(1,store.snapshot().rolePolicies.size)
            assertEquals(0L,store.roomCursor(room).sequence);assertFalse(store.roomCursor(room).historyIncomplete)
            store.close();store = store();assertEquals(1,store.snapshot().rolePolicies.size)
        } finally { store.close() }
    }
}

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
import java.util.UUID

class RelationshipPageStorageTests {
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private inner class Fixture {
        val actor=UserId(id());val device=DeviceId(id());val file=accountDatabaseFile(context,actor,device)
        var store=SqliteClientStore(context,actor,device)
        suspend fun relationship(user:UserId,state:String="accepted",requester:UserId=actor,time:Long=1000) {
            project("relationship",buildJsonObject {put("target_user_id",user.value);put("state",state);if(state=="pending") put("requested_by_user_id",requester.value);put("updated_at_ms",time)})
        }
        suspend fun project(kind:String,payload:JsonObject) {
            val cursor=store.cursor();val n=cursor.sequence+1
            store.commit(SyncBatch.newBuilder().setGeneration(maxOf(1,cursor.generation)).setNextSyncToken("$n").setSyncReceipt("$n")
                .addRecords(SyncRecord.newBuilder().setUserSyncSequence(n).setSourceEventId(id()).setProjectionKind(kind).setPayload(ByteString.copyFromUtf8(payload.toString()))).build(),cursor)
        }
        suspend fun profile(user:UserId,name:String,handle:String="friend",revision:Long=1) {
            val key=ProfileKey(user,ProfileContext.Relationship)
            val value=ProfileReadResult.Available(AuthorizedProfile(ProfileView(user,PublicIdentity(user,PublicHandle(handle),name,AccountKind.Regular),null,ProfileState.Active,revision,revision),
                ProfileLease(actor,device,key,revision,revision,0,ProfileAuthority(revision,null,0,0),revision,revision+60_000)),System.nanoTime()+60_000_000_000)
            assertTrue(store.saveLocalProfileDisplays(persistentListOf(value),store.profileFences(persistentListOf(key))))
        }
        suspend fun search(query:String,scope:RelationshipPageScope=RelationshipPageScope.Accepted):RelationshipPage {
            while(!store.processRelationshipSearchIndex(2)) {}
            return store.relationshipPage(actor,RelationshipPageRequest(query,scope))
        }
        fun reopen() {store.close();store=SqliteClientStore(context,actor,device)}
        fun close() {store.close();SQLiteDatabase.deleteDatabase(file)}
    }
    @Test fun unicodeSubstringSearchTreatsOperatorsAsTextAndDoesNotMatchInsideEmojiCluster()=runBlocking {
        val f=Fixture();try {
            val first=UserId(id());val second=UserId(id());val unknown=UserId(id())
            for(user in listOf(first,second,unknown)) f.relationship(user)
            f.profile(first,"Ａlice·中文👍🏽 Café","alice_01");f.profile(second,"literal OR \"* 中文名","other")
            for(query in listOf("alice","LICE·中","文👍🏽","Cafe\u0301","ALICE_01","\u0085alice\u0085")) assertEquals(listOf(first),f.search(query).relationships.map {it.target})
            assertTrue(f.search("Café alice").relationships.isEmpty());assertTrue(f.search("👍").relationships.isEmpty());assertEquals(listOf(second),f.search("OR \"*").relationships.map {it.target})
            assertEquals(2,f.search("中文").relationships.size);assertEquals(3,f.search("").relationships.size)
            try {f.search("中".repeat(34));fail("oversized query accepted")} catch(_:RelationshipPageFailure.InvalidQuery) {}
            f.reopen();assertEquals(listOf(first),f.search("alice").relationships.map {it.target})
        } finally {f.close()}
    }
    @Test fun relationshipKeysetTiesDirectionAndAccountBoundContinuationSurviveDataChanges()=runBlocking {
        val f=Fixture();try {
            val users=(0..4).map {UserId(id())}.sortedBy {it.value};for(user in users) f.relationship(user)
            val request=RelationshipPageRequest(limit=2);val first=f.store.relationshipPage(f.actor,request)
            assertEquals(users.take(2),first.relationships.map {it.target});assertNotNull(first.next)
            val second=f.store.relationshipPage(f.actor,request.copy(cursor=first.next));assertEquals(users.drop(2).take(2),second.relationships.map {it.target})
            val last=f.store.relationshipPage(f.actor,request.copy(cursor=second.next));assertEquals(listOf(users.last()),last.relationships.map {it.target});assertNull(last.next)
            f.relationship(users[2],"none",time=2000)
            assertEquals(users.drop(3),f.store.relationshipPage(f.actor,request.copy(cursor=first.next)).relationships.map {it.target})
            val incoming=UserId(id());val outgoing=UserId(id());f.relationship(incoming,"pending",incoming);f.relationship(outgoing,"pending")
            assertEquals(listOf(incoming),f.search("",RelationshipPageScope.Incoming).relationships.map {it.target})
            assertEquals(listOf(outgoing),f.search("",RelationshipPageScope.Outgoing).relationships.map {it.target})
            try {f.store.relationshipPage(UserId(id()),request);fail("foreign viewer")} catch(_:IllegalArgumentException) {}
            try {f.store.relationshipPage(f.actor,request.copy(query="changed",cursor=first.next));fail("foreign query cursor")} catch(_:RelationshipPageFailure.InvalidContinuation) {}
            f.reopen();try {f.store.relationshipPage(f.actor,request.copy(cursor=first.next));fail("retired store cursor")} catch(_:RelationshipPageFailure.InvalidContinuation) {}
        } finally {f.close()}
    }
    @Test fun renameDenialSecurityFloorAndCacheClearInvalidateSearchBeforeReturningStaleHits()=runBlocking {
        val f=Fixture();try {
            val user=UserId(id());val key=ProfileKey(user,ProfileContext.Relationship);f.relationship(user);f.profile(user,"Old Name")
            assertEquals(1,f.search("old").relationships.size);f.profile(user,"New Name",revision=2)
            try {f.store.relationshipPage(f.actor,RelationshipPageRequest("old"));fail("dirty index published")} catch(_:RelationshipPageFailure.Building) {}
            assertTrue(f.search("old").relationships.isEmpty());assertEquals(1,f.search("new").relationships.size)
            assertTrue(f.store.saveLocalProfileDisplays(persistentListOf(ProfileReadResult.Unavailable(key,ProfileAuthority(3,null,0,0))),f.store.profileFences(persistentListOf(key))))
            assertTrue(f.search("new").relationships.isEmpty());f.profile(user,"Returned",revision=4);assertEquals(1,f.search("returned").relationships.size)
            f.project("profile_invalidation",buildJsonObject {put("user_id",user.value);put("minimum_profile_revision",4);put("profile_state","hidden")})
            assertTrue(f.search("returned").relationships.isEmpty());f.profile(user,"Newest",revision=5);assertEquals(1,f.search("newest").relationships.size)
            f.store.clearLocalProfileDisplays();assertTrue(f.search("newest").relationships.isEmpty())
        } finally {f.close()}
    }
    @Test fun oldTokenizerFormatRebuildsExistingProfileFactsInBoundedTurns()=runBlocking {
        val f=Fixture();try {
            val users=(0..4).map {UserId(id())}
            for((n,user) in users.withIndex()) {f.relationship(user);f.profile(user,"Cached $n")}
            assertEquals(5,f.search("cached").relationships.size);f.store.close()
            SQLiteDatabase.openDatabase(f.file.path,null,SQLiteDatabase.OPEN_READWRITE).use {db->
                db.execSQL("UPDATE contact_search_meta SET format='previous-tokenizer'")
                db.execSQL("DELETE FROM contact_search_fts")
            }
            f.reopen()
            try {f.store.relationshipPage(f.actor,RelationshipPageRequest("cached"));fail("incomplete rebuilt index escaped")} catch(_:RelationshipPageFailure.Building) {}
            assertFalse(f.store.processRelationshipSearchIndex(2));assertFalse(f.store.processRelationshipSearchIndex(2));assertTrue(f.store.processRelationshipSearchIndex(2))
            assertEquals(users.toSet(),f.store.relationshipPage(f.actor,RelationshipPageRequest("cached")).relationships.map {it.target}.toSet())
        } finally {f.close()}
    }

    @Test fun anchoredWindowResolvesMovedRowsAndRemovedRowsWithoutOffsetPaging()=runBlocking {
        val f=Fixture();try {
            val users=(0..19).map {UserId(id())}.sortedBy {it.value};for(user in users) f.relationship(user)
            val request=RelationshipPageRequest(limit=6);val anchor=RelationshipAnchor(users[10],1000)
            val initial=f.store.relationshipWindow(f.actor,request,anchor,2)
            assertEquals(users.subList(8,14),initial.page.relationships.map {it.target});assertEquals(anchor,initial.anchor)
            assertTrue(initial.hasEarlier);assertEquals(users[13],initial.page.next!!.target)
            f.relationship(users[10],time=3000)
            val moved=f.store.relationshipWindow(f.actor,request,anchor,2)
            assertEquals(RelationshipAnchor(users[10],3000),moved.anchor);assertFalse(moved.hasEarlier)
            assertEquals(listOf(users[10])+users.take(5),moved.page.relationships.map {it.target})
            f.relationship(users[10],"none",time=4000)
            val removed=f.store.relationshipWindow(f.actor,request,anchor,2)
            assertEquals(users.subList(8,10)+users.subList(11,15),removed.page.relationships.map {it.target})
            assertEquals(users[11],removed.anchor!!.target);assertTrue(removed.hasEarlier)
            assertEquals(users.subList(8,14),initial.page.relationships.map {it.target})
            f.reopen();assertEquals(removed.page.relationships,f.store.relationshipWindow(f.actor,request,anchor,2).page.relationships)
        } finally {f.close()}
    }
    @Test fun windowBackfillsBothEndsAndAppliesSearchScopeAndParameterBounds()=runBlocking {
        val f=Fixture();try {
            val users=(0..7).map {UserId(id())}.sortedBy {it.value}
            for((n,user) in users.withIndex()) {f.relationship(user);f.profile(user,if(n%2==0) "Match $n" else "Different $n")}
            while(!f.store.processRelationshipSearchIndex(3)) {}
            val request=RelationshipPageRequest(limit=3)
            val tail=f.store.relationshipWindow(f.actor,request,RelationshipAnchor(UserId(id()),0),0)
            assertEquals(users.takeLast(3),tail.page.relationships.map {it.target});assertEquals(users.last(),tail.anchor!!.target);assertTrue(tail.hasEarlier);assertNull(tail.page.next)
            val head=f.store.relationshipWindow(f.actor,request,RelationshipAnchor(UserId(id()),Long.MAX_VALUE),2)
            assertEquals(users.take(3),head.page.relationships.map {it.target});assertFalse(head.hasEarlier);assertNotNull(head.page.next)
            val matched=f.store.relationshipWindow(f.actor,request.copy(query="match"),RelationshipAnchor(users[3],1000),1)
            assertEquals(listOf(users[2],users[4],users[6]),matched.page.relationships.map {it.target});assertEquals(users[4],matched.anchor!!.target)
            val empty=f.store.relationshipWindow(f.actor,request.copy(scope=RelationshipPageScope.Incoming),RelationshipAnchor(users[3],1000),1)
            assertTrue(empty.page.relationships.isEmpty());assertNull(empty.anchor);assertFalse(empty.hasEarlier)
            val one=f.store.relationshipWindow(f.actor,request.copy(limit=1),RelationshipAnchor(users[3],1000),0)
            assertEquals(listOf(users[3]),one.page.relationships.map {it.target});assertTrue(one.hasEarlier);assertNotNull(one.page.next)
            try {f.store.relationshipWindow(UserId(id()),request,RelationshipAnchor(users[3],1000),1);fail("foreign viewer")} catch(_:IllegalArgumentException) {}
            try {f.store.relationshipWindow(f.actor,request,RelationshipAnchor(users[3],1000),3);fail("invalid preceding count")} catch(_:IllegalArgumentException) {}
            try {f.store.relationshipWindow(f.actor,request.copy(cursor=head.page.next),RelationshipAnchor(users[3],1000),1);fail("ambiguous cursor and anchor")} catch(_:IllegalArgumentException) {}
        } finally {f.close()}
    }

}

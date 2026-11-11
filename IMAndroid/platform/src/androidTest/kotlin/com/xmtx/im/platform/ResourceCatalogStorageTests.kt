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

class ResourceCatalogStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val actor=UserId(id());private val device=DeviceId(id());private val room=RoomId(id());private val message=MessageId(id())
    private val first=id();private val second=id()
    private fun store()=SqliteClientStore(context,actor,device)
    private suspend fun ready(store: SqliteClientStore,revision: Long=1)=store.acceptState(room,RoomSyncState.newBuilder().setHead(100).setViewerMembershipRevision(revision).build())
    private fun descriptor(media: String=first,name: String="图片.png",revision: Long=1)=ResourceDescriptor(ResourceKey(ResourceHome.Room(room),media),revision,name,"image/png",100,ResourceChecksum("a".repeat(64)),ResourceState.Ready,20,20)
    private fun item(media: String=first,sequence: Long=10,ordinal: Int=0,revision: Long=1,msg: MessageId=message,descriptor: ResourceDescriptor=descriptor(media))=
        RoomResourceItem(msg,revision,RoomResourcePosition(sequence,ordinal,media),1000,descriptor)
    private fun page(vararg items: RoomResourceItem,upper: Long=100,cursor: String?=null)=RoomResourcePage(items.sortedByDescending { it.position }.toPersistentList(),upper,cursor)
    private suspend fun catalog(store: SqliteClientStore,vararg items: RoomResourceItem) {
        val scan=store.beginResourceDirectoryScan(room);store.applyResourceDirectoryPage(scan,page(*items))
    }
    private fun accepted(revision: Long=1,vararg descriptors: ResourceDescriptor)=buildJsonObject {
        MessageRichContent.Empty.payload().forEach { (k,v)->put(k,v) }
        put("event_type","message.accepted");put("message_id",message.value);put("room_id",room.value);put("sender_user_id",actor.value)
        put("message_revision",revision);put("room_sequence",1);put("timeline_sequence",1);put("server_created_at_ms",1000);put("text","body")
        MessageMedia(descriptors.map { it.key.media }.toPersistentList(),descriptors.map { MessageMediaPresentation(it.key.media,MessageMediaKind.forContentType(it.contentType),it.contentType,it.byteCount,it) }.toPersistentList()).payload().forEach { (k,v)->put(k,v) }
    }
    private fun edit(revision: Long,type: String="message.edited",replacement: JsonObject?=null)=buildJsonObject {
        put("event_type",type);put("room_id",room.value);put("message_id",message.value);put("message_revision",revision);put("text","edited")
        replacement?.let { put("replacement",buildJsonObject { put("schema_version",1);put("accepted_membership_revision",1);put("accepted_event_id",id());put("state",it) }) }
    }
    private suspend fun apply(store: SqliteClientStore,value: JsonObject) {
        val cursor=store.roomCursor(room);val next=cursor.sequence+1
        store.commitRoom(GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(next).addEvents(GroupEvent.newBuilder().setRoomSequence(next).setSourceEventId(id()).setProjectionKind("message").setPayload(ByteString.copyFromUtf8(value.toString()))).build(),cursor)
    }
    private suspend fun conflict(body: suspend ()->Unit) {
        try { body();fail("stale or conflicting facts accepted") } catch(_: ResourceCatalogConflict) { }
    }
    private fun database(block: (SQLiteDatabase)->Unit) {
        val digest=MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") { "%02x".format(it) }
        SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$digest.db").path,null,SQLiteDatabase.OPEN_READWRITE).use(block)
    }
    @Test fun liveMessagesIndexOrderedSourcesAndEditsReplacementAndWithdrawalStayAtomic()=runBlocking {
        var store=store();try {
            ready(store);apply(store,accepted(1,descriptor(),descriptor(second)))
            assertEquals(2,store.resourceDirectory().entries.size)
            val source=store.resourceSources(descriptor().key).sources.single();assertEquals(0,source.ordinal);assertTrue(store.containsResourceSource(descriptor().key,source))
            store.close();store=store();apply(store,edit(2))
            assertFalse(store.containsResourceSource(descriptor().key,source));assertEquals(2L,store.resourceSources(descriptor().key).sources.single().revision)
            apply(store,edit(3,replacement=accepted(3,descriptor(second))))
            assertEquals(listOf(second),store.resourceDirectory().entries.map { it.descriptor.key.media });assertTrue(store.resourceSources(descriptor().key).sources.isEmpty())
            apply(store,edit(4,"message.withdrawn"));assertTrue(store.resourceDirectory().entries.isEmpty())
            catalog(store,item(revision=99));assertTrue(store.resourceDirectory().entries.isEmpty())
        } finally { store.close() }
    }
    @Test fun retainedFilteringPrecedesPaginationAndDoesNotPinOtherResourcesWithSharedBytes()=runBlocking {
        val store=store();val files=ManagedResourceFiles(context,store)
        try {
            catalog(store,item(),item(second,9,1))
            val entries=store.resourceDirectory().entries
            val last=entries.last().descriptor.key
            files.setResourceRetained(ResourceVariantKey(last),true)
            val page=store.resourceDirectory(ResourceCatalogQuery(limit=1,retainedOnly=true))
            assertEquals(last,page.entries.single().descriptor.key);assertTrue(page.entries.single().retained);assertNull(page.nextCursor)
            assertEquals(1,store.resourceDirectory().entries.count {it.retained})
            assertTrue(store.resourceDirectory(ResourceCatalogQuery(category=ResourceCategory.File,retainedOnly=true)).entries.isEmpty())
            assertTrue(store.resourceDirectory(ResourceCatalogQuery(search="absent",retainedOnly=true)).entries.isEmpty())
            files.setResourceRetained(ResourceVariantKey(entries.first().descriptor.key),true)
            val firstPage=store.resourceDirectory(ResourceCatalogQuery(limit=1,retainedOnly=true))
            val secondPage=store.resourceDirectory(ResourceCatalogQuery(before=firstPage.nextCursor,limit=1,retainedOnly=true))
            assertEquals(entries.map {it.descriptor.key},(firstPage.entries+secondPage.entries).map {it.descriptor.key})
            store.unavailable(room);assertTrue(store.resourceDirectory(ResourceCatalogQuery(retainedOnly=true)).entries.isEmpty())
        } finally {files.close();store.close()}
    }
    @Test fun detailReadsBindVariantsAndPagedSourcesToTheSameVisibleResource()=runBlocking {
        val store=store();val files=ManagedResourceFiles(context,store);val key=descriptor().key
        try {
            catalog(store,item(),item(sequence=9,msg=MessageId(id())))
            files.setResourceRetained(ResourceVariantKey(key),true)
            val detail=requireNotNull(store.resourceDetails(key,limit=1))
            assertEquals(descriptor(),detail.descriptor);assertTrue(detail.variants.single().retained)
            assertFalse(detail.variants.single().availableLocally);assertEquals(1,detail.sources.sources.size)
            val next=requireNotNull(store.resourceDetails(key,detail.sources.nextCursor,1))
            assertNotEquals(detail.sources.sources,next.sources.sources);assertNull(next.sources.nextCursor)
            store.unavailable(room);assertNull(store.resourceDetails(key));files.setResourceRetained(ResourceVariantKey(key),false)
        } finally {files.close();store.close()}
    }
    @Test fun legacyCatalogMigrationPreservesOriginalRetentionAndSources()=runBlocking {
        var store=store();var files=ManagedResourceFiles(context,store);val key=descriptor().key
        try {
            catalog(store,item());files.setResourceRetained(ResourceVariantKey(key),true);files.close();store.close()
            database {db->
                db.execSQL("ALTER TABLE resource_catalog_entries RENAME TO catalog_new")
                db.execSQL("CREATE TABLE resource_catalog_entries(home_kind TEXT NOT NULL,home TEXT NOT NULL,media TEXT NOT NULL,descriptor TEXT NOT NULL,revision INTEGER NOT NULL,name TEXT NOT NULL,kind TEXT NOT NULL,indexed_at INTEGER NOT NULL,PRIMARY KEY(home_kind,home,media))")
                db.execSQL("INSERT INTO resource_catalog_entries SELECT home_kind,home,media,descriptor,revision,name,kind,indexed_at FROM catalog_new")
                db.execSQL("DROP TABLE catalog_new")
            }
            store=store();files=ManagedResourceFiles(context,store)
            assertEquals(key,store.resourceDirectory(ResourceCatalogQuery(retainedOnly=true)).entries.single().descriptor.key)
            assertTrue(requireNotNull(store.resourceDetails(key)).variants.single().retained)
            assertEquals(message,store.resourceSources(key).sources.single().message)
        } finally {files.close();store.close()}
    }
    @Test fun scansResumeAcrossReopenAndRejectReplayDifferentUpperAndOverlappingPages()=runBlocking {
        var store=store();try {
            val start=store.beginResourceDirectoryScan(room,RoomResourceQuery(limit=1))
            val next=store.applyResourceDirectoryPage(start,page(item(sequence=10),cursor="opaque-next"))
            store.close();store=store();assertEquals(next,store.resourceDirectoryScan(room))
            conflict { store.applyResourceDirectoryPage(start,page(item(sequence=10),cursor="opaque-next")) }
            conflict { store.applyResourceDirectoryPage(next,page(item(second,9,1),upper=101)) }
            conflict { store.applyResourceDirectoryPage(next,page(item(second,10,1))) }
            assertEquals(next,store.resourceDirectoryScan(room));assertEquals(1,store.resourceDirectory().entries.size)
            val finished=store.applyResourceDirectoryPage(next,page(item(second,9,1)));assertTrue(finished.finished)
            conflict { store.applyResourceDirectoryPage(finished,page()) };assertEquals(2,store.resourceDirectory().entries.size)
        } finally { store.close() }
    }
    @Test fun aPageConflictRollsBackAllDescriptorsBindingsAndContinuation()=runBlocking {
        val store=store();try {
            catalog(store,item())
            val scan=store.beginResourceDirectoryScan(room)
            val changed=descriptor(revision=2).copy(byteCount=101)
            conflict { store.applyResourceDirectoryPage(scan,page(item(second,20,1),item(sequence=10,descriptor=changed))) }
            assertEquals(scan,store.resourceDirectoryScan(room));assertEquals(listOf(first),store.resourceDirectory().entries.map { it.descriptor.key.media })
            assertTrue(store.resourceSources(descriptor(second).key).sources.isEmpty())
        } finally { store.close() }
    }
    @Test fun localRevisionAndRoomRevocationRejectLatePagesAndRejoinCannotRestoreOldUnknownSources()=runBlocking {
        val store=store();try {
            ready(store);catalog(store,item())
            val old=store.beginResourceDirectoryScan(room)
            store.unavailable(room);assertTrue(store.resourceDirectory().entries.isEmpty())
            conflict { store.applyResourceDirectoryPage(old,page(item())) }
            ready(store,2)
            catalog(store) // A fresh empty response must not restore a pre-revocation source.
            assertTrue(store.resourceDirectory().entries.isEmpty())
            catalog(store,item());assertEquals(1,store.resourceDirectory().entries.size)
            val late=store.beginResourceDirectoryScan(room)
            apply(store,accepted(1,descriptor()));apply(store,edit(2))
            conflict { store.applyResourceDirectoryPage(late,page(item())) }
            assertNull(store.resourceDirectoryScan(room));assertEquals(2L,store.resourceSources(descriptor().key).sources.single().revision)
        } finally { store.close() }
    }
    @Test fun denialFencesEveryFilterAndOnlyFreshlyValidatedUnknownSourcesReturn()=runBlocking {
        val store=store();try {
            catalog(store,item(),item(second,9,1))
            val image=store.beginResourceDirectoryScan(room,RoomResourceQuery(ResourceCategory.Image))
            val all=store.beginResourceDirectoryScan(room)
            store.denyResourceDirectory(image);assertTrue(store.resourceDirectory().entries.isEmpty())
            conflict { store.applyResourceDirectoryPage(all,page(item())) }
            conflict { store.denyResourceDirectory(all) }
            catalog(store,item());assertEquals(listOf(first),store.resourceDirectory().entries.map { it.descriptor.key.media })
        } finally { store.close() }
    }
    @Test fun snapshotPrevalidationRollsBackEpochButActivationRequiresFreshSourceEvidence()=runBlocking {
        val store=store();try {
            catalog(store,item());val old=store.beginResourceDirectoryScan(room)
            store.validateSnapshot(persistentListOf());assertEquals(old,store.resourceDirectoryScan(room));assertEquals(1,store.resourceDirectory().entries.size)
            store.activateFixture(SnapshotManifest.newBuilder().setGeneration(2).setBaseUserSyncSequence(0).setNextSyncToken("snapshot").build(),persistentListOf())
            assertTrue(store.resourceDirectory().entries.isEmpty());conflict { store.applyResourceDirectoryPage(old,page(item())) }
            catalog(store,item());assertEquals(1,store.resourceDirectory().entries.size)
        } finally { store.close() }
    }
    @Test fun literalSearchKeysetPaginationAndMetadataUpdatePreserveFirstIndexTime()=runBlocking {
        val store=store();try {
            catalog(store,item(descriptor=descriptor(name="literal%_name.png")),item(second,9,1,descriptor=descriptor(second,"ordinary.png")))
            assertEquals(listOf(first),store.resourceDirectory(ResourceCatalogQuery(search="%_")).entries.map { it.descriptor.key.media })
            assertTrue(store.resourceDirectory(ResourceCatalogQuery(category=ResourceCategory.Audio)).entries.isEmpty())
            val initial=store.resourceDirectory(ResourceCatalogQuery(limit=1));val next=store.resourceDirectory(ResourceCatalogQuery(before=initial.nextCursor,limit=1))
            assertEquals(2,(initial.entries+next.entries).map { it.descriptor.key }.toSet().size);assertNull(next.nextCursor)
            catalog(store,item(descriptor=descriptor(name="renamed.png",revision=2)).copy(createdAt=9999))
            val renamed=store.resourceDirectory(ResourceCatalogQuery(search="renamed")).entries.single();assertEquals(1000L,renamed.indexedAt);assertEquals(2L,renamed.descriptor.revision)
        } finally { store.close() }
    }
    @Test fun multipleMessageSourcesAreCountedPagedAndCheckedAtTheExactRevision()=runBlocking {
        val store=store();try {
            val other=MessageId(id());catalog(store,item(),item(sequence=9,msg=other))
            assertEquals(2,store.resourceDirectory().entries.single().referenceCount)
            val firstPage=store.resourceSources(descriptor().key,limit=1);val last=store.resourceSources(descriptor().key,firstPage.nextCursor,1)
            assertEquals(setOf(message,other),(firstPage.sources+last.sources).map { it.message }.toSet());assertNull(last.nextCursor)
            assertTrue(store.containsResourceSource(descriptor().key,last.sources.single()));assertFalse(store.containsResourceSource(descriptor().key,last.sources.single().copy(revision=2)))
            ready(store);apply(store,edit(2,"message.withdrawn"));assertEquals(1,store.resourceDirectory().entries.single().referenceCount)
        } finally { store.close() }
    }
    @Test fun legacyProjectionBackfillIsBoundedDurableAndAdvertisesIncompleteIndexing()=runBlocking {
        var store=store();try {
            ready(store);apply(store,accepted(1,descriptor()))
            apply(store,JsonObject(accepted(1,descriptor(second)) + mapOf("message_id" to JsonPrimitive(id()),"room_sequence" to JsonPrimitive(2),"timeline_sequence" to JsonPrimitive(2))))
            store.close()
            database { db ->
                for(table in listOf("resource_catalog_entries","resource_catalog_sources","resource_message_media","resource_catalog_jobs")) db.execSQL("DELETE FROM $table")
                db.execSQL("DELETE FROM projection_migrations WHERE name='resource_catalog_v1'")
            }
            store=store();val before=store.resourceDirectory();assertTrue(before.isIndexing);assertTrue(before.entries.isEmpty())
            store.close();store=store();assertTrue(store.indexResourceProjectionBatch(1))
            assertTrue(store.resourceDirectory().isIndexing);assertEquals(1,store.resourceDirectory().entries.size)
            store.close();store=store();assertFalse(store.indexResourceProjectionBatch(1))
            assertFalse(store.resourceDirectory().isIndexing);assertEquals(2,store.resourceDirectory().entries.size)
        } finally { store.close() }
    }
    @Test fun unknownLegacyMediaHidesSourcesUntilCompleteSameRevisionStateReturns()=runBlocking {
        var store=store();try {
            ready(store);apply(store,accepted(1,descriptor()));val source=store.resourceSources(descriptor().key).sources.single()
            store.close();database { db ->
                db.execSQL("UPDATE messages SET media=NULL WHERE id=?",arrayOf(message.value))
                db.execSQL("INSERT INTO resource_catalog_jobs VALUES(?,?)",arrayOf(message.value,room.value))
            }
            store=store();assertTrue(store.resourceDirectory().entries.isEmpty());assertFalse(store.containsResourceSource(descriptor().key,source))
            store.indexResourceProjectionBatch();assertTrue(store.resourceDirectory().entries.isEmpty())
            apply(store,edit(1,replacement=accepted(1,descriptor())))
            assertEquals(1,store.resourceDirectory().entries.size);assertTrue(store.containsResourceSource(descriptor().key,source))
        } finally { store.close() }
    }
    @Test fun immutableResourceIdentityConflictRollsBackTheMessageAndRoomCursor()=runBlocking {
        val store=store();try {
            ready(store);apply(store,accepted(1,descriptor()))
            val cursor=store.roomCursor(room)
            conflict { apply(store,edit(2,replacement=accepted(2,descriptor(revision=2).copy(checksum=ResourceChecksum("b".repeat(64)))))) }
            assertEquals(cursor,store.roomCursor(room));assertEquals(1L,store.snapshot().messages.single().revision)
            assertEquals(descriptor(),store.resourceDirectory().entries.single().descriptor)
        } finally { store.close() }
    }
    @Test fun supersededScanCannotDenyNewResultsAndRoomDirectoryRemovalHidesRemoteOnlySources()=runBlocking {
        val store=store();try {
            val old=store.beginResourceDirectoryScan(room);val current=store.beginResourceDirectoryScan(room)
            conflict { store.denyResourceDirectory(old) };store.applyResourceDirectoryPage(current,page(item()))
            store.reconcileDirectory(persistentMapOf());assertTrue(store.resourceDirectory().entries.isEmpty())
            val other=RoomId(id());val stable=store.beginResourceDirectoryScan(other)
            store.reconcileDirectory(persistentMapOf(other to RoomKind.Group))
            assertEquals(stable,store.resourceDirectoryScan(other)) // Already denied rooms do not churn every unrelated scan.
        } finally { store.close() }
    }
}

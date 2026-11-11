package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class AvatarResourceSelectionStorageTests {
    private fun id()=UUID.randomUUID().toString().uppercase()
    private inner class Fixture {
        val actor=UserId(id());val device=DeviceId(id());val room=RoomId(id());val message=MessageId(id());val now=1700000000000L
        var store=SqliteClientStore(InstrumentationRegistry.getInstrumentation().targetContext,actor,device)
        val baseline=ProfileView(actor,PublicIdentity(actor,PublicHandle("selected_avatar"),"本人",AccountKind.Regular),null,ProfileState.Active,1,1)
        val descriptor=ResourceDescriptor(ResourceKey(ResourceHome.Room(room),id()),1,"聊天原图.png","image/png",1024,ResourceChecksum("a".repeat(64)),ResourceState.Ready,32,32)
        fun service()=AvatarResourceSelectionService(actor,store) { now }
        suspend fun start() { store.saveOwnProfile(baseline);store.acceptState(room,RoomSyncState.newBuilder().setHead(100).setViewerMembershipRevision(1).build());index() }
        suspend fun index(value: ResourceDescriptor=descriptor,revision: Long=1) {
            val scan=store.beginResourceDirectoryScan(room)
            store.applyResourceDirectoryPage(scan,RoomResourcePage(persistentListOf(RoomResourceItem(message,revision,RoomResourcePosition(1,0,value.key.media),1000,value)),100,null))
        }
        suspend fun empty() { assertTrue(store.profileIntents().isEmpty());assertTrue(store.resourceImports().isEmpty());assertTrue(store.ownProfileWorks().isEmpty()) }
        suspend fun reopen() { store.close();store=SqliteClientStore(InstrumentationRegistry.getInstrumentation().targetContext,actor,device) }
        suspend fun withdraw() {
            val cursor=store.roomCursor(room)
            val payload=buildJsonObject { put("event_type","message.withdrawn");put("room_id",room.value);put("message_id",message.value);put("message_revision",2) }
            store.commitRoom(GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(cursor.sequence+1).addEvents(GroupEvent.newBuilder().setRoomSequence(cursor.sequence+1).setSourceEventId(id()).setProjectionKind("message").setPayload(ByteString.copyFromUtf8(payload.toString()))).build(),cursor)
        }
        fun intent(selection: AvatarResourceSelection)=ProfileIntent(id(),actor,id(),baseline.revision,now+86400000,serverImport=ProfileAvatarImport(id(),ResourceImportRequest(id(),selection.importSource,ResourceUsage.UserAvatar,id())))
    }
    private suspend fun Fixture.groupAuthority(target: RoomId=room): GroupAvatarEditAuthority {
        store.reconcileDirectory(kotlinx.collections.immutable.persistentMapOf(target to RoomKind.Group))
        store.acceptState(target,RoomSyncState.newBuilder().setHead(100).setViewerMembershipRevision(1).build())
        return GroupAvatarEditAuthority(GroupAvatarPresentation(actor,device,GroupAvatarState(target,null,0),1,null,true,null,
            now,now+300000,now,System.nanoTime()+300000000000L,null),store.groupAvatarFence(target))
    }
    @Test fun selectedGroupImportAtomicallyOwnsExactSourceAndBlocksPendingDuplicateAcrossReopen()=runBlocking {
        val f=Fixture();try {
            f.start();val authority=f.groupAuthority();val selection=f.store.selectAvatarResource(f.descriptor.key)
            val service=GroupAvatarResourceSelectionService(f.actor,f.device,f.store) { f.now }
            val intent=service.submit(authority,selection);f.reopen()
            assertEquals(intent,f.store.groupAvatarIntents().single())
            val work=f.store.resourceImports().single();assertEquals(selection.importSource,work.request.source)
            assertEquals(ResourceUsage.GroupAvatar(f.room),work.request.targetUsage);assertNotEquals(selection.key.media,work.request.targetMedia)
            fails { GroupAvatarResourceSelectionService(f.actor,f.device,f.store).submit(authority,selection) }
            assertEquals(1,f.store.groupAvatarIntents().size);assertEquals(1,f.store.resourceImports().size)
            fails { f.store.cancelResourceImport(work.id) }
        } finally { f.store.close() }
    }
    @Test fun selectedGroupImportRejectsWithdrawnOrChangedSourceAndStaleTargetFenceWithoutPartialJobs()=runBlocking {
        val f=Fixture();try {
            f.start();val authority=f.groupAuthority();val service=GroupAvatarResourceSelectionService(f.actor,f.device,f.store) { f.now }
            val selection=f.store.selectAvatarResource(f.descriptor.key)
            f.index(f.descriptor.copy(revision=2));fails { service.submit(authority,selection) }
            val current=f.store.selectAvatarResource(f.descriptor.key)
            f.store.acceptState(f.room,RoomSyncState.newBuilder().setHead(100).setViewerMembershipRevision(2).build())
            fails { service.submit(authority,current) }
            f.withdraw();fails { service.submit(authority,current) }
            assertTrue(f.store.groupAvatarIntents().isEmpty());assertTrue(f.store.resourceImports().isEmpty())
        } finally { f.store.close() }
    }
    @Test fun selectedGroupImportCannotSubstituteSourceTargetOrIdentity()=runBlocking {
        val f=Fixture();try {
            f.start();val authority=f.groupAuthority();val selection=f.store.selectAvatarResource(f.descriptor.key)
            val source=GroupAvatarImportPreparation(id(),ResourceImportRequest(id(),selection.importSource,ResourceUsage.GroupAvatar(f.room),id()))
            val command=GroupAvatarCommand(id(),f.room,0,GroupAvatarMutation.Set(source.request.targetMedia))
            fails { f.store.enqueueSelectedGroupAvatar(authority,command,source.copy(request=source.request.copy(source=ResourceImportSource.Message(f.room,MessageId(id()),selection.key.media))),selection,f.now) }
            fails { f.store.enqueueSelectedGroupAvatar(authority,command,source.copy(request=source.request.copy(targetUsage=ResourceUsage.GroupAvatar(RoomId(id())))),selection,f.now) }
            fails { GroupAvatarResourceSelectionService(UserId(id()),f.device,f.store).submit(authority,selection) }
            fails { GroupAvatarResourceSelectionService(f.actor,DeviceId(id()),f.store).submit(authority,selection) }
            fails { GroupAvatarResourceSelectionService(f.actor,f.device,f.store).submit(authority.copy(presentation=authority.presentation.copy(canManage=false)),selection) }
            assertTrue(f.store.groupAvatarIntents().isEmpty());assertTrue(f.store.resourceImports().isEmpty())
        } finally { f.store.close() }
    }
    private suspend fun fails(body: suspend ()->Unit) { assertNotNull(runCatching { body() }.exceptionOrNull()) }
    @Test fun explicitMessageSelectionNeverSubstitutesAnotherVisibleSource()=runBlocking {
        val f=Fixture();try {
            f.start();val other=MessageId(id());val scan=f.store.beginResourceDirectoryScan(f.room)
            f.store.applyResourceDirectoryPage(scan,RoomResourcePage(persistentListOf(
                RoomResourceItem(other,1,RoomResourcePosition(2,0,f.descriptor.key.media),2000,f.descriptor),
                RoomResourceItem(f.message,1,RoomResourcePosition(1,0,f.descriptor.key.media),1000,f.descriptor)),100,null))
            val original=f.store.selectMessageResource(f.descriptor.key,MediaMessageLocation(f.room,f.message))
            val duplicate=f.store.selectMessageResource(f.descriptor.key,MediaMessageLocation(f.room,other))
            assertEquals(f.message,original.source.message);assertEquals(other,duplicate.source.message)
            f.withdraw();fails { f.store.selectMessageResource(f.descriptor.key,MediaMessageLocation(f.room,f.message)) }
            assertEquals(other,f.store.selectMessageResource(f.descriptor.key,MediaMessageLocation(f.room,other)).source.message)
            fails { f.store.selectMessageResource(f.descriptor.key,MediaMessageLocation(RoomId(id()),other)) }
        } finally { f.store.close() }
    }
    @Test fun readEvidenceSurvivesReopenButMetadataAndSourceChangesInvalidateItsGeneration()=runBlocking {
        val f=Fixture();try {
            f.start();val read=f.store.selectMessageResource(f.descriptor.key);val generation=f.store.resourceReadGeneration()
            assertEquals(generation,read.generation);assertTrue(f.store.isMessageResourceCurrent(read))
            f.store.saveOwnProfile(f.baseline);assertEquals(generation,f.store.resourceReadGeneration())
            f.reopen();assertEquals(generation,f.store.resourceReadGeneration());assertTrue(f.store.isMessageResourceCurrent(read))
            f.index(f.descriptor.copy(revision=2,displayName="重新命名.png"))
            assertNotEquals(generation,f.store.resourceReadGeneration());assertFalse(f.store.isMessageResourceCurrent(read))
            val next=f.store.selectMessageResource(f.descriptor.key);assertTrue(f.store.isMessageResourceCurrent(next))
            f.withdraw();assertFalse(f.store.isMessageResourceCurrent(next));f.empty()
        } finally { f.store.close() }
    }
    @Test fun deniedAndReauthorizedIdenticalMessageNeverRevivesOldReadEvidence()=runBlocking {
        val f=Fixture();try {
            f.start();val read=f.store.selectMessageResource(f.descriptor.key)
            f.store.denyResourceDirectory(f.store.beginResourceDirectoryScan(f.room));assertFalse(f.store.isMessageResourceCurrent(read))
            f.store.acceptState(f.room,RoomSyncState.newBuilder().setHead(100).setViewerMembershipRevision(1).build());f.index()
            val fresh=f.store.selectMessageResource(f.descriptor.key)
            assertEquals(read.descriptor,fresh.descriptor);assertEquals(read.source,fresh.source);assertNotEquals(read.generation,fresh.generation)
            assertTrue(f.store.isMessageResourceCurrent(fresh));assertFalse(f.store.isMessageResourceCurrent(read));f.empty()
        } finally { f.store.close() }
    }
    @Test fun selectionIsReadOnlyAndAdmissionPersistsOneImportAndItsConsumerAcrossReopen()=runBlocking {
        val f=Fixture();try {
            f.start();val selection=f.service().select(f.descriptor.key);assertEquals(f.descriptor,selection.descriptor);f.empty()
            val intent=f.service().submit(f.baseline,selection);f.reopen()
            assertEquals(intent,f.store.profileIntents().single().intent)
            val work=f.store.resourceImports().single();assertEquals(intent.serverImport!!.id,work.id)
            assertEquals(selection.importSource,work.request.source);assertEquals(ResourceUsage.UserAvatar,work.request.targetUsage)
            assertNotEquals(f.descriptor.key.media,work.request.targetMedia)
            // A persisted consumer owns the task; independent cancellation is not permitted.
            fails { f.store.cancelResourceImport(work.id) }
            assertTrue(f.store.ownProfileWorks().isEmpty())
        } finally { f.store.close() }
    }
    @Test fun withdrawalAndDirectoryDenialInvalidatePreviouslyChosenSourcesWithoutCreatingTasks()=runBlocking {
        for(withdraw in listOf(true,false)) {
            val f=Fixture();try {
                f.start();val selected=f.service().select(f.descriptor.key)
                if(withdraw) f.withdraw() else f.store.denyResourceDirectory(f.store.beginResourceDirectoryScan(f.room))
                assertFalse(f.service().isCurrent(selected));fails { f.service().submit(f.baseline,selected) };f.empty()
                fails { f.service().select(f.descriptor.key) }
            } finally { f.store.close() }
        }
    }
    @Test fun metadataAndSourceRevisionChangesRequireExplicitReselection()=runBlocking {
        for(metadata in listOf(true,false)) {
            val f=Fixture();try {
                f.start();val selected=f.service().select(f.descriptor.key)
                f.index(if(metadata) f.descriptor.copy(revision=2,displayName="更新后的名称.png") else f.descriptor,if(metadata) 1 else 2)
                assertFalse(f.service().isCurrent(selected));fails { f.service().submit(f.baseline,selected) };f.empty()
                val fresh=f.service().select(f.descriptor.key);assertNotEquals(selected,fresh)
                f.service().submit(f.baseline,fresh);assertEquals(1,f.store.profileIntents().size)
            } finally { f.store.close() }
        }
    }
    @Test fun changedBaselineOrMismatchedImportContextLeavesNoOrphanWork()=runBlocking {
        val f=Fixture();try {
            f.start();val selected=f.service().select(f.descriptor.key)
            val intent=f.intent(selected);val imported=intent.serverImport!!
            fails { f.store.enqueueSelectedProfileAvatar(intent.copy(serverImport=imported.copy(request=imported.request.copy(source=ResourceImportSource.Message(f.room,MessageId(id()),f.descriptor.key.media)))),selected,f.now) };f.empty()
            f.store.saveOwnProfile(f.baseline.copy(revision=2,visibilityRevision=2))
            fails { f.service().submit(f.baseline,selected) };f.empty()
            f.service().submit(f.baseline.copy(revision=2,visibilityRevision=2),selected)
            assertEquals(2L,f.store.profileIntents().single().intent.revision)
        } finally { f.store.close() }
    }
    @Test fun simultaneousConfirmationAdmitsExactlyOneConsumerAndRejectsPendingProfileWork()=runBlocking {
        val f=Fixture();try {
            f.start();val selected=f.service().select(f.descriptor.key)
            val results=List(2) { async(Dispatchers.Default) { runCatching { f.service().submit(f.baseline,selected) } } }.awaitAll()
            assertEquals(1,results.count { it.isSuccess });assertEquals(1,f.store.profileIntents().size);assertEquals(1,f.store.resourceImports().size)
        } finally { f.store.close() }
        val g=Fixture();try {
            g.start();val selected=g.service().select(g.descriptor.key)
            g.store.enqueueOwnProfile(OwnProfileCommand(g.actor,id(),1,OwnProfilePatch(name="待确认"),g.now+86400000))
            fails { g.service().submit(g.baseline,selected) };assertTrue(g.store.profileIntents().isEmpty());assertTrue(g.store.resourceImports().isEmpty())
        } finally { g.store.close() }
    }
    @Test fun ineligibleCatalogDescriptorsCannotBecomeAvatarSelections()=runBlocking {
        for(type in listOf("image/gif","video/mp4","image/png")) {
            val f=Fixture();try {
                f.store.acceptState(f.room,RoomSyncState.newBuilder().setHead(100).setViewerMembershipRevision(1).build())
                f.index(f.descriptor.copy(contentType=type,byteCount=if(type=="image/png") 50L*1024*1024+1 else 1024))
                fails { f.service().select(f.descriptor.key) };f.empty()
            } finally { f.store.close() }
        }
    }
}

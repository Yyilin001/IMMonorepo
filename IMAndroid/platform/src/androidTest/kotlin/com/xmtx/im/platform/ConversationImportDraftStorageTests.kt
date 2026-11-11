package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.RoomSyncState
import kotlinx.collections.immutable.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID
import java.io.File

class ConversationImportDraftStorageTests {
    private fun id()=UUID.randomUUID().toString().uppercase()
    private inner class Fixture {
        val context=InstrumentationRegistry.getInstrumentation().targetContext;val actor=UserId(id());val device=DeviceId(id())
        val room=RoomId(id());val sourceRoom=RoomId(id());val message=MessageId(id());val now=1700000000000L
        var store=SqliteClientStore(context,actor,device);var files=ManagedResourceFiles(context,store)
        val descriptor=ResourceDescriptor(ResourceKey(ResourceHome.Room(sourceRoom),id()),1,"原文件.txt","text/plain",100,ResourceChecksum("a".repeat(64)),ResourceState.Ready)
        suspend fun start() {
            store.reconcileDirectory(persistentMapOf(room to RoomKind.Group,sourceRoom to RoomKind.Group))
            for(r in listOf(room,sourceRoom)) store.acceptState(r,RoomSyncState.newBuilder().setHead(100).setViewerMembershipRevision(1).build())
            index()
        }
        suspend fun index(value: ResourceDescriptor=descriptor) {
            val scan=store.beginResourceDirectoryScan(sourceRoom)
            store.applyResourceDirectoryPage(scan,RoomResourcePage(persistentListOf(RoomResourceItem(message,1,RoomResourcePosition(1,0,value.key.media),1000,value)),100,null))
        }
        suspend fun imported(): ConversationImportedAttachment {val service=ConversationResourceSelectionService(store);return service.prepare(room,service.select(descriptor.key))}
        suspend fun local(): SendAttachment {
            val file=File.createTempFile("draft-import-",".txt",context.cacheDir)
            try {file.writeText("local");val asset=files.importFile(file,"local.txt","text/plain",ResourceUsage.Attachment(room),1024);return SendAttachment(asset.id,asset.id,asset.displayName,asset.contentType,asset.byteCount)} finally {file.delete()}
        }
        suspend fun reopen() {files.close();store.close();store=SqliteClientStore(context,actor,device);files=ManagedResourceFiles(context,store)}
        suspend fun close() {files.close();store.close()}
        fun intent(draft: ConversationDraft)=SendIntentService(actor,store) {now}.prepareDraft(draft)
    }
    private suspend fun fails(body: suspend ()->Unit) {assertTrue(runCatching {body()}.isFailure)}
    @Test fun mixedDraftRestoresReordersAndFreezesDependenciesOnlyWhenSent()=runBlocking {
        val f=Fixture();try {
            f.start();val local=f.local();var draft=f.store.addConversationAttachment(f.room,local,f.now);val remote=f.imported()
            draft=f.store.addConversationImport(draft,remote,f.now);draft=f.store.reorderConversationResources(draft,persistentListOf(remote.id,local.id),f.now)
            assertTrue(f.store.resourceImports().isEmpty());assertTrue(f.store.sendIntents().isEmpty());f.reopen();assertEquals(draft,f.store.conversationDraft(f.room))
            val frozen=f.intent(draft);f.store.submitConversationDraft(draft,frozen,f.now)
            assertEquals(persistentListOf(remote.transfer.request.targetMedia,local.id),f.store.sendIntents().single().intent.mediaIds)
            assertEquals(remote.transfer.request,f.store.resourceImports().single().request);assertTrue(f.store.conversationDraft(f.room).empty)
            f.store.denyResourceDirectory(f.store.beginResourceDirectoryScan(f.sourceRoom));f.reopen()
            assertEquals(frozen,f.store.submitConversationDraft(draft,frozen,f.now));assertEquals(1,f.store.resourceImports().size)
            fails {f.store.cancelResourceImport(remote.id)}
        } finally {f.close()}
    }
    @Test fun changedOrRevokedSourceRejectsSendAtomicallyAndLeavesEditableDraft()=runBlocking {
        val f=Fixture();try {
            f.start();val local=f.local();var draft=f.store.addConversationAttachment(f.room,local,f.now)
            val remote=f.imported();draft=f.store.addConversationImport(draft,remote,f.now);f.index(f.descriptor.copy(revision=2))
            fails {f.store.submitConversationDraft(draft,f.intent(draft),f.now)}
            assertEquals(draft,f.store.conversationDraft(f.room));assertTrue(f.store.resourceImports().isEmpty());assertTrue(f.store.resourceUploads().isEmpty());assertTrue(f.store.sendIntents().isEmpty())
            draft=f.store.removeConversationImport(draft,remote.id,f.now);val fresh=f.imported();draft=f.store.addConversationImport(draft,fresh,f.now)
            f.store.denyResourceDirectory(f.store.beginResourceDirectoryScan(f.sourceRoom));fails {f.store.submitConversationDraft(draft,f.intent(draft),f.now)}
            assertTrue(f.store.resourceImports().isEmpty());assertEquals(draft,f.store.conversationDraft(f.room))
        } finally {f.close()}
    }
    @Test fun lostLocalAddConfirmationIsIdempotentAndRemovalNeverCreatesOrCancelsATransfer()=runBlocking {
        val f=Fixture();try {
            f.start();val initial=f.store.conversationDraft(f.room);val remote=f.imported();val added=f.store.addConversationImport(initial,remote,f.now)
            val edited=f.store.saveConversationText(added,"更新的文字",f.now);f.reopen()
            assertEquals(edited,f.store.addConversationImport(initial,remote,f.now));assertTrue(f.store.resourceImports().isEmpty())
            fails {f.store.removeConversationImport(added,remote.id,f.now)}
            val removed=f.store.removeConversationImport(edited,remote.id,f.now);assertEquals("更新的文字",removed.text);assertTrue(removed.imports.isEmpty())
            assertTrue(f.store.resourceImports().isEmpty());assertTrue(f.store.resourceFiles().isEmpty())
        } finally {f.close()}
    }
    @Test fun pendingDraftCannotSmuggleTargetSourceOrAnOlderPermutationIntoSubmission()=runBlocking {
        val f=Fixture();try {
            f.start();val initial=f.store.conversationDraft(f.room);val first=f.imported();val second=f.imported()
            val one=f.store.addConversationImport(initial,first,f.now);val two=f.store.addConversationImport(one,second,f.now)
            fails {f.store.addConversationImport(initial,f.imported(),f.now)}
            val reordered=f.store.reorderConversationResources(two,persistentListOf(second.id,first.id),f.now)
            fails {f.store.submitConversationDraft(two,f.intent(two),f.now)}
            fails {f.store.submitConversationDraft(reordered,f.intent(reordered).copy(serverImports=persistentListOf(first.transfer)),f.now)}
            val wrong=first.copy(transfer=first.transfer.copy(request=first.transfer.request.copy(targetUsage=ResourceUsage.Attachment(RoomId(id())))))
            fails {f.store.addConversationImport(reordered,wrong.copy(transfer=wrong.transfer.copy(id=id())),f.now)}
            assertTrue(f.store.resourceImports().isEmpty());assertEquals(reordered,f.store.conversationDraft(f.room))
        } finally {f.close()}
    }
    @Test fun combinedCapacityAndTargetRevocationRejectAdmissionWithoutLosingExistingDraft()=runBlocking {
        val f=Fixture();try {
            f.start();var draft=f.store.conversationDraft(f.room)
            repeat(10) {draft=f.store.addConversationImport(draft,f.imported(),f.now)}
            fails {f.store.addConversationImport(draft,f.imported(),f.now)};assertEquals(draft,f.store.conversationDraft(f.room));assertTrue(f.store.resourceImports().isEmpty())
            val old=draft;draft=f.store.removeConversationImport(draft,draft.imports.first().id,f.now)
            f.store.unavailable(f.room);fails {f.store.addConversationImport(draft,f.imported(),f.now)};fails {f.store.submitConversationDraft(draft,f.intent(draft),f.now)}
            assertEquals(9,draft.imports.size);assertEquals(10,old.imports.size);assertEquals(draft,f.store.conversationDraft(f.room));assertTrue(f.store.resourceImports().isEmpty())
        } finally {f.close()}
    }
}

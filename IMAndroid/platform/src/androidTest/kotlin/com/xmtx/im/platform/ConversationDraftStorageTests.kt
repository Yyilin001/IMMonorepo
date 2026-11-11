package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class ConversationDraftStorageTests {
    private val context=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private inner class Fixture {
        val actor=UserId(id());val device=DeviceId(id());val room=RoomId(id());var now=1700000000000L
        var store=SqliteClientStore(context,actor,device);var files=ManagedResourceFiles(context,store)
        fun sends()=SendIntentService(actor,store) { now }
        suspend fun source(room: RoomId=this.room): SendAttachment {
            val file=File.createTempFile("composer-",".txt",context.cacheDir)
            try { file.writeText("草稿原件");val asset=files.importFile(file,"草稿.txt","text/plain",ResourceUsage.Attachment(room),1024)
                return SendAttachment(asset.id,asset.id,asset.displayName,asset.contentType,asset.byteCount)
            } finally { file.delete() }
        }
        suspend fun reopen() { files.close();store.close();store=SqliteClientStore(context,actor,device);files=ManagedResourceFiles(context,store) }
        suspend fun close() { files.close();store.close() }
    }
    private suspend fun fails(body: suspend ()->Unit) { assertNotNull(runCatching { body() }.exceptionOrNull()) }
    @Test fun textAndOrderedSelectionsRestoreAcrossAccountReopen()=runBlocking<Unit> {
        val f=Fixture();try {
            var draft=f.store.conversationDraft(f.room);draft=f.store.saveConversationText(draft,"  再次编辑\n草稿🙂  ",f.now)
            val first=f.source();draft=f.store.addConversationAttachment(f.room,first,f.now)
            val second=f.source();draft=f.store.addConversationAttachment(f.room,second,f.now)
            f.files.cleanup();assertEquals(1,f.store.resourceFiles().size);f.reopen()
            assertEquals(draft,f.store.conversationDraft(f.room));assertEquals(listOf(first,second),draft.attachments)
            assertEquals(2,f.files.selected(ResourceUsage.Attachment(f.room)).size)
        } finally { f.close() }
    }
    @Test fun publishedSelectionBeforeDraftAdoptionIsRecoveredExactlyOnce()=runBlocking<Unit> {
        val f=Fixture();try {
            val source=f.source();f.reopen();val recovered=f.store.conversationDraft(f.room)
            assertEquals(persistentListOf(source),recovered.attachments);assertEquals(recovered,f.store.conversationDraft(f.room))
            assertEquals(recovered,f.store.addConversationAttachment(f.room,source,f.now))
        } finally { f.close() }
    }
    @Test fun staleSaveOrRemovalCannotOverwriteNewerTextOrAttachments()=runBlocking<Unit> {
        val f=Fixture();try {
            val old=f.store.conversationDraft(f.room);val latest=f.store.saveConversationText(old,"更新的正文",f.now)
            assertTrue(runCatching { f.store.saveConversationText(old,"旧正文",f.now) }.exceptionOrNull() is ConversationDraftConflict)
            val source=f.source();val attached=f.store.addConversationAttachment(f.room,source,f.now)
            fails { f.store.removeConversationAttachment(latest,source.asset,f.now) }
            assertEquals(attached,f.store.conversationDraft(f.room));assertTrue(f.store.resourceOriginal(selection=source.asset).selectionActive)
        } finally { f.close() }
    }
    @Test fun atomicSendConsumesOnlyItsRevisionAndRetryKeepsTheNextDraft()=runBlocking<Unit> {
        val f=Fixture();try {
            val source=f.source();var draft=f.store.addConversationAttachment(f.room,source,f.now)
            draft=f.store.saveConversationText(draft,"  发送这一条  ",f.now)
            val intent=f.sends().prepare(f.room,draft.text.trim(),draft.attachments)
            assertEquals(intent,f.store.submitConversationDraft(draft,intent,f.now));val empty=f.store.conversationDraft(f.room)
            assertTrue(empty.empty);assertEquals(draft.revision+1,empty.revision);assertFalse(f.store.resourceAssets().single().selectionActive)
            var next=f.store.saveConversationText(empty,"下一条，不应被清空",f.now+1)
            val second=f.source();next=f.store.addConversationAttachment(f.room,second,f.now+1)
            f.reopen();assertEquals(intent,f.store.submitConversationDraft(draft,intent,f.now+2))
            assertEquals(next,f.store.conversationDraft(f.room));assertEquals(1,f.store.sendIntents().size);assertEquals(1,f.store.resourceUploads().size)
            fails { f.store.submitConversationDraft(draft,intent.copy(id=id(),operation=id()),f.now+2) }
            assertEquals(next,f.store.conversationDraft(f.room))
        } finally { f.close() }
    }
    @Test fun failedSubmissionRollsBackTheDraftAndAllOriginalOwnership()=runBlocking<Unit> {
        val f=Fixture();try {
            val source=f.source();val draft=f.store.addConversationAttachment(f.room,source,f.now)
            f.store.markResourceAssetUnavailable(source.asset)
            val error=runCatching { f.store.submitConversationDraft(draft,f.sends().prepare(f.room,"",draft.attachments),f.now) }.exceptionOrNull()
            assertTrue(error is ConversationDraftSubmissionRejected);assertEquals(draft,f.store.conversationDraft(f.room))
            assertTrue(f.store.sendIntents().isEmpty());assertTrue(f.store.resourceUploads().isEmpty());assertTrue(f.store.resourceAssets().single().selectionActive)
            val removed=f.store.removeConversationAttachment(draft,source.asset,f.now);assertTrue(removed.empty)
            f.files.cleanup();assertTrue(f.store.resourceFiles().isEmpty())
        } finally { f.close() }
    }
    @Test fun removalAndRoomOwnershipAreDurableAndCannotResurrectSelections()=runBlocking<Unit> {
        val f=Fixture();try {
            val source=f.source();val other=RoomId(id());fails { f.store.addConversationAttachment(other,source,f.now) }
            val draft=f.store.addConversationAttachment(f.room,source,f.now);val removed=f.store.removeConversationAttachment(draft,source.asset,f.now)
            f.files.cleanup();f.reopen();assertEquals(removed,f.store.conversationDraft(f.room));assertTrue(f.store.resourceFiles().isEmpty())
            assertTrue(f.store.conversationDraft(other).empty)
        } finally { f.close() }
    }
    @Test fun tenAttachmentLimitAndConcurrentNewEditRejectAnOldFrozenSend()=runBlocking<Unit> {
        val f=Fixture();try {
            repeat(10) { f.store.addConversationAttachment(f.room,f.source(),f.now) }
            val draft=f.store.conversationDraft(f.room);val extra=f.source();fails { f.store.addConversationAttachment(f.room,extra,f.now) }
            f.files.discardSelection(extra.asset)
            val frozen=f.sends().prepare(f.room,"",draft.attachments);val changed=f.store.saveConversationText(draft,"稍后再发",f.now+1)
            assertTrue(runCatching { f.store.submitConversationDraft(draft,frozen,f.now+1) }.exceptionOrNull() is ConversationDraftSubmissionRejected)
            assertEquals(changed,f.store.conversationDraft(f.room));assertTrue(f.store.sendIntents().isEmpty());assertEquals(10,f.files.selected(ResourceUsage.Attachment(f.room)).size)
        } finally { f.close() }
    }
    @Test fun reorderingPreservesOriginalOwnersAndTheOrderAfterReopen()=runBlocking<Unit> {
        val f=Fixture();try {
            val first=f.source();val second=f.source();val third=f.source();val before=f.store.conversationDraft(f.room)
            val order=persistentListOf(third.asset,first.asset,second.asset)
            val changed=f.store.reorderConversationAttachments(before,order,f.now)
            assertEquals(before.revision+1,changed.revision);assertEquals(listOf(third,first,second),changed.attachments)
            assertEquals(changed,f.store.reorderConversationAttachments(changed,order,f.now+1));f.reopen()
            assertEquals(changed,f.store.conversationDraft(f.room));assertEquals(3,f.files.selected(ResourceUsage.Attachment(f.room)).size);assertEquals(1,f.store.resourceFiles().size)
            val send=f.sends().prepare(f.room,"",changed.attachments);f.store.submitConversationDraft(changed,send,f.now)
            assertEquals(changed.attachments,f.store.sendIntents().single().intent.attachments)
        } finally { f.close() }
    }
    @Test fun staleOrInvalidPermutationNeverChangesTheLatestDraft()=runBlocking<Unit> {
        val f=Fixture();try {
            val first=f.source();val second=f.source();val before=f.store.conversationDraft(f.room)
            val latest=f.store.saveConversationText(before,"新正文",f.now)
            assertTrue(runCatching { f.store.reorderConversationAttachments(before,persistentListOf(second.asset,first.asset),f.now) }.exceptionOrNull() is ConversationDraftConflict)
            for(order in listOf(persistentListOf(first.asset),persistentListOf(first.asset,first.asset),persistentListOf(first.asset,id()))) fails { f.store.reorderConversationAttachments(latest,order,f.now) }
            assertEquals(latest,f.store.conversationDraft(f.room));assertEquals(2,f.files.selected(ResourceUsage.Attachment(f.room)).size)
        } finally { f.close() }
    }
    @Test fun anOldSendCannotBypassANewerAttachmentOrder()=runBlocking<Unit> {
        val f=Fixture();try {
            val first=f.source();val second=f.source();val before=f.store.conversationDraft(f.room);val old=f.sends().prepare(f.room,"",before.attachments)
            val changed=f.store.reorderConversationAttachments(before,persistentListOf(second.asset,first.asset),f.now)
            assertTrue(runCatching { f.store.submitConversationDraft(before,old,f.now) }.exceptionOrNull() is ConversationDraftSubmissionRejected)
            assertTrue(f.store.sendIntents().isEmpty());assertEquals(changed,f.store.conversationDraft(f.room))
        } finally { f.close() }
    }

    @Test fun frozenLocalDraftCannotSmuggleImportsOrAChangedAttachmentOrder()=runBlocking<Unit> {
        val f=Fixture();try {
            val first=f.source();f.store.addConversationAttachment(f.room,first,f.now)
            val second=f.source();val draft=f.store.addConversationAttachment(f.room,second,f.now)
            val valid=f.sends().prepare(f.room,draft.sendText,draft.attachments,draft.rich)
            val remote=SendImportedAttachment(id(),ResourceImportRequest(id(),ResourceImportSource.Message(f.room,MessageId(id()),id()),ResourceUsage.Attachment(f.room),id()))
            val extra=f.sends().prepare(f.room,draft.sendText,draft.attachments,draft.rich,serverImports=persistentListOf(remote))
            fails {f.store.submitConversationDraft(draft,extra,f.now)}
            fails {f.store.submitConversationDraft(draft,valid.copy(attachmentOrder=valid.attachmentOrder.reversed().toPersistentList()),f.now)}
            assertEquals(draft,f.store.conversationDraft(f.room));assertTrue(f.store.sendIntents().isEmpty());assertTrue(f.store.resourceImports().isEmpty());assertTrue(f.store.resourceUploads().isEmpty())
            f.store.submitConversationDraft(draft,valid,f.now)
            fails {f.store.submitConversationDraft(draft,valid.copy(attachmentOrder=valid.attachmentOrder.reversed().toPersistentList()),f.now)}
            assertEquals(valid,f.store.sendIntents().single().intent)
        } finally {f.close()}
    }
}

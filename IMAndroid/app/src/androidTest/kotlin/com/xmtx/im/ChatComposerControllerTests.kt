package com.xmtx.im

import android.net.Uri
import com.xmtx.im.client.*
import com.xmtx.im.platform.CameraPhoto
import com.xmtx.im.platform.NormalizedPhoto
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.util.UUID

class ChatComposerControllerTests {
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val actor=UserId(id());private val room=RoomId(id())
    private fun source()=SendAttachment(id(),id(),"图片.jpg","image/jpeg",1000)
    private class Store(private val room: RoomId): ConversationDraftStore {
        var draft=ConversationDraft(room);val sends=mutableMapOf<String,SendIntent>();var lost=false;var reject=false
        var saveGate: CompletableDeferred<Unit>?=null;var submitGate: CompletableDeferred<Unit>?=null
        var entered=CompletableDeferred<Unit>()
        override suspend fun conversationDraft(room: RoomId)=draft
        override suspend fun saveConversationContent(expected: ConversationDraft,text: String,rich: MessageRichContent,now: Long): ConversationDraft {
            saveGate?.let {entered.complete(Unit);it.await()};if(draft!=expected) throw ConversationDraftConflict()
            if(text!=draft.text || rich!=draft.rich) draft=draft.copy(revision=draft.revision+1,text=text,rich=rich,updatedAt=now);return draft
        }
        override suspend fun saveConversationText(expected: ConversationDraft,text: String,now: Long): ConversationDraft {
            saveGate?.let { entered.complete(Unit);it.await() };if(draft!=expected) throw ConversationDraftConflict()
            if(text!=draft.text) draft=draft.copy(revision=draft.revision+1,text=text,rich=draft.rich.copy(entities=persistentListOf()),updatedAt=now);return draft
        }
        override suspend fun addConversationAttachment(room: RoomId,attachment: SendAttachment,now: Long): ConversationDraft { draft=draft.copy(revision=draft.revision+1,attachments=draft.attachments.add(attachment),attachmentOrder=draft.attachmentOrder.add(attachment.id));return draft }
        override suspend fun removeConversationAttachment(expected: ConversationDraft,asset: String,now: Long): ConversationDraft { check(draft==expected);draft=draft.copy(revision=draft.revision+1,attachments=draft.attachments.filterNot { it.asset==asset }.toPersistentList(),attachmentOrder=draft.attachmentOrder.remove(draft.attachments.first {it.asset==asset}.id));return draft }
        override suspend fun reorderConversationAttachments(expected: ConversationDraft,assets: PersistentList<String>,now: Long): ConversationDraft {
            check(expected==draft);draft=draft.copy(revision=draft.revision+1,attachments=assets.map { id -> draft.attachments.first { it.asset==id } }.toPersistentList(),attachmentOrder=assets.map {asset->draft.attachments.first {it.asset==asset}.id}.toPersistentList());return draft
        }
        override suspend fun submitConversationDraft(expected: ConversationDraft,intent: SendIntent,now: Long): SendIntent {
            submitGate?.let { entered.complete(Unit);it.await() }
            if(reject) throw ConversationDraftSubmissionRejected("附件未就绪，请移除后重试")
            sends[intent.id]?.let { return it }
            check(expected==draft);sends[intent.id]=intent;draft=ConversationDraft(room,expected.revision+1)
            if(lost) { lost=false;throw IOException("lost local confirmation") };return intent
        }
    }
    private suspend fun until(test: ()->Boolean)=withTimeout(5000) { while(!test()) delay(10) }
    private fun controller(parent: CoroutineScope,store: Store,stage: suspend (Uri)->SendAttachment={ source() },release: suspend (String)->Unit={},document: suspend (Uri)->SendAttachment={ source() },camera: suspend ()->CameraPhoto={ error("no camera") },preview: suspend (SendAttachment)->NormalizedPhoto?={ null },resolve: suspend (String)->PersistentList<MentionTarget> = {persistentListOf()},replyAllowed: suspend (MessageId)->Boolean={true},capability: suspend ()->Boolean?={null},accountKind:suspend ()->AccountKind?={null})=ChatComposerController(room,parent,store,
        prepareSend={ text,attachments -> val now=System.currentTimeMillis();SendIntent(id(),actor,room,id(),text,attachments,now,now+86400000) },stage=stage,release=release,stageDocument=document,createCamera=camera,thumbnail=preview,resolveMentions=resolve,validateReply=replyAllowed,readSendingPolicy={ConversationSendingPolicy(capability(),accountKind())},missing={ persistentSetOf() },publish={})
    @Test fun systemAccountKindDisablesNewWorkEvenWhenCapabilityAllowsAndKeepsOriginalRetry()=runBlocking<Unit> {
        val store=Store(room);var kind=AccountKind.System;val controller=controller(this,store,capability={true},accountKind={kind})
        try {
            store.draft=ConversationDraft(room,text="原草稿")
            controller.foreground(true);until {controller.state.draft!=null && controller.state.directAccountKind==AccountKind.System}
            controller.edit("忽略编辑");assertFalse(controller.beginPick());controller.send();delay(20)
            assertTrue(store.sends.isEmpty());assertEquals("原草稿",store.draft.text)
            kind=AccountKind.CustomerSupport;controller.refreshSendingCapability();until {controller.state.directAccountKind==kind}
            store.lost=true;controller.send();until {store.sends.size==1 && !controller.state.sending};val frozen=store.sends.values.single()
            kind=AccountKind.System;controller.refreshSendingCapability();until {controller.state.directAccountKind==kind}
            controller.retrySave();until {!controller.state.contentLocked};assertEquals(listOf(frozen),store.sends.values.toList());assertTrue(store.draft.empty)
        } finally {controller.close()}
    }
    @Test fun unknownCapabilityAllowsEditingButDenialPreservesDraftUntilNewerAllowance()=runBlocking<Unit> {
        val store=Store(room);var allowed:Boolean?=null;val controller=controller(this,store,capability={allowed})
        try {
            controller.foreground(true);until {controller.state.draft!=null};controller.edit("保留草稿");until {store.draft.text=="保留草稿"}
            allowed=false;controller.refreshSendingCapability();until {controller.state.canSend==false}
            controller.edit("不应修改");assertFalse(controller.beginPick());controller.send();delay(20)
            assertTrue(store.sends.isEmpty());assertEquals("保留草稿",store.draft.text);assertEquals("保留草稿",controller.state.text)
            allowed=true;controller.refreshSendingCapability();until {controller.state.canSend==true};controller.send();until {store.sends.size==1}
            assertEquals("保留草稿",store.sends.values.single().text);assertTrue(store.draft.empty)
        } finally {controller.close()}
    }
    @Test fun staleCapabilityReadsCannotOverrideNewerStateOrBackgroundAndErrorsKeepDenial()=runBlocking<Unit> {
        val store=Store(room);var call=0;val gate=CompletableDeferred<Unit>();val entered=CompletableDeferred<Unit>();var fail=false
        val controller=controller(this,store,capability={
            call++;if(call==1) {entered.complete(Unit);withContext(NonCancellable) {gate.await()};true}
            else if(fail) throw IOException("read failure") else false
        })
        try {
            controller.foreground(true);entered.await();controller.refreshSendingCapability();until {controller.state.canSend==false}
            gate.complete(Unit);delay(20);assertEquals(false,controller.state.canSend)
            fail=true;controller.refreshSendingCapability();until {controller.state.capabilityFeedback!=null};assertEquals(false,controller.state.canSend)
            controller.foreground(false);val calls=call;controller.refreshSendingCapability();delay(20);assertEquals(calls,call)
            fail=false;controller.foreground(true);until {controller.state.capabilityFeedback==null};assertEquals(false,controller.state.canSend)
        } finally {gate.complete(Unit);controller.close()}
    }
    @Test fun lostLocalSubmissionConfirmationReplaysOriginalIdentityAfterCapabilityDenial()=runBlocking<Unit> {
        val store=Store(room);var allowed=true;store.lost=true
        val controller=controller(this,store,capability={allowed})
        try {
            controller.foreground(true);until {controller.state.draft!=null};controller.edit("已提交");controller.send()
            until {!controller.state.sending && store.sends.size==1};val original=store.sends.values.single()
            allowed=false;controller.refreshSendingCapability();until {controller.state.canSend==false}
            controller.retrySave();until {!controller.state.contentLocked && !controller.state.sending}
            assertEquals(listOf(original),store.sends.values.toList());assertTrue(store.draft.empty);assertTrue(controller.state.text.isEmpty())
        } finally {controller.close()}
    }
    @Test fun capabilityDenialDuringAttachmentPreparationReleasesUnadoptedSelection()=runBlocking<Unit> {
        val store=Store(room);var allowed=true;val gate=CompletableDeferred<Unit>();val entered=CompletableDeferred<Unit>();val attachment=source();val released=mutableListOf<String>()
        val controller=controller(this,store,capability={allowed},stage={entered.complete(Unit);withContext(NonCancellable) {gate.await()};attachment},release={released+=it})
        try {
            controller.foreground(true);until {controller.state.draft!=null};assertTrue(controller.beginPick());controller.picked(Uri.parse("content://test/photo"));entered.await()
            allowed=false;controller.refreshSendingCapability();until {controller.state.canSend==false};gate.complete(Unit)
            until {!controller.state.preparing};assertTrue(store.draft.attachments.isEmpty());assertEquals(listOf(attachment.asset),released)
        } finally {gate.complete(Unit);controller.close()}
    }
    @Test fun mentionResolutionCannotOverwriteAnEditedDraftOrReturnFromBackground()=runBlocking<Unit> {
        val store=Store(room);var gate=CompletableDeferred<Unit>();var entered=CompletableDeferred<Unit>()
        val controller=controller(this,store,resolve={entered.complete(Unit);withContext(NonCancellable) {gate.await()};persistentListOf(MentionTarget.User(actor))})
        try {
            controller.foreground(true);until {controller.state.draft!=null};controller.edit("body");controller.mentions("@member");entered.await()
            controller.send();assertTrue(store.sends.isEmpty());controller.edit("changed");gate.complete(Unit);until {!controller.state.resolvingMentions}
            assertTrue(store.draft.rich.mentions.isEmpty());assertTrue(controller.state.feedback.orEmpty().contains("草稿已变化"))
            gate=CompletableDeferred();entered=CompletableDeferred();controller.mentions("@member");entered.await();controller.foreground(false);gate.complete(Unit);delay(20)
            assertTrue(store.draft.rich.mentions.isEmpty());controller.foreground(true);controller.mentions("@member");until {store.draft.rich.mentions.isNotEmpty()}
            assertEquals(persistentListOf(MentionTarget.User(actor)),store.draft.rich.mentions)
        } finally {gate.complete(Unit);controller.close()}
    }
    @Test fun replySelectionIsRoomBoundAndRevokedTargetStopsFreezeUntilExplicitlyCleared()=runBlocking<Unit> {
        val store=Store(room);var valid=true;val controller=controller(this,store,replyAllowed={valid})
        val target=Message(MessageId(id()),room,actor,"source",1)
        try {
            controller.foreground(true);until {controller.state.draft!=null};controller.edit("reply")
            controller.reply(target.copy(roomId=RoomId(id())));assertNull(controller.state.rich.replyTo)
            controller.reply(target.copy(withdrawn=true));assertNull(controller.state.rich.replyTo)
            controller.reply(target);until {store.draft.rich.replyTo==target.id};valid=false;controller.send();until {!controller.state.sending}
            assertTrue(store.sends.isEmpty());assertEquals(target.id,store.draft.rich.replyTo);assertTrue(controller.state.feedback.orEmpty().contains("回复的消息当前不可用"))
            controller.reply(null);controller.send();until {store.sends.size==1};assertNull(store.sends.values.single().rich.replyTo)
        } finally {controller.close()}
    }
    @Test fun richEditsDuringASuspendedSaveDrainTheLatestContentOnClose()=runBlocking<Unit> {
        val store=Store(room);val controller=controller(this,store)
        try {
            controller.foreground(true);until {controller.state.draft!=null};store.saveGate=CompletableDeferred()
            val first=MessageRichContent(entities=persistentListOf(RichTextEntity(0,1,RichTextKind.bold)))
            controller.editContent("first",first);store.entered.await()
            val latest=first.copy(entities=persistentListOf(RichTextEntity(0,2,RichTextKind.italic)))
            controller.editContent("latest",latest);val closing=launch {controller.close()};delay(20);assertFalse(closing.isCompleted)
            store.saveGate!!.complete(Unit);closing.join();assertEquals("latest",store.draft.text);assertEquals(latest,store.draft.rich)
        } finally {store.saveGate?.complete(Unit);controller.close()}
    }
    @Test fun restoredRichDraftKeepsExactWhitespaceAndTheSameFrozenContentAfterLostConfirmation()=runBlocking<Unit> {
        val store=Store(room);val text=" 😀 正文 "
        val rich=MessageRichContent(persistentListOf(MentionTarget.User(actor)),persistentListOf(RichTextEntity(1,2,RichTextKind.bold)),MessageId(id()))
        store.draft=ConversationDraft(room,text=text,rich=rich);val controller=controller(this,store)
        try {
            controller.foreground(true);until {controller.state.draft!=null};store.lost=true;controller.send()
            until {!controller.state.sending && store.sends.size==1};val frozen=store.sends.values.single()
            assertEquals(text,frozen.text);assertEquals(rich,frozen.rich)
            controller.edit("next");controller.retrySave();until {!controller.state.sending && store.draft.text=="next"}
            assertEquals(listOf(frozen),store.sends.values.toList());assertEquals(MessageRichContent.Empty,store.draft.rich)
        } finally {controller.close()}
    }
    @Test fun plainTextEditDropsOldRangesWithoutLosingMentionsOrReply()=runBlocking<Unit> {
        val store=Store(room);val rich=MessageRichContent(persistentListOf(MentionTarget.Everyone),persistentListOf(RichTextEntity(1,2,RichTextKind.bold)),MessageId(id()))
        store.draft=ConversationDraft(room,text=" 😀 ",rich=rich);val controller=controller(this,store)
        try {
            controller.foreground(true);until {controller.state.draft!=null};controller.edit("changed");controller.send();until {store.sends.size==1}
            assertEquals("changed",store.sends.values.single().text);assertEquals(rich.copy(entities=persistentListOf()),store.sends.values.single().rich)
        } finally {controller.close()}
    }
    @Test fun editDuringSubmissionBecomesANewPersistedDraft()=runBlocking<Unit> {
        val store=Store(room);val controller=controller(this,store)
        try {
            controller.foreground(true);until { controller.state.draft!=null };controller.edit("  第一条  ");until { store.draft.text=="  第一条  " }
            store.submitGate=CompletableDeferred();controller.send();store.entered.await();controller.edit("下一条")
            store.submitGate!!.complete(Unit);until { !controller.state.sending && store.draft.text=="下一条" }
            assertEquals("第一条",store.sends.values.single().text);assertEquals("下一条",controller.state.text)
        } finally { store.submitGate?.complete(Unit);controller.close() }
    }
    @Test fun uncertainLocalSaveRetriesSameIntentAndDoesNotClearNextInput()=runBlocking<Unit> {
        val store=Store(room);val controller=controller(this,store)
        try {
            controller.foreground(true);until { controller.state.draft!=null };controller.edit("已保存但回调丢失");store.lost=true;controller.send()
            until { !controller.state.sending && controller.state.feedback?.contains("未确认")==true };val original=store.sends.values.single()
            controller.edit("新的输入");controller.retrySave();until { !controller.state.sending && store.draft.text=="新的输入" }
            assertEquals(listOf(original),store.sends.values.toList());assertEquals("新的输入",controller.state.text)
        } finally { controller.close() }
    }
    @Test fun routeCloseDrainsAcceptedTextBeforeReleasingItsOwner()=runBlocking<Unit> {
        val store=Store(room);val controller=controller(this,store)
        try {
            controller.foreground(true);until { controller.state.draft!=null };store.saveGate=CompletableDeferred();controller.edit("返回时保留")
            store.entered.await();var closed=false;val closing=launch { controller.close();closed=true };delay(30);assertFalse(closed)
            store.saveGate!!.complete(Unit);closing.join();assertEquals("返回时保留",store.draft.text);assertTrue(closed)
        } finally { store.saveGate?.complete(Unit);controller.close() }
    }
    @Test fun backgroundPickerReturnWaitsForForegroundAndLateCancelledPhotoIsReleased()=runBlocking<Unit> {
        val store=Store(room);val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();val source=source();var discarded:String?=null
        val controller=controller(this,store,stage={ entered.complete(Unit);withContext(NonCancellable) { release.await() };source },release={ discarded=it })
        try {
            controller.foreground(true);until { controller.state.draft!=null };assertTrue(controller.beginPick());controller.foreground(false)
            controller.picked(Uri.parse("content://photos/1"));assertFalse(entered.isCompleted);controller.foreground(true);entered.await()
            controller.foreground(false);release.complete(Unit);until { discarded!=null };assertEquals(source.asset,discarded);assertTrue(store.draft.attachments.isEmpty())
        } finally { release.complete(Unit);controller.close() }
    }
    @Test fun deterministicSubmissionRejectionLeavesAttachmentsEditable()=runBlocking<Unit> {
        val store=Store(room);val source=source();store.draft=store.draft.copy(attachments=persistentListOf(source),attachmentOrder=persistentListOf(source.id));val controller=controller(this,store)
        try {
            controller.foreground(true);until { controller.state.draft!=null };store.reject=true;controller.send();until { !controller.state.sending && controller.state.feedback!=null }
            controller.remove(source.asset);until { store.draft.attachments.isEmpty() };assertTrue(store.sends.isEmpty())
            controller.edit("改为文本");store.reject=false;controller.send();until { store.sends.size==1 };assertEquals("改为文本",store.sends.values.single().text)
        } finally { controller.close() }
    }
    private class Capture: CameraPhoto {
        override val uri=Uri.parse("content://camera/capture");var released=false
        override suspend fun prepare(): NormalizedPhoto=error("the existing image staging pipeline reads the URI")
        override fun close() { released=true }
    }
    @Test fun cameraResultWaitsForForegroundThenClosesTemporaryCaptureAfterAdoption()=runBlocking<Unit> {
        val store=Store(room);val capture=Capture();val source=source();val controller=controller(this,store,stage={ assertEquals(capture.uri,it);source },camera={ capture })
        try {
            controller.foreground(true);until { controller.state.draft!=null };var output:Uri?=null
            controller.takePicture { output=it };until { output!=null };assertEquals(ChatAttachmentSource.Camera,controller.state.source)
            controller.foreground(false);controller.captured(true);assertTrue(store.draft.attachments.isEmpty());assertFalse(capture.released)
            controller.foreground(true);until { store.draft.attachments.isNotEmpty() && !controller.state.preparing }
            assertTrue(capture.released);assertEquals(source,store.draft.attachments.single())
        } finally { controller.close() }
    }
    @Test fun closingAnExternalCameraReleasesItsGrantAndRejectsLateResult()=runBlocking<Unit> {
        val store=Store(room);val capture=Capture();val controller=controller(this,store,camera={ capture })
        controller.foreground(true);until { controller.state.draft!=null };controller.takePicture {};until { controller.state.picking }
        controller.close();controller.captured(true);assertTrue(capture.released);assertTrue(store.draft.attachments.isEmpty())
    }
    @Test fun cancelledCameraAllocationNeverLaunchesAndAlwaysReleasesTheNewHandle()=runBlocking<Unit> {
        val store=Store(room);val capture=Capture();val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();var launched=false
        val controller=controller(this,store,camera={ entered.complete(Unit);release.await();capture })
        try {
            controller.foreground(true);until { controller.state.draft!=null };controller.takePicture { launched=true };entered.await()
            controller.foreground(false);release.complete(Unit);until { capture.released };assertFalse(launched);assertFalse(controller.state.picking)
        } finally { release.complete(Unit);controller.close() }
    }
    @Test fun documentResultsAreBoundToTheirPickerKindAndAdoptTheSameOrderedDraft()=runBlocking<Unit> {
        val store=Store(room);val first=source();val second=source();val controller=controller(this,store,stage={ first },document={ second })
        try {
            controller.foreground(true);until { controller.state.draft!=null };assertTrue(controller.beginPick(ChatAttachmentSource.Document))
            controller.picked(Uri.parse("content://stale-photo/1"));assertEquals(ChatAttachmentSource.Document,controller.state.source)
            controller.foreground(false);controller.picked(Uri.parse("content://document/1"),ChatAttachmentSource.Document);assertTrue(store.draft.attachments.isEmpty())
            controller.foreground(true);until { !controller.state.preparing && store.draft.attachments.size==1 }
            assertTrue(controller.beginPick());controller.picked(Uri.parse("content://photo/1"));until { !controller.state.preparing && store.draft.attachments.size==2 }
            assertEquals(listOf(second,first),store.draft.attachments)
        } finally { controller.close() }
    }

    private suspend fun previewPhoto(): NormalizedPhoto {
        val bitmap=android.graphics.Bitmap.createBitmap(32,20,android.graphics.Bitmap.Config.ARGB_8888)
        val bytes=com.google.protobuf.ByteString.newOutput()
        try { bitmap.eraseColor(android.graphics.Color.BLUE);bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,bytes) } finally { bitmap.recycle() }
        return com.xmtx.im.platform.PhotoPreparation().prepare(bytes.toByteString())
    }
    @Test fun multiPhotoSelectionPreservesOrderSkipsDuplicateUrisAndContinuesAfterOneFailure()=runBlocking<Unit> {
        val store=Store(room);val first=source();val second=source()
        val controller=controller(this,store,stage={ when(it.lastPathSegment) { "1"->first;"2"->second;else->throw IOException("bad picture") } })
        try {
            controller.foreground(true);until { controller.state.draft!=null };controller.beginPick()
            controller.pickedPhotos(listOf("1","bad","1","2").map { Uri.parse("content://photos/$it") })
            until { !controller.state.preparing && store.draft.attachments.size==2 }
            assertEquals(listOf(first,second),store.draft.attachments);assertTrue(controller.state.feedback!!.contains("1 项未能添加"));assertNull(controller.state.progress)
        } finally { controller.close() }
    }
    @Test fun fallbackPickerCannotExceedRemainingCapacity()=runBlocking<Unit> {
        val store=Store(room);val initial=(1..9).map { source() }.toPersistentList();store.draft=store.draft.copy(attachments=initial,attachmentOrder=initial.map {it.id}.toPersistentList());var reads=0
        val controller=controller(this,store,stage={ reads++;source() })
        try {
            controller.foreground(true);until { controller.state.draft!=null };controller.beginPick()
            controller.pickedPhotos((1..20).map { Uri.parse("content://photos/$it") });until { !controller.state.preparing && store.draft.attachments.size==10 }
            assertEquals(1,reads);assertTrue(controller.state.feedback!!.contains("最多 10"));assertFalse(controller.beginPick())
        } finally { controller.close() }
    }
    @Test fun backgroundCancelsTheRestOfABatchAndReleasesOnlyItsUnadoptedPhoto()=runBlocking<Unit> {
        val store=Store(room);val first=source();val second=source();val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();val read=mutableListOf<String>();val discarded=mutableListOf<String>()
        val controller=controller(this,store,stage={ uri -> read.add(uri.lastPathSegment!!);if(uri.lastPathSegment=="1") first else { entered.complete(Unit);withContext(NonCancellable) { release.await() };second } },release={ discarded.add(it) })
        try {
            controller.foreground(true);until { controller.state.draft!=null };controller.beginPick();controller.pickedPhotos((1..3).map { Uri.parse("content://photos/$it") })
            entered.await();controller.foreground(false);release.complete(Unit);until { !controller.state.preparing }
            assertEquals(listOf("1","2"),read);assertEquals(listOf(first),store.draft.attachments);assertEquals(listOf(second.asset),discarded)
        } finally { release.complete(Unit);controller.close() }
    }
    @Test fun backgroundClearsThumbnailsAndLateDecodeCannotReplaceTheNewForegroundRead()=runBlocking<Unit> {
        val store=Store(room);val source=source();store.draft=store.draft.copy(attachments=persistentListOf(source),attachmentOrder=persistentListOf(source.id));val photo=previewPhoto()
        val first=CompletableDeferred<Unit>();val second=CompletableDeferred<Unit>();var reads=0
        val controller=controller(this,store,preview={ reads++;val gate=if(reads==1) first else second;withContext(NonCancellable) { gate.await() };photo })
        try {
            controller.foreground(true);until { reads==1 };controller.foreground(false);assertTrue(controller.state.thumbnails.isEmpty());controller.foreground(true)
            first.complete(Unit);until { reads==2 };assertTrue(controller.state.thumbnails.isEmpty());second.complete(Unit)
            until { controller.state.thumbnails.size==1 };assertSame(photo,controller.state.thumbnails[source.asset])
            controller.foreground(false);assertTrue(controller.state.thumbnails.isEmpty())
        } finally { first.complete(Unit);second.complete(Unit);controller.close() }
    }
    @Test fun removalRejectsALateThumbnailAndPreviewFailureDoesNotPreventSending()=runBlocking<Unit> {
        val store=Store(room);val source=source();store.draft=store.draft.copy(attachments=persistentListOf(source),attachmentOrder=persistentListOf(source.id));val photo=previewPhoto()
        val gate=CompletableDeferred<Unit>();var entered=false
        val controller=controller(this,store,preview={ entered=true;withContext(NonCancellable) { gate.await() };photo })
        try {
            controller.foreground(true);until { entered };controller.remove(source.asset);until { store.draft.attachments.isEmpty() };gate.complete(Unit)
            controller.close();assertTrue(controller.state.thumbnails.isEmpty())
        } finally { gate.complete(Unit);controller.close() }
        val next=Store(room);next.draft=next.draft.copy(attachments=persistentListOf(source),attachmentOrder=persistentListOf(source.id));val failed=controller(this,next,preview={ throw IOException("invalid image") })
        try {
            failed.foreground(true);until { source.asset in failed.state.thumbnailFailures };assertTrue(failed.state.unavailable.isEmpty())
            failed.send();until { next.sends.size==1 };assertEquals(source,next.sends.values.single().attachments.single())
        } finally { failed.close() }
    }

    @Test fun cancelledBatchReportsFailedCleanupWithoutCrashingTheEditor()=runBlocking<Unit> {
        val store=Store(room);val attachment=source();val entered=CompletableDeferred<Unit>();val gate=CompletableDeferred<Unit>()
        val controller=controller(this,store,stage={ entered.complete(Unit);withContext(NonCancellable) { gate.await() };attachment },release={ throw IOException("cleanup failed") })
        try {
            controller.foreground(true);until { controller.state.draft!=null };controller.beginPick();controller.pickedPhotos(listOf(Uri.parse("content://photo/1")))
            entered.await();controller.foreground(false);gate.complete(Unit);until { !controller.state.preparing }
            assertTrue(store.draft.attachments.isEmpty());assertTrue(controller.state.feedback!!.contains("未能清理"))
        } finally { gate.complete(Unit);controller.close() }
    }

    @Test fun moveUsesTheCurrentDraftAndSubmittedAttachmentsFollowThatOrder()=runBlocking<Unit> {
        val store=Store(room);val first=source();val second=source();store.draft=store.draft.copy(attachments=persistentListOf(first,second),attachmentOrder=persistentListOf(first.id,second.id));val controller=controller(this,store)
        try {
            controller.foreground(true);until { controller.state.draft!=null };controller.edit("保留正文");controller.move(second.asset,-1)
            until { store.draft.attachments.first()==second && store.draft.text=="保留正文" };controller.send();until { store.sends.size==1 }
            assertEquals(listOf(second,first),store.sends.values.single().attachments);assertEquals("保留正文",store.sends.values.single().text)
        } finally { controller.close() }
    }
    @Test fun movementCannotAlterASendWhoseLocalConfirmationIsUnknown()=runBlocking<Unit> {
        val store=Store(room);val first=source();val second=source();store.draft=store.draft.copy(attachments=persistentListOf(first,second),attachmentOrder=persistentListOf(first.id,second.id));val controller=controller(this,store)
        try {
            controller.foreground(true);until { controller.state.draft!=null };controller.move(first.asset,-1);controller.move(second.asset,1)
            assertEquals(listOf(first,second),store.draft.attachments);store.lost=true;controller.send()
            until { !controller.state.sending && controller.state.feedback?.contains("未确认")==true };controller.move(second.asset,-1);controller.retrySave()
            until { !controller.state.sending && controller.state.attachments.isEmpty() };assertEquals(listOf(first,second),store.sends.values.single().attachments)
        } finally { controller.close() }
    }

}

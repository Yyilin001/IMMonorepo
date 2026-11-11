package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.util.UUID

class SendIntentStorageTests {
    private val context=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private inner class Fixture {
        val actor=UserId(id());val device=DeviceId(id());val room=RoomId(id());var now=1700000000000L
        var store=SqliteClientStore(context,actor,device);var files=ManagedResourceFiles(context,store)
        var service=SendIntentService(actor,store) { now }
        suspend fun source(room: RoomId=this.room): SendAttachment {
            val file=File.createTempFile("send-intent-",".txt",context.cacheDir)
            try {
                file.writeText("持久化附件原件")
                val asset=files.importFile(file,"附件.txt","text/plain",ResourceUsage.Attachment(room),1024)
                return SendAttachment(id(),asset.id,asset.displayName,asset.contentType,asset.byteCount)
            } finally { file.delete() }
        }
        suspend fun enqueue(count: Int=1): SendIntent {
            val sources=(1..count).map { source() }.toPersistentList()
            return service.enqueue(room,"正文与顺序",sources)
        }
        suspend fun ready(source: SendAttachment,until: Long=now+100000) {
            val work=store.resourceUploads().first { it.id==source.id }
            store.saveResourceUploadSession(work.id,ResourceUploadSession(ResourceUploadLocator(ResourceHome.Room((work.request.usage as ResourceUsage.Attachment).room),id()),source.id,1,
                ResourceSessionState.Completed,ResourceState.Ready,now+200000,until,persistentListOf(),null))
        }
        suspend fun cancelled(source: SendAttachment) {
            store.requestResourceUploadCancellation(source.id)
            store.confirmResourceUploadCancellation(source.id,ResourceUploadSession(ResourceUploadLocator(ResourceHome.Room(room),id()),source.id,1,
                ResourceSessionState.Cancelled,ResourceState.Pending,now+100000,null,persistentListOf(),null))
        }
        fun receipt(command: MessageSendOperation,reject: Int?=null): MessageSendOperationReceipt = MessageSendOperationReceipt.newBuilder()
            .setIdentity(MessageSendOperationIdentity.newBuilder().setAccountId(actor.value).setRoomId(command.roomId).setOperationId(command.clientMessageId))
            .setFingerprint(MessageSendOperationFingerprint.newBuilder().setVersion(command.fingerprintVersion).setDigest(command.fingerprint)).setResolvedAtMs(now)
            .apply { if(reject==null) setAccepted(MessageSendOperationAcceptance.newBuilder().setMessageId(command.clientMessageId).setRoomSequence(1))
                else setRejected(MessageSendOperationRejection.newBuilder().setReasonValue(reject)) }.build()
        suspend fun reopen() { files.close();store.close();store=SqliteClientStore(context,actor,device);files=ManagedResourceFiles(context,store);service=SendIntentService(actor,store) { now } }
        suspend fun close() { files.close();store.close() }
    }
    private suspend fun fails(body: suspend ()->Unit) { assertNotNull(runCatching { body() }.exceptionOrNull()) }
    @Test fun atomicallyAdoptsOrderedAttachmentsAndRecoversHandoffAndLostAcceptance()=runBlocking<Unit> {
        val f=Fixture();try {
            val intent=f.enqueue(2);assertEquals(2,f.store.resourceUploads().size);assertTrue(f.files.selected(ResourceUsage.Attachment(f.room)).isEmpty())
            f.files.cleanup();assertEquals(1,f.store.resourceFiles().size);f.reopen();assertEquals(intent,f.store.sendIntents().single().intent)
            f.ready(intent.attachments.last());f.service.prepareNext();assertTrue(f.store.pending().isEmpty())
            f.ready(intent.attachments.first());f.now+=5000;f.service.prepareNext()
            val command=f.store.pending().single();assertEquals(intent.operation,command.clientMessageId);assertEquals(intent.attachments.map { it.id },command.mediaIdsList)
            assertEquals(f.now+ClientSubmissionWindow.COMMAND_MILLISECONDS,command.firstSubmissionDeadlineMs)
            assertEquals(MessageCommand.withMedia(f.actor,f.room,intent.text,intent.attachments.map { it.id }.toPersistentList(),command.firstSubmissionDeadlineMs,intent.operation),command)
            assertFalse(f.service.prepareNext());fails { f.service.discard(intent.id) }
            var calls=0;val receipt=f.receipt(command)
            val transport=object: EnvelopeTransport { override suspend fun request(body: Envelope.Builder): Envelope {
                val request=body.build()
                if(calls==0) assertEquals(command,request.messageSendOperation) else {
                    assertEquals(MessageSendOperationRecover.Action.QUERY,request.messageSendOperationRecover.action)
                    assertEquals(command.fingerprint,request.messageSendOperationRecover.fingerprint.digest)
                    assertEquals(command.clientMessageId,request.messageSendOperationRecover.identity.operationId)
                }
                calls++;if(calls==1) throw IOException("lost accepted reply")
                return Envelope.newBuilder().setMessageSendOperationResult(MessageSendOperationResult.newBuilder().setReceipt(receipt)).build()
            } }
            fails { MessageOutbox(transport,f.store) { f.now }.flush() };f.reopen();assertEquals(command,f.store.pending().single())
            assertEquals(intent.id,f.service.resumeOrReapply(intent.id).id);f.files.cleanup();assertEquals(1,f.store.resourceFiles().size)
            f.now+=1000;MessageOutbox(transport,f.store) { f.now }.flush();assertEquals(2,calls)
            assertEquals(SendIntentPhase.Accepted,f.store.sendIntents().single().phase);assertTrue(f.store.sendIntents().single().intent.sourcesReleased)
            f.files.cleanup();assertTrue(f.store.resourceFiles().isEmpty());f.reopen();assertEquals(SendIntentPhase.Accepted,f.store.sendIntents().single().phase)
        } finally { f.close() }
    }
    @Test fun uncertainLocalFreezeCanBeRetriedWithTheSameIdentityAfterHandoff()=runBlocking<Unit> {
        val f=Fixture();try {
            val prepared=f.service.prepare(f.room,"原始正文",persistentListOf(f.source()))
            f.now+=500;assertEquals(prepared,f.service.enqueue(prepared));f.reopen()
            assertEquals(prepared,f.service.enqueue(prepared));assertEquals(1,f.store.resourceUploads().size)
            fails { f.service.enqueue(prepared.copy(text="不可替换正文")) };assertEquals(prepared,f.store.sendIntents().single().intent)
            f.ready(prepared.attachments.single());f.service.prepareNext();val command=f.store.pending().single()
            assertEquals(SendPreparation.HandedOff,f.service.enqueue(prepared).preparation);assertEquals(command,f.store.pending().single())
            f.store.complete(prepared.operation,f.receipt(command));f.now=prepared.deadline+1
            assertTrue(f.service.enqueue(prepared).sourcesReleased);assertEquals(1,f.store.sendIntents().size);assertEquals(1,f.store.resourceUploads().size)
        } finally { f.close() }
    }
    @Test fun partialCapacityFailureRollsBackUploadsClaimsAndSelectionAdoption()=runBlocking<Unit> {
        val f=Fixture();try {
            repeat(31) {
                val source=f.source();val asset=f.store.resourceOriginal(selection=source.asset)
                f.store.prepareResourceUpload(source.id,source.asset,ResourceUploadRequest(source.id,source.id,asset.purpose,asset.contentType,asset.byteCount,asset.checksum,displayName=asset.displayName))
            }
            val first=f.source();val second=f.source()
            fails { f.service.enqueue(f.room,"原草稿",persistentListOf(first,second)) }
            assertTrue(f.store.sendIntents().isEmpty());assertEquals(31,f.store.resourceUploads().size)
            assertEquals(setOf(first.asset,second.asset),f.files.selected(ResourceUsage.Attachment(f.room)).map { it.id }.toSet())
            f.reopen();assertTrue(f.store.sendIntents().isEmpty());assertEquals(31,f.store.resourceUploads().size)
        } finally { f.close() }
    }
    @Test fun cancelledPreparationNeverCreatesMessageAndKeepsUnconfirmedUploadBytes()=runBlocking<Unit> {
        val f=Fixture();try {
            val intent=f.enqueue();val source=intent.attachments.single();f.service.discard(intent.id)
            assertEquals(SendIntentPhase.Cancelled,f.store.sendIntents().single().phase);assertTrue(f.store.resourceUploads().single().cancellationRequested)
            f.files.cleanup();assertEquals(1,f.store.resourceFiles().size);assertTrue(f.store.pending().isEmpty())
            f.cancelled(source);f.service.prepareNext();f.files.cleanup();assertTrue(f.store.resourceFiles().isEmpty());assertTrue(f.store.resourceUploads().single().sourceReleased)
            fails { f.service.resumeOrReapply(intent.id) }
        } finally { f.close() }
    }
    @Test fun expiredBindingRequiresNewIntentAndUploadsWhileOriginalFilesRemainOwned()=runBlocking<Unit> {
        val f=Fixture();try {
            val old=f.enqueue(2);for(source in old.attachments) f.ready(source,f.now+5)
            f.now+=6;f.service.prepareNext();assertEquals(SendIntentPhase.Expired,f.store.sendIntents().single().phase);assertTrue(f.store.pending().isEmpty())
            val next=f.service.resumeOrReapply(old.id);assertNotEquals(old.id,next.id);assertNotEquals(old.operation,next.operation)
            assertEquals(old.attachments.map { it.asset },next.attachments.map { it.asset });assertTrue(old.attachments.map { it.id }.toSet().intersect(next.attachments.map { it.id }.toSet()).isEmpty())
            assertTrue(f.store.sendIntents().first().intent.sourcesReleased);f.files.cleanup();assertEquals(1,f.store.resourceFiles().size)
            next.attachments.forEach { f.ready(it) };f.service.prepareNext();assertEquals(next.operation,f.store.pending().single().clientMessageId)
        } finally { f.close() }
    }
    @Test fun verifiedReceiptIsRequiredAndAnUnknownSendCannotBeDiscardedOrReplaced()=runBlocking<Unit> {
        val f=Fixture();try {
            val intent=f.enqueue();f.ready(intent.attachments.single());f.service.prepareNext();val command=f.store.pending().single()
            val forged=f.receipt(command).toBuilder().setFingerprint(MessageSendOperationFingerprint.getDefaultInstance()).build()
            fails { f.store.complete(intent.operation,forged) };assertEquals(SendIntentPhase.Confirming,f.store.sendIntents().single().phase)
            fails { f.service.discard(intent.id) };assertEquals(intent.id,f.service.resumeOrReapply(intent.id).id)
            f.store.complete(intent.operation,f.receipt(command));fails { f.store.complete(intent.operation,f.receipt(command,2)) }
            assertEquals(SendIntentPhase.Accepted,f.store.sendIntents().single().phase)
        } finally { f.close() }
    }
    @Test fun rejectionRetainsDraftAndExplicitReapplyGetsNewIdentity()=runBlocking<Unit> {
        val f=Fixture();try {
            val intent=f.enqueue();f.ready(intent.attachments.single());f.service.prepareNext();val command=f.store.pending().single()
            f.store.complete(intent.operation,f.receipt(command,4));f.files.cleanup();assertEquals(1,f.store.resourceFiles().size)
            assertEquals(SendIntentPhase.Rejected,f.store.sendIntents().single().phase)
            val next=f.service.resumeOrReapply(intent.id);assertEquals(intent.text,next.text);assertNotEquals(intent.operation,next.operation)
            assertEquals(intent.attachments.single().asset,next.attachments.single().asset);assertTrue(f.store.pending().isEmpty())
            f.service.discard(next.id);f.cancelled(next.attachments.single());f.service.prepareNext();f.files.cleanup();assertTrue(f.store.resourceFiles().isEmpty())
        } finally { f.close() }
    }
    @Test fun pausedDependencyResumesWithoutChangingFrozenIdentity()=runBlocking<Unit> {
        val f=Fixture();try {
            val intent=f.enqueue();f.store.controlResourceUpload(intent.attachments.single().id,true,false);f.service.prepareNext()
            assertEquals(SendIntentPhase.NeedsAttention,f.store.sendIntents().single().phase)
            assertEquals(intent,f.service.resumeOrReapply(intent.id));assertFalse(f.store.resourceUploads().single().execution.userPaused)
            f.ready(intent.attachments.single());f.service.prepareNext();assertEquals(intent.operation,f.store.pending().single().clientMessageId)
        } finally { f.close() }
    }
    @Test fun expiredOrSlowPreparationDoesNotBlockIndependentReadyMessages()=runBlocking<Unit> {
        val f=Fixture();try {
            val slow=f.enqueue();val fast=f.enqueue();f.ready(fast.attachments.single());f.service.prepareNext()
            assertEquals(fast.operation,f.store.pending().single().clientMessageId)
            f.now=slow.deadline;f.service.prepareNext();assertEquals(SendIntentPhase.Expired,f.store.sendIntents().first().phase)
            assertEquals(SendIntentPhase.Confirming,f.store.sendIntents().last().phase)
            assertNull(f.store.sendPreparationDeadline())
        } finally { f.close() }
    }
    @Test fun revokedRoomAndSourceLossCannotBeHandedToOutbox()=runBlocking<Unit> {
        val f=Fixture();try {
            f.store.acceptState(f.room,RoomSyncState.newBuilder().setOwnerEpoch(1).setViewerMembershipRevision(1).build())
            val intent=f.enqueue();f.ready(intent.attachments.single());f.store.unavailable(f.room);f.service.prepareNext()
            assertEquals(SendIntentPhase.NeedsAttention,f.store.sendIntents().single().phase);assertTrue(f.store.pending().isEmpty())
            fails { f.service.resumeOrReapply(intent.id) }
            val other=RoomId(id());val source=f.source(other);val second=f.service.enqueue(other,"",persistentListOf(source))
            f.store.markResourceAssetUnavailable(source.asset);f.service.prepareNext()
            assertEquals(SendPreparation.Failed,f.store.sendIntents().last().intent.preparation)
            fails { f.service.resumeOrReapply(second.id) };assertEquals(2,f.store.sendIntents().size)
        } finally { f.close() }
    }
    @Test fun preparationObserverHandoffIsEventDrivenAndStopsWithAccountOwner()=runBlocking<Unit> {
        val f=Fixture();val worker=launch { f.service.runPreparation() }
        try {
            val intent=f.enqueue();delay(50);assertTrue(f.store.pending().isEmpty())
            f.ready(intent.attachments.single());withTimeout(5000) { while(f.store.pending().isEmpty()) delay(10) }
            worker.cancelAndJoin();val next=f.enqueue();f.ready(next.attachments.single());delay(50)
            assertEquals(1,f.store.pending().size);assertEquals(SendPreparation.Preparing,f.store.sendIntents().last().intent.preparation)
        } finally { worker.cancelAndJoin();f.close() }
    }
    @Test fun pausedConfirmationCannotReplaceOrDiscardButProvenLocalExpiryCan()=runBlocking<Unit> {
        val f=Fixture();try {
            val intent=f.enqueue();f.ready(intent.attachments.single());f.service.prepareNext()
            val claim=f.store.claimSend(f.now)!!;f.store.deferSend(claim,claim.state.copy(status=SendRecoveryStatus.NeedsAttention,nextAt=f.now+5000))
            val paused=f.store.sendIntents().single();assertTrue(paused.canResumeConfirmation);assertFalse(paused.canReplace)
            fails {f.service.discard(intent.id)};assertEquals(intent.id,f.service.resumeOrReapply(intent.id).id)
            assertEquals(claim.command,f.store.pending().single())
            f.store.resumeSend(f.room,f.actor,intent.operation,f.now);assertNull(f.store.claimSend(f.now+4999))
            val resumed=f.store.claimSend(f.now+5000)!!;assertEquals(SendAction.Recover,resumed.action)
            f.store.completeSend(resumed,f.receipt(claim.command,6));assertTrue(f.store.sendIntents().single().canReplace)
            val replacement=f.service.resumeOrReapply(intent.id);assertNotEquals(intent.operation,replacement.operation)
            f.ready(replacement.attachments.single());f.service.prepareNext();val command=f.store.pending().single()
            f.now=command.firstSubmissionDeadlineMs+1;assertNull(f.store.claimSend(f.now))
            val expired=f.store.sendIntents().first {it.intent.id==replacement.id};assertEquals(SendIntentPhase.Expired,expired.phase);assertTrue(expired.canReplace)
            f.service.discard(replacement.id);assertTrue(f.store.sendIntents().first {it.intent.id==replacement.id}.intent.sourcesReleased)
        } finally {f.close()}
    }


    @Test fun networkAndAuthenticationWaitingKeepOriginalAttachmentOwnershipAndCannotBeReplaced()=runBlocking<Unit> {
        val f=Fixture();try {
            val intent=f.enqueue();f.ready(intent.attachments.single());f.service.prepareNext()
            val original=f.store.pending().single()
            for(status in listOf(SendRecoveryStatus.WaitingForNetwork,SendRecoveryStatus.WaitingForAuthentication)) {
                val claim=f.store.claimSend(f.now)!!
                f.store.deferSend(claim,claim.state.copy(action=SendAction.Submit,status=status))
                f.reopen()
                val task=f.store.sendIntents().single()
                assertEquals(SendIntentPhase.Confirming,task.phase);assertEquals(status,task.recovery)
                assertFalse(task.canResumeConfirmation);assertFalse(task.canReplace);assertFalse(task.intent.sourcesReleased)
                fails {f.service.discard(intent.id)}
                assertEquals(intent.id,f.service.resumeOrReapply(intent.id).id)
                assertEquals(status,f.store.sendIntents().single().recovery);assertNull(f.store.claimSend(f.now))
                assertEquals(original,f.store.pending().single());assertEquals(1,f.store.resourceUploads().size)
                f.store.resumeNetworkWaitingSends(f.actor,f.now)
            }
            val resumed=f.store.claimSend(f.now)!!;assertEquals(original,resumed.command);assertEquals(SendAction.Submit,resumed.action)
            f.store.completeSend(resumed,f.receipt(original));assertTrue(f.store.sendIntents().single().intent.sourcesReleased)
        } finally {f.close()}
    }
}

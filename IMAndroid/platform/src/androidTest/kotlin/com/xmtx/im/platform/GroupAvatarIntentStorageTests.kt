package com.xmtx.im.platform

import android.graphics.Bitmap
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.RoomSyncState
import com.xmtx.imclientkit.generated.im.realtime.v2.SnapshotManifest
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class GroupAvatarIntentStorageTests {
    private val context=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private suspend fun fails(body: suspend ()->Unit) { assertNotNull(runCatching { body() }.exceptionOrNull()) }
    private inner class Fixture {
        val actor=UserId(id());val device=DeviceId(id());val room=RoomId(id());val variant=id();var now=1700000000000L
        var store=SqliteClientStore(context,actor,device);var files=ManagedResourceFiles(context,store)
        var remote=GroupAvatarState(room,null,0);var membership=1L;var lose=false;var loseBefore=false;var submits=0;var recoveries=0
        val attempts=mutableListOf<NetworkWorkIntent?>()
        val receipts=mutableMapOf<String,GroupAvatarChange>();val closed=mutableSetOf<String>()
        val reader=GroupAvatarReading { r -> presentation(r) }
        fun presentation(r: RoomId=room,state: GroupAvatarState=remote)=GroupAvatarPresentation(actor,device,state.copy(room=r),membership,
            state.media?.let { 1L },true,state.media?.let { AvatarAccess(AvatarContent(it,variant,1,ResourceChecksum("a".repeat(64)),1),null) },
            now,now+300000,now,System.nanoTime()+300000000000L,null)
        val commands=object: GroupAvatarCommands {
            override suspend fun submit(command: GroupAvatarCommand): GroupAvatarCommandResponse {
                attempts+=currentCoroutineContext()[NetworkWorkIntent];submits++
                if(loseBefore) { loseBefore=false;throw java.io.IOException("lost before reply") }
                if(command.operation in closed) throw ClientFailure.Http(410)
                val previous=receipts[command.operation]
                val outcome=if(previous!=null) GroupAvatarOutcome.Committed(previous)
                    else if(command.revision!=remote.revision) GroupAvatarOutcome.RevisionConflict
                    else {
                        remote=GroupAvatarState(room,command.mutation.mediaId,remote.revision+1)
                        GroupAvatarChange(remote,remote.revision,now).also { receipts[command.operation]=it }.let(GroupAvatarOutcome::Committed)
                    }
                if(lose) { lose=false;throw java.io.IOException("lost committed reply") }
                return GroupAvatarCommandResponse(actor,device,command,outcome)
            }
            override suspend fun recover(request: GroupAvatarRecoveryRequest): GroupAvatarRecoveryResponse {
                attempts+=currentCoroutineContext()[NetworkWorkIntent];recoveries++
                val receipt=receipts[request.command.operation]
                val result=if(receipt!=null) GroupAvatarRecoveryResult.Committed(receipt)
                    else if(request.command.operation in closed) GroupAvatarRecoveryResult.Closed
                    else if(request.action==GroupAvatarRecoveryAction.CloseIfAbsent) { closed.add(request.command.operation);GroupAvatarRecoveryResult.Closed }
                    else GroupAvatarRecoveryResult.Unresolved
                return GroupAvatarRecoveryResponse(actor,device,request,result)
            }
        }
        var service=GroupAvatarIntentService(actor,device,commands,reader,store) { now }
        suspend fun start() { store.reconcileDirectory(persistentMapOf(room to RoomKind.Group));store.acceptState(room,RoomSyncState.newBuilder().setViewerMembershipRevision(1).setHead(30).build()) }
        suspend fun source(purpose: ResourceUsage=ResourceUsage.GroupAvatar(room)): ResourceLocalAsset {
            val bitmap=Bitmap.createBitmap(32,32,Bitmap.Config.ARGB_8888);val encoded=ByteString.newOutput()
            try { bitmap.eraseColor(android.graphics.Color.CYAN);assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG,100,encoded)) } finally { bitmap.recycle() }
            return files.importPhoto(PhotoPreparation().prepare(encoded.toByteString()),purpose)
        }
        suspend fun enqueue(image: Boolean=true)=service.enqueue(service.refresh(room),if(image) source() else null)
        suspend fun ready(intent: GroupAvatarIntent): ResourceUploadWork {
            val work=store.resourceUploads().first { it.id==intent.upload }
            return store.saveResourceUploadSession(work.id,ResourceUploadSession(ResourceUploadLocator(ResourceHome.Room(room),id()),work.request.media,1,
                ResourceSessionState.Completed,ResourceState.Ready,now+200000,now+100000,persistentListOf(),null))
        }
        fun imported(room: RoomId=this.room)=GroupAvatarImportPreparation(id(),ResourceImportRequest(id(),ResourceImportSource.Message(this.room,MessageId(id()),id()),ResourceUsage.GroupAvatar(room),id()))
        suspend fun importIntent(source: GroupAvatarImportPreparation=imported())=service.enqueueImported(service.refresh(room),source)
        suspend fun importReady(source: GroupAvatarImportPreparation,until: Long=now+100000) {
            val claim=store.claimResourceImport(source.id,id(),now)!!
            store.finishResourceImport(claim,ResourceImportStatus(source.request.locator(actor),source.request.targetMedia,ResourceImportState.Ready,until),now)
        }
        suspend fun work(id: String)=store.groupAvatarIntents().first { it.id==id }
        suspend fun reopen() { files.close();store.close();store=SqliteClientStore(context,actor,device);files=ManagedResourceFiles(context,store);service=GroupAvatarIntentService(actor,device,commands,reader,store) { now } }
        suspend fun close() { files.close();store.close() }
    }
    @Test fun uploadAndConsumerAreAtomicAndIndependentSourceSurvivesReopenAndUploadRelease()=runBlocking {
        val f=Fixture();try {
            f.start();val intent=f.enqueue();val upload=f.store.resourceUploads().single()
            assertEquals(intent.upload,upload.id);assertEquals(intent.command.mutation.mediaId,upload.request.media);assertEquals(ResourceUsage.GroupAvatar(f.room),upload.request.usage)
            assertTrue(f.files.selected(ResourceUsage.GroupAvatar(f.room)).isEmpty());assertNull(f.store.claimGroupAvatar(intent.id,f.now))
            fails { f.service.resolve(intent.id,GroupAvatarRecoveryAction.Query) };assertFalse(f.work(intent.id).submissionStarted)
            f.files.cleanup();assertEquals(1,f.store.resourceFiles().size);f.reopen();assertEquals(intent,f.work(intent.id))
            f.ready(intent);f.store.releaseResourceUploadSource(upload.id);f.files.cleanup();assertEquals(1,f.store.resourceFiles().size)
            f.service.recoverOnce();val committed=f.work(intent.id)
            assertEquals(GroupAvatarStage.Committed,committed.stage);assertTrue(committed.sourceReleased);assertEquals(intent.command,committed.command)
            f.files.cleanup();assertTrue(f.store.resourceFiles().isEmpty());assertEquals(committed,f.store.snapshot().groupAvatarIntents.single())
        } finally { f.close() }
    }
    @Test fun failedAdmissionPreservesSelectionAndCannotBypassCurrentAuthorityOrActiveRoom()=runBlocking {
        val f=Fixture();try {
            f.start();val baseline=f.service.refresh(f.room);val wrong=f.source(ResourceUsage.UserAvatar)
            fails { f.service.enqueue(baseline,wrong) };assertTrue(f.store.groupAvatarIntents().isEmpty());assertTrue(f.store.resourceUploads().isEmpty());assertTrue(f.store.resourceAssets().single().selectionActive)
            val intent=f.enqueue(false);val source=f.source();fails { f.service.enqueue(baseline,source) }
            assertTrue(f.store.resourceAssets().first { it.id==source.id }.selectionActive);assertTrue(f.store.resourceUploads().isEmpty())
            f.service.cancel(intent.id);f.store.acceptState(f.room,RoomSyncState.newBuilder().setViewerMembershipRevision(2).setHead(30).build())
            fails { f.service.enqueue(baseline,source) };assertTrue(f.store.resourceUploads().isEmpty())
        } finally { f.close() }
    }
    @Test fun lostCommitReopensAndRecoversOriginalWithoutAllocatingReplacementOrReleasingSourceEarly()=runBlocking {
        val f=Fixture();val diagnostics=NetworkDiagnostics();try {
            f.start();val intent=f.enqueue();f.ready(intent);f.lose=true;withContext(NetworkDiagnosticsScope(diagnostics)) {f.service.recoverOnce()}
            val uncertain=f.work(intent.id);assertTrue(uncertain.submissionStarted);assertEquals(GroupAvatarRecoveryAction.Query,uncertain.action);assertFalse(uncertain.sourceReleased)
            fails { f.service.cancel(intent.id) };fails { f.service.abandon(intent.id) };fails { f.service.replace(intent.id,f.service.refresh(f.room)) }
            f.reopen();f.now=uncertain.retryAt;withContext(NetworkDiagnosticsScope(diagnostics)) {f.service.recoverOnce()}
            val committed=f.work(intent.id);assertEquals(GroupAvatarStage.Committed,committed.stage);assertEquals(intent.command,committed.command);assertEquals(1,f.submits);assertEquals(1,f.recoveries)
            assertEquals(listOf(false,true),f.attempts.map {requireNotNull(it).isRetry})
            assertTrue(f.attempts.all {it?.priority==NetworkWorkPriority.Recovery})
            val samples=diagnostics.snapshot().operations
            assertEquals(listOf(OperationWorkAction.Submit,OperationWorkAction.Reconcile),samples.map {it.action})
            assertTrue(samples.all {it.kind==OperationKind.GroupAvatar && it.priority==NetworkWorkPriority.Recovery})
            assertEquals(NetworkMetric.Certainty.OutcomeUnknown,samples.first().certainty)
            assertEquals(OperationExecutionState.Committed,samples.last().observation?.execution)
            assertEquals(NetworkMetric.Certainty.ResponseReceived,samples.last().certainty)
            assertEquals(committed,f.store.groupAvatarIntent(intent.id));assertNull(f.store.groupAvatarIntent(id()))
            f.files.cleanup();assertTrue(f.store.resourceFiles().isEmpty())
        } finally { f.close() }
    }
    @Test fun unresolvedQueryMayResubmitOnlyOriginalFrozenCommand()=runBlocking {
        val f=Fixture();try {
            f.start();val intent=f.enqueue(false);f.loseBefore=true;f.service.recoverOnce();f.now=f.work(intent.id).retryAt
            f.service.recoverOnce();val absent=f.work(intent.id);assertNull(absent.action);assertFalse(absent.terminal);assertEquals(intent.command,absent.command)
            f.now=absent.retryAt;f.service.recoverOnce();assertEquals(GroupAvatarStage.Committed,f.work(intent.id).stage);assertEquals(2,f.submits);assertEquals(1,f.recoveries)
        } finally { f.close() }
    }
    @Test fun explicitClosureProofThenReplacementAllocatesFreshUploadMediaAndTransfersOriginalAtomically()=runBlocking {
        val f=Fixture();try {
            f.start();val original=f.enqueue();f.ready(original);f.remote=f.remote.copy(revision=2)
            f.service.recoverOnce();assertEquals(GroupAvatarRecoveryAction.CloseIfAbsent,f.work(original.id).action)
            fails { f.service.replace(original.id,f.service.refresh(f.room)) }
            f.service.recoverOnce();val closed=f.work(original.id);assertEquals(GroupAvatarStage.Closed,closed.stage);assertNotNull(closed.proof);assertFalse(closed.sourceReleased)
            f.files.cleanup();assertEquals(1,f.store.resourceFiles().size);f.reopen()
            val fresh=f.service.replace(original.id,f.service.refresh(f.room));assertNotEquals(original.id,fresh.id);assertNotEquals(original.upload,fresh.upload);assertNotEquals(original.command.mutation.mediaId,fresh.command.mutation.mediaId)
            assertEquals(2L,fresh.command.revision);assertEquals(original.asset,fresh.asset);assertEquals(GroupAvatarDisposition.Replaced,f.work(original.id).disposition)
            assertEquals(fresh.id,f.service.replace(original.id,f.service.refresh(f.room)).id);fails { f.service.abandon(original.id) }
            f.files.cleanup();assertEquals(1,f.store.resourceFiles().size);f.ready(fresh);f.service.recoverOnce();assertEquals(GroupAvatarStage.Committed,f.work(fresh.id).stage)
            f.files.cleanup();assertTrue(f.store.resourceFiles().isEmpty())
        } finally { f.close() }
    }
    @Test fun closeRequestIsMonotonicAndOlderFailureCannotOverwriteItButValidLateReceiptCanWin()=runBlocking {
        val f=Fixture();try {
            f.start();val original=f.enqueue(false);val claim=f.store.claimGroupAvatar(original.id,f.now)!!
            f.service.resolve(original.id,GroupAvatarRecoveryAction.CloseIfAbsent);f.service.resolve(original.id,GroupAvatarRecoveryAction.Query)
            f.store.failGroupAvatar(claim,GroupAvatarIssue.Forbidden,f.now,true)
            assertEquals(GroupAvatarRecoveryAction.CloseIfAbsent,f.work(original.id).action);assertNull(f.work(original.id).claim);assertEquals(0,f.work(original.id).attempts)
            val receipt=GroupAvatarChange(GroupAvatarState(f.room,null,1),1,f.now)
            f.store.finishGroupAvatar(claim,GroupAvatarCommandResponse(f.actor,f.device,original.command,GroupAvatarOutcome.Committed(receipt)),f.now)
            assertEquals(GroupAvatarStage.Committed,f.work(original.id).stage)
            f.store.failGroupAvatar(claim,GroupAvatarIssue.InvalidResponse,f.now,true);assertEquals(GroupAvatarStage.Committed,f.work(original.id).stage)
        } finally { f.close() }
    }
    @Test fun wrongProofOrDeviceCannotCloseAndClosedEvidenceCannotBeOverwrittenByContradictoryReceipt()=runBlocking {
        val f=Fixture();try {
            f.start();val original=f.enqueue(false);f.service.resolve(original.id,GroupAvatarRecoveryAction.CloseIfAbsent)
            val claim=f.store.claimGroupAvatar(original.id,f.now)!!
            val request=GroupAvatarRecoveryRequest(original.command,GroupAvatarRecoveryAction.CloseIfAbsent)
            fails { f.store.finishGroupAvatarRecovery(claim,GroupAvatarRecoveryResponse(f.actor,DeviceId(id()),request,GroupAvatarRecoveryResult.Closed),f.now) }
            fails { f.store.finishGroupAvatarRecovery(claim,GroupAvatarRecoveryResponse(f.actor,f.device,request.copy(action=GroupAvatarRecoveryAction.Query),GroupAvatarRecoveryResult.Closed),f.now) }
            assertEquals(claim.token,f.work(original.id).claim)
            f.store.finishGroupAvatarRecovery(claim,GroupAvatarRecoveryResponse(f.actor,f.device,request,GroupAvatarRecoveryResult.Closed),f.now)
            fails { f.store.finishGroupAvatar(claim,GroupAvatarCommandResponse(f.actor,f.device,original.command,GroupAvatarOutcome.Committed(GroupAvatarChange(GroupAvatarState(f.room,null,1),1,f.now))),f.now) }
            assertEquals(GroupAvatarStage.Closed,f.work(original.id).stage);f.service.abandon(original.id);assertEquals(GroupAvatarDisposition.Abandoned,f.work(original.id).disposition)
        } finally { f.close() }
    }
    @Test fun explicitDepartureCancelsUnsubmittedWorkButProjectionAbsenceIsNotDeparture()=runBlocking {
        val f=Fixture();try {
            f.start();val original=f.enqueue()
            val manifest=SnapshotManifest.newBuilder().setGeneration(2).setBaseUserSyncSequence(1).setNextSyncToken("reset").build()
            f.store.activateFixture(manifest,persistentListOf());f.store.prepareGroupAvatars(f.now)
            assertEquals(GroupAvatarStage.Preparing,f.work(original.id).stage);assertFalse(f.work(original.id).sourceReleased)
            f.start();f.store.unavailable(f.room);f.store.prepareGroupAvatars(f.now)
            assertEquals(GroupAvatarStage.Cancelled,f.work(original.id).stage);assertTrue(f.work(original.id).sourceReleased)
            assertTrue(f.store.resourceUploads().single().cancellationRequested);f.files.cleanup();assertEquals(1,f.store.resourceFiles().size) // The cancelling upload still owns its reference.
        } finally { f.close() }
    }
    @Test fun departureOfSubmittedWorkRequiresClosureAndAutomaticallyAbandonsOnlyAfterProof()=runBlocking {
        val f=Fixture();try {
            f.start();val original=f.enqueue(false);val claim=f.store.claimGroupAvatar(original.id,f.now)!!
            f.store.failGroupAvatar(claim,GroupAvatarIssue.OutcomeUnknown,f.now,false)
            f.store.unavailable(f.room);f.store.prepareGroupAvatars(f.now);assertEquals(GroupAvatarRecoveryAction.CloseIfAbsent,f.work(original.id).action)
            f.service.recoverOnce();assertEquals(GroupAvatarStage.Closed,f.work(original.id).stage);assertEquals(GroupAvatarDisposition.Abandoned,f.work(original.id).disposition)
        } finally { f.close() }
    }
    @Test fun retryCannotShortenServerCooldownAndExpiredCrashClaimsConsumeTheirOriginalAttempt()=runBlocking {
        val f=Fixture();try {
            f.start();val original=f.enqueue(false);val claim=f.store.claimGroupAvatar(original.id,f.now)!!
            f.reopen();assertNull(f.store.claimGroupAvatar(original.id,f.now));f.now+=30001;f.store.prepareGroupAvatars(f.now)
            assertEquals(1,f.work(original.id).attempts);assertEquals(GroupAvatarRecoveryAction.Query,f.work(original.id).action)
            val next=f.store.claimGroupAvatar(original.id,f.now)!!;f.store.failGroupAvatar(next,GroupAvatarIssue.Throttled,f.now+90000,true,f.now+90000)
            f.service.retry(original.id);assertNull(f.store.claimGroupAvatar(original.id,f.now));assertEquals(f.now+90000,f.work(original.id).retryAt)
            f.now+=90000;assertNotNull(f.store.claimGroupAvatar(original.id,f.now));assertEquals(original.command,f.work(original.id).command)
            f.store.failGroupAvatar(claim,GroupAvatarIssue.InvalidResponse,f.now,true);assertEquals(1,f.work(original.id).attempts)
        } finally { f.close() }
    }
    @Test fun foregroundWaitsForUploadEventsAndPublishesOnceWithoutPollingAnUnreadyDependency()=runBlocking {
        val f=Fixture();try {
            f.start();val original=f.enqueue();val worker=launch { f.service.runForeground() }
            try {
                delay(250);assertEquals(0,f.submits);assertEquals(0,f.work(original.id).attempts)
                f.ready(original)
                withTimeout(5000) { while(f.work(original.id).stage!=GroupAvatarStage.Committed) delay(20) }
                assertEquals(1,f.submits)
            } finally { worker.cancelAndJoin() }
            assertNull(f.work(original.id).claim)
        } finally { f.close() }
    }
    @Test fun exhaustedRoundClosesOriginalAndRepeatedClosureFailureWaitsAnotherMinute()=runBlocking {
        val f=Fixture();try {
            f.start();val original=f.enqueue(false)
            repeat(5) {
                val claim=f.store.claimGroupAvatar(original.id,f.now)!!
                f.store.failGroupAvatar(claim,GroupAvatarIssue.OutcomeUnknown,f.now,false)
            }
            assertEquals(GroupAvatarStage.NeedsAttention,f.work(original.id).stage)
            assertNull(f.store.claimGroupAvatar(original.id,f.now));f.store.prepareGroupAvatars(f.now)
            assertEquals(GroupAvatarRecoveryAction.CloseIfAbsent,f.work(original.id).action)
            repeat(5) {
                val claim=f.store.claimGroupAvatar(original.id,f.now)!!
                assertEquals(original.command,claim.intent.command)
                f.store.failGroupAvatar(claim,GroupAvatarIssue.OutcomeUnknown,f.now,false)
            }
            f.store.prepareGroupAvatars(f.now);assertEquals(f.now+60000,f.work(original.id).retryAt)
            assertTrue(f.store.dueGroupAvatars(f.now).isEmpty());f.now+=60000
            f.service.recoverOnce();assertEquals(GroupAvatarStage.Closed,f.work(original.id).stage)
        } finally { f.close() }
    }
    @Test fun foregroundOwnsTwoPhysicalCallsAndCancellationDrainsBeforeReleasingActivity()=runBlocking {
        val f=Fixture();val release=CompletableDeferred<Unit>();try {
            f.start();val rooms=listOf(f.room,RoomId(id()),RoomId(id()))
            f.store.reconcileDirectory(rooms.associateWith { RoomKind.Group }.toPersistentMap())
            rooms.drop(1).forEach { f.store.acceptState(it,RoomSyncState.newBuilder().setViewerMembershipRevision(1).setHead(30).build()) }
            val entered=kotlinx.coroutines.channels.Channel<GroupAvatarCommand>(3)
            val stalled=object: GroupAvatarCommands by f.commands {
                override suspend fun submit(command: GroupAvatarCommand): GroupAvatarCommandResponse {
                    entered.send(command)
                    withContext(NonCancellable) { release.await() }
                    throw java.io.IOException("physical request ended without receipt")
                }
            }
            val service=GroupAvatarIntentService(f.actor,f.device,stalled,f.reader,f.store) { f.now }
            rooms.forEach { service.enqueue(service.refresh(it)) }
            val worker=launch { service.runForeground() }
            try {
                withTimeout(5000) { entered.receive();entered.receive() }
                delay(100);assertTrue(entered.tryReceive().isFailure)
                worker.cancel();delay(100);assertFalse(worker.isCompleted)
                assertEquals(2,f.store.groupAvatarIntents().count { it.claim!=null })
                release.complete(Unit);withTimeout(5000) { worker.join() }
                assertTrue(entered.tryReceive().isFailure)
                assertTrue(f.store.groupAvatarIntents().all { it.claim==null })
                assertEquals(2,f.store.groupAvatarIntents().count { it.action==GroupAvatarRecoveryAction.Query })
            } finally { release.complete(Unit);worker.cancelAndJoin();entered.close() }
        } finally { release.complete(Unit);f.close() }
    }

    @Test fun importAdmissionChecksTargetAuthorityAndActiveRoomBeforeAdoptingAnything()=runBlocking<Unit> {
        val f=Fixture();try {
            f.start();val authority=f.service.refresh(f.room);val wrong=f.imported(RoomId(id()))
            fails {f.service.enqueueImported(authority,wrong)};assertTrue(f.store.resourceImports().isEmpty())
            val source=f.imported();val intent=f.service.enqueueImported(authority,source)
            assertEquals(intent,f.store.enqueueImportedGroupAvatar(authority,intent.command,source,f.now))
            assertEquals(source,f.work(intent.id).serverImport);assertNull(intent.upload);assertFalse(intent.sourceReleased)
            fails {f.store.cancelResourceImport(source.id)};fails {f.store.releaseResourceImport(source.id)}
            fails {f.service.enqueueImported(authority,f.imported())};assertEquals(1,f.store.resourceImports().size)
            f.service.cancel(intent.id)
            f.store.acceptState(f.room,RoomSyncState.newBuilder().setViewerMembershipRevision(2).setHead(30).build())
            fails {f.service.enqueueImported(authority,f.imported())};assertEquals(1,f.store.resourceImports().size)
            fails {f.service.enqueueImported(authority.copy(presentation=authority.presentation.copy(actor=UserId(id()))),f.imported())}
            assertEquals(1,f.store.groupAvatarIntents().size)
        } finally {f.close()}
    }
    @Test fun coldImportOwnerWaitsForReadyAndUnknownAcceptedCommandRecoversAfterBindingExpires()=runBlocking<Unit> {
        val f=Fixture();try {
            f.start();val source=f.imported();val original=f.importIntent(source)
            f.service.recoverOnce();assertEquals(0,f.submits);assertNull(f.store.claimGroupAvatar(original.id,f.now));f.reopen()
            assertEquals(original,f.work(original.id));f.importReady(source,f.now+10);f.lose=true;f.service.recoverOnce()
            assertEquals(1,f.submits);assertFalse(f.work(original.id).sourceReleased)
            fails {f.service.cancel(original.id)};fails {f.store.cancelResourceImport(source.id)}
            f.now+=5000;f.reopen();f.service.recoverOnce()
            val committed=f.work(original.id);assertEquals(GroupAvatarStage.Committed,committed.stage);assertEquals(original.command,committed.command)
            assertEquals(1,f.submits);assertEquals(1,f.recoveries);assertTrue(committed.sourceReleased)
            assertTrue(f.store.resourceImports().single().businessBound);assertFalse(f.store.resourceImports().single().cancellationRequested)
            fails {f.store.cancelResourceImport(source.id)}
        } finally {f.close()}
    }
    @Test fun closedPendingImportIsSharedUntilEveryGroupAvatarConsumerReleasesIt()=runBlocking<Unit> {
        val f=Fixture();try {
            f.start();val source=f.imported();val first=f.importIntent(source)
            f.service.resolve(first.id,GroupAvatarRecoveryAction.CloseIfAbsent);f.service.recoverOnce()
            assertEquals(GroupAvatarStage.Closed,f.work(first.id).stage);assertFalse(f.work(first.id).sourceReleased)
            val second=f.importIntent(source);assertNotEquals(first.id,second.id);f.reopen()
            f.service.cancel(second.id);assertFalse(f.store.resourceImports().single().cancellationRequested)
            fails {f.store.cancelResourceImport(source.id)}
            f.service.abandon(first.id);assertTrue(f.store.resourceImports().single().cancellationRequested)
            assertTrue(f.store.groupAvatarIntents().all {it.sourceReleased})
        } finally {f.close()}
    }
    @Test fun closedExpiredImportReplacementUsesFreshTargetAndOriginalSourceExactlyOnce()=runBlocking<Unit> {
        val f=Fixture();try {
            f.start();val source=f.imported();val original=f.importIntent(source);f.importReady(source,f.now-1)
            f.service.recoverOnce();assertEquals(0,f.submits);assertEquals(GroupAvatarStage.NeedsAttention,f.work(original.id).stage)
            f.service.resolve(original.id,GroupAvatarRecoveryAction.CloseIfAbsent);f.service.recoverOnce()
            val replacement=f.service.replace(original.id,f.service.refresh(f.room));f.reopen()
            assertEquals(replacement,f.service.replace(original.id,f.service.refresh(f.room)))
            val imported=replacement.serverImport!!;assertNotEquals(source.id,imported.id);assertNotEquals(source.request.operation,imported.request.operation)
            assertNotEquals(source.request.targetMedia,imported.request.targetMedia);assertEquals(source.request.source,imported.request.source)
            assertEquals(GroupAvatarDisposition.Replaced,f.work(original.id).disposition);assertTrue(f.store.resourceImports().first {it.id==source.id}.cancellationRequested)
            f.importReady(imported);f.service.recoverOnce();assertEquals(GroupAvatarStage.Committed,f.work(replacement.id).stage)
            assertEquals(1,f.submits);assertEquals(2,f.store.resourceImports().size)
        } finally {f.close()}
    }
    @Test fun departingOrCancellingPreparationCannotLetLateReadySubmitAvatar()=runBlocking<Unit> {
        for(depart in listOf(false,true)) {
            val f=Fixture();try {
                f.start();val source=f.imported();val intent=f.importIntent(source);val claim=f.store.claimResourceImport(source.id,id(),f.now)!!
                if(depart) {f.store.unavailable(f.room);assertNull(f.store.claimGroupAvatar(intent.id,f.now));f.service.recoverOnce()} else f.service.cancel(intent.id)
                f.store.finishResourceImport(claim,ResourceImportStatus(source.request.locator(f.actor),source.request.targetMedia,ResourceImportState.Ready,f.now+100000),f.now)
                f.reopen();f.service.recoverOnce();assertEquals(0,f.submits);assertEquals(GroupAvatarStage.Cancelled,f.work(intent.id).stage)
                assertTrue(f.store.resourceImports().single().cancellationRequested);assertFalse(f.store.resourceImports().single().businessBound)
            } finally {f.close()}
        }
    }
    @Test fun importPauseRetainsRoundAndLateReadyResumesParentWithoutPollingWrites()=runBlocking<Unit> {
        val f=Fixture();try {
            f.start();val source=f.imported();val intent=f.importIntent(source)
            val claim=f.store.claimResourceImport(source.id,id(),f.now)!!;f.store.controlResourceImport(source.id,true)
            f.service.recoverOnce();assertEquals(GroupAvatarStage.NeedsAttention,f.work(intent.id).stage);assertEquals(0,f.submits)
            val revision=f.store.groupAvatarIntentChanges.value;f.service.recoverOnce();assertEquals(revision,f.store.groupAvatarIntentChanges.value)
            f.store.finishResourceImport(claim,ResourceImportStatus(source.request.locator(f.actor),source.request.targetMedia,ResourceImportState.Ready,f.now+100000),f.now)
            f.reopen();f.service.recoverOnce();assertEquals(GroupAvatarStage.Committed,f.work(intent.id).stage);assertEquals(1,f.submits)
        } finally {f.close()}
    }
    @Test fun committedSharedImportCannotBeCancelledByAbandoningAnOlderClosedDecision()=runBlocking<Unit> {
        val f=Fixture();try {
            f.start();val source=f.imported();val old=f.importIntent(source)
            f.service.resolve(old.id,GroupAvatarRecoveryAction.CloseIfAbsent);f.service.recoverOnce()
            val next=f.importIntent(source);f.importReady(source);f.service.recoverOnce()
            assertEquals(GroupAvatarStage.Committed,f.work(next.id).stage);assertTrue(f.store.resourceImports().single().businessBound)
            f.service.abandon(old.id);assertFalse(f.store.resourceImports().single().cancellationRequested)
            f.reopen();assertTrue(f.store.resourceImports().single().businessBound);fails {f.store.cancelResourceImport(source.id)}
        } finally {f.close()}
    }
    @Test fun groupAvatarHistoryKeepsItsImportedJobWhenUnownedTransferHistoryIsPruned()=runBlocking<Unit> {
        val f=Fixture();try {
            f.start();val source=f.imported();val intent=f.importIntent(source);f.importReady(source);f.service.recoverOnce()
            val digest=java.security.MessageDigest.getInstance("SHA-256").digest("${f.actor.value}/${f.device.value}".toByteArray()).joinToString("") {"%02x".format(it)}
            val path=java.io.File(context.noBackupFilesDir,"im-$digest.db").path
            android.database.sqlite.SQLiteDatabase.openDatabase(path,null,android.database.sqlite.SQLiteDatabase.OPEN_READWRITE).use {db->
                db.beginTransaction();try {
                    repeat(505) {
                        val value=f.imported();val request=value.request
                        val status=ResourceImportStatus(request.locator(f.actor),request.targetMedia,ResourceImportState.Ready,f.now+100000)
                        db.execSQL("INSERT INTO resource_imports(id,operation,media,request,status,created,retained) VALUES (?,?,?,?,?,?,0)",
                            arrayOf<Any>(value.id,request.operation,request.targetMedia,request.payload().toString(),status.payload().toString(),f.now))
                    }
                    db.setTransactionSuccessful()
                } finally {db.endTransaction()}
            }
            f.store.releaseResourceImport(source.id);f.reopen()
            assertEquals(501,f.store.resourceImports().size);assertTrue(f.store.resourceImports().first {it.id==source.id}.businessBound)
            assertEquals(source,f.work(intent.id).serverImport)
        } finally {f.close()}
    }
    @Test fun businessOwnerPagesKeepClosedDecisionsAndRejectWrongRoomAcrossMigration()=runBlocking<Unit> {
        val f=Fixture();try {
            f.start();val source=f.imported();val first=f.importIntent(source)
            f.service.resolve(first.id,GroupAvatarRecoveryAction.CloseIfAbsent);f.service.recoverOnce()
            val second=f.importIntent(source);f.service.resolve(second.id,GroupAvatarRecoveryAction.CloseIfAbsent);f.service.recoverOnce()
            val third=f.importIntent(source);val key=ResourceTransferId(ResourceTransferKind.ServerImport,source.id)
            val expected=listOf(first,second,third).sortedByDescending {it.id}.map {ResourceBusinessOwner.Group(f.room,it.id)}
            val actual=mutableListOf<ResourceBusinessOwner>();var cursor:ResourceBusinessOwnerCursor?=null
            do {val page=f.store.resourceBusinessOwners(ResourceBusinessOwnerQuery(key,cursor,1));actual+=page.entries.map {it.owner};cursor=page.next} while(cursor!=null)
            assertEquals(expected,actual);assertFalse(f.store.resourceHasBusinessOwner(key,ResourceBusinessOwner.Group(RoomId(id()),first.id)))
            assertTrue(f.store.resourceBusinessOwners(ResourceBusinessOwnerQuery(key.copy(kind=ResourceTransferKind.Download))).entries.isEmpty())
            val path=java.io.File(context.noBackupFilesDir,"im-${f.store.resourceScope}.db");f.files.close();f.store.close()
            android.database.sqlite.SQLiteDatabase.openDatabase(path.path,null,0).use {db->
                db.execSQL("CREATE TABLE group_avatar_old(id TEXT PRIMARY KEY,room TEXT NOT NULL,upload_id TEXT,replacement_of TEXT UNIQUE,payload TEXT NOT NULL,import_id TEXT)")
                db.execSQL("INSERT INTO group_avatar_old SELECT id,room,upload_id,replacement_of,payload,import_id FROM group_avatar_intents")
                db.execSQL("DROP TABLE group_avatar_intents");db.execSQL("ALTER TABLE group_avatar_old RENAME TO group_avatar_intents")
            }
            f.reopen();assertEquals(expected,f.store.resourceBusinessOwners(ResourceBusinessOwnerQuery(key)).entries.map {it.owner})
            f.service.abandon(first.id);assertFalse(f.store.resourceHasBusinessOwner(key,ResourceBusinessOwner.Group(f.room,first.id)))
            assertFalse(f.store.resourceImports().single().cancellationRequested)
            f.service.cancel(third.id);f.service.abandon(second.id);assertTrue(f.store.resourceBusinessOwners(ResourceBusinessOwnerQuery(key)).entries.isEmpty())
            assertFalse(f.store.resourceTransfers().entries.first {it.id==key}.hasBusinessOwners)
        } finally {f.close()}
    }
}

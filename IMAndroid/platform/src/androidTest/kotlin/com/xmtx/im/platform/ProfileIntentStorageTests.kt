package com.xmtx.im.platform

import android.graphics.Bitmap
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class ProfileIntentStorageTests {
    private val context=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private inner class Fixture(private val limits: OperationAdmissionLimits = OperationAdmissionLimits()) {
        val actor=UserId(id());val device=DeviceId(id());var now=1700000000000L
        var store=SqliteClientStore(context,actor,device,operationLimits=limits);var files=ManagedResourceFiles(context,store)
        var remote=ProfileView(actor,PublicIdentity(actor,PublicHandle("profile_intent"),"原名称",AccountKind.Regular),null,ProfileState.Active,1,1)
        var lose=false;var submissions=0;var recoveries=0;var reads=0
        val results=mutableMapOf<String,OwnProfileResult.Receipt>()
        val transport=object: OwnProfileTransport {
            override suspend fun current(): ProfileView { reads++;return remote }
            override suspend fun submit(command: OwnProfileCommand): OwnProfileResult.Receipt {
                submissions++;val result=results.getOrPut(command.operation) {
                    val conflict=command.revision!=remote.revision
                    if(!conflict) remote=remote.copy(revision=remote.revision+1,visibilityRevision=remote.visibilityRevision+1,
                        identity=remote.identity!!.copy(displayName=command.patch.name ?: remote.identity!!.displayName),
                        avatarMediaId=when(val patch=command.patch.avatar) { ProfileAvatarPatch.Unchanged->remote.avatarMediaId;ProfileAvatarPatch.Remove->null;is ProfileAvatarPatch.Set->patch.media })
                    receipt(command,conflict)
                }
                if(lose) { lose=false;throw java.io.IOException("lost reply") };return result
            }
            override suspend fun recover(command: OwnProfileCommand,close: Boolean): OwnProfileResult { recoveries++;return results[command.operation] ?: OwnProfileResult.Unresolved }
        }
        var own=OwnProfileService(actor,transport,store) { now }
        var service=ProfileIntentService(actor,own,store) { now }
        private fun receipt(command: OwnProfileCommand,conflict: Boolean)=OwnProfileClient.decodeResult(command,buildJsonObject {
            put("receipt",buildJsonObject {
                put("actorUserID",buildJsonObject { put("rawValue",actor.value) });put("operationID",buildJsonObject { put("rawValue",command.operation) })
                put("fingerprint",buildJsonObject { put("version",1);put("digest",command.fingerprint) });put("resolvedAtMilliseconds",now)
                put("outcome",buildJsonObject {
                    if(conflict) put("rejected",buildJsonObject { put("_0",buildJsonObject { put("revisionConflict",buildJsonObject { put("current",remote.revision) }) }) })
                    else put("committed",buildJsonObject { put("revision",remote.revision);put("visibilityRevision",remote.visibilityRevision) })
                })
            });put("currentSnapshot",OwnProfileClient.profilePayload(remote))
        })
        suspend fun source(): ProfileAvatarUpload {
            val bitmap=Bitmap.createBitmap(32,32,Bitmap.Config.ARGB_8888);val bytes=ByteString.newOutput()
            try { bitmap.eraseColor(android.graphics.Color.BLUE);assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG,100,bytes)) } finally { bitmap.recycle() }
            val asset=files.importPhoto(PhotoPreparation().prepare(bytes.toByteString()),ResourceUsage.UserAvatar)
            return ProfileAvatarUpload(id(),asset.id,asset.displayName,asset.contentType,asset.byteCount)
        }
        suspend fun avatar(): ProfileIntent { val base=service.refresh();return service.enqueue(base,upload=source()) }
        suspend fun ready(intent: ProfileIntent,until: Long=now+100000): ResourceUploadWork {
            service.prepareNext();val work=store.resourceUploads().first { it.id==intent.upload!!.id }
            return store.saveResourceUploadSession(work.id,ResourceUploadSession(ResourceUploadLocator(ResourceHome.Account(actor),id()),work.request.media,1,
                ResourceSessionState.Completed,ResourceState.Ready,now+200000,until,persistentListOf(),null))
        }
        suspend fun cancelled(work: ResourceUploadWork) {
            store.requestResourceUploadCancellation(work.id)
            store.confirmResourceUploadCancellation(work.id,ResourceUploadSession(ResourceUploadLocator(ResourceHome.Account(actor),id()),work.request.media,1,
                ResourceSessionState.Cancelled,ResourceState.Pending,now+200000,null,persistentListOf(),null))
        }
        fun importSource()=ProfileAvatarImport(id(),ResourceImportRequest(id(),ResourceImportSource.Avatar(ProfileKey(actor,ProfileContext.Relationship),id(),id()),ResourceUsage.UserAvatar,id()))
        suspend fun imported()=service.enqueueImportedAvatar(service.refresh(),importSource())
        suspend fun importReady(intent: ProfileIntent,until: Long=now+100000) {
            val source=intent.serverImport!!;val claim=store.claimResourceImport(source.id,id(),now)!!
            store.finishResourceImport(claim,ResourceImportStatus(source.request.locator(actor),source.request.targetMedia,ResourceImportState.Ready,until),now)
        }
        suspend fun reopen() {
            files.close();store.close();store=SqliteClientStore(context,actor,device,operationLimits=limits);files=ManagedResourceFiles(context,store)
            own=OwnProfileService(actor,transport,store) { now };service=ProfileIntentService(actor,own,store) { now }
        }
        suspend fun close() { files.close();store.close() }
    }
    private suspend fun fails(body: suspend ()->Unit) { assertNotNull(runCatching { body() }.exceptionOrNull()) }

    @Test fun intentOwnsOriginalAcrossReopenAndUploadReleaseUntilVerifiedCommit()=runBlocking {
        val f=Fixture();try {
            val intent=f.avatar();val source=intent.upload!!
            assertTrue(f.files.selected(ResourceUsage.UserAvatar).isEmpty());assertTrue(f.store.resourceUploads().isEmpty())
            f.files.cleanup();assertEquals(1,f.store.resourceFiles().size);f.reopen()
            assertEquals(intent,f.store.profileIntents().single().intent)
            f.files.withOriginal(profile=ProfileOriginalConsumer(intent.id)) { assertTrue(it.length()>0) }
            val ready=f.ready(intent);assertEquals(source.id,ready.request.operation);assertEquals(source.id,ready.request.media)
            f.store.releaseResourceUploadSource(ready.id);f.files.cleanup();assertEquals(1,f.store.resourceFiles().size)
            f.service.prepareNext();val work=f.store.ownProfileWorks().single();assertEquals(intent.operation,work.command.operation);assertEquals(intent.revision,work.command.revision)
            assertEquals(ProfileAvatarPatch.Set(source.id),work.command.patch.avatar)
            val execution=f.store.operationWork(intent.operation)!!
            assertEquals(OperationKind.ProfileUpdate,execution.kind);assertEquals(f.now,execution.originalCreatedAt)
            assertEquals(work.command.fingerprint,execution.fingerprint)
            f.own.flush();assertEquals(ProfileIntentPhase.Committed,f.store.profileIntents().single().phase)
            assertEquals(OperationExecutionState.Committed,f.store.operationWork(intent.operation)!!.execution)
            assertFalse(f.store.profileIntents().single().sourceRetained);f.files.cleanup();assertTrue(f.store.resourceFiles().isEmpty())
            assertEquals(source.id,f.store.snapshot().ownProfile!!.avatarMediaId)
        } finally { f.close() }
    }

    @Test fun unknownProfileReplyKeepsIdentityAndSourceAcrossReopen()=runBlocking {
        val f=Fixture();try {
            val intent=f.avatar();f.ready(intent);f.service.prepareNext();f.lose=true;f.own.flush()
            val uncertain=f.store.ownProfileWorks().single();assertTrue(uncertain.reconcile);assertTrue(uncertain.submissionStarted)
            fails { f.service.discard(intent.id) };assertEquals(intent.id,f.service.resumeOrReapply(intent.id).id);assertEquals(1,f.reads)
            f.reopen();f.now+=4000;f.own.flush()
            assertEquals(1,f.submissions);assertEquals(1,f.recoveries);assertEquals(uncertain.command,f.store.ownProfileWorks().single().command)
            assertEquals(ProfileIntentPhase.Committed,f.store.profileIntents().single().phase);f.files.cleanup();assertTrue(f.store.resourceFiles().isEmpty())
        } finally { f.close() }
    }

    @Test fun capturedRevisionConflictsThenExplicitReplacementAdoptsReadySourceAtomically()=runBlocking {
        val f=Fixture();try {
            val intent=f.avatar();f.ready(intent)
            f.remote=f.remote.copy(revision=2,visibilityRevision=2,identity=f.remote.identity!!.copy(displayName="另一设备"));f.service.refresh()
            f.service.prepareNext();assertEquals(1L,f.store.ownProfileWorks().single().command.revision);f.own.flush()
            assertEquals(OwnProfileStatus.Conflicted,f.store.ownProfileWorks().single().status)
            fails { f.own.reapply(intent.operation) }
            val next=f.service.resumeOrReapply(intent.id);assertNotEquals(intent.operation,next.operation);assertEquals(2L,next.revision);assertEquals(intent.upload,next.upload)
            assertFalse(f.store.profileIntents().first().sourceRetained);f.files.cleanup();assertEquals(1,f.store.resourceFiles().size)
            f.files.withOriginal(profile=ProfileOriginalConsumer(next.id)) { assertTrue(it.exists()) }
            f.service.prepareNext();f.own.flush();assertEquals(ProfileIntentPhase.Committed,f.store.profileIntents().last().phase)
            assertEquals(intent.revision,f.store.ownProfileWorks().first().command.revision);f.files.cleanup();assertTrue(f.store.resourceFiles().isEmpty())
        } finally { f.close() }
    }

    @Test fun expiredBindingRenewsUploadButRetainsTheSameOriginal()=runBlocking {
        val f=Fixture();try {
            val intent=f.avatar();f.ready(intent,f.now+10);f.now+=11;f.service.prepareNext()
            assertEquals(ProfilePreparation.Expired,f.store.profileIntents().single().intent.preparation);assertTrue(f.store.ownProfileWorks().isEmpty())
            val next=f.service.resumeOrReapply(intent.id);assertNotEquals(intent.upload!!.id,next.upload!!.id);assertEquals(intent.upload!!.asset,next.upload!!.asset)
            assertTrue(f.store.resourceUploads().single().sourceReleased);f.files.cleanup();assertEquals(1,f.store.resourceFiles().size)
            f.ready(next);f.service.prepareNext();f.own.flush();f.files.cleanup();assertTrue(f.store.resourceFiles().isEmpty())
        } finally { f.close() }
    }

    @Test fun failedTransferReplacementAndDiscardKeepUnknownCancellationBytes()=runBlocking {
        val f=Fixture();try {
            val intent=f.avatar();f.service.prepareNext();f.cancelled(f.store.resourceUploads().single());f.service.prepareNext()
            assertEquals(ProfilePreparation.Failed,f.store.profileIntents().single().intent.preparation)
            val next=f.service.resumeOrReapply(intent.id);assertNotEquals(intent.upload!!.id,next.upload!!.id)
            f.service.prepareNext();val pending=f.store.resourceUploads().last();f.service.discard(next.id)
            assertTrue(f.store.resourceUploads().last().cancellationRequested);assertFalse(f.store.resourceUploads().last().sourceReleased)
            f.files.cleanup();assertEquals(1,f.store.resourceFiles().size)
            f.cancelled(pending);f.service.prepareNext();f.files.cleanup();assertTrue(f.store.resourceFiles().isEmpty())
        } finally { f.close() }
    }

    @Test fun deadlineUnblocksOrderedNameIntentWithoutChangingItsCapturedBase()=runBlocking {
        val f=Fixture();try {
            val first=f.avatar();f.now+=1000;val next=f.service.enqueue(f.remote,name="排队名称")
            f.service.prepareNext();f.service.prepareNext();assertTrue(f.store.ownProfileWorks().isEmpty())
            fails { f.own.save(f.remote,OwnProfilePatch("绕过准备队列")) }
            f.now=first.deadline+1;f.service.prepareNext();f.service.prepareNext()
            assertEquals(ProfilePreparation.Expired,f.store.profileIntents().first().intent.preparation)
            assertEquals(next.operation,f.store.ownProfileWorks().single().command.operation)
            assertEquals(next.revision,f.store.ownProfileWorks().single().command.revision)
            f.own.flush();assertEquals("排队名称",f.remote.identity!!.displayName)
            assertTrue(f.store.profileIntents().first().sourceRetained)
        } finally { f.close() }
    }

    @Test fun capacityAndInvalidMetadataRollBackWithoutConsumingSelection()=runBlocking {
        val f=Fixture(OperationAdmissionLimits(maximumActiveCount=16));try {
            f.service.refresh();val source=f.source()
            fails { f.service.enqueue(f.remote,upload=source.copy(displayName="其他.jpg")) }
            assertTrue(f.store.profileIntents().isEmpty());assertEquals(source.asset,f.files.selected(ResourceUsage.UserAvatar).single().id)
            repeat(4) { f.own.save(f.remote,OwnProfilePatch("已有名称 $it")) }
            repeat(12) { f.service.enqueue(f.remote,name="排队名称 $it") }
            try { f.service.enqueue(f.remote,upload=source);fail("Shared operation capacity was bypassed") }
            catch (_: OperationCapacityExceeded) { }
            assertEquals(12,f.store.profileIntents().size)
            assertEquals(source.asset,f.files.selected(ResourceUsage.UserAvatar).single().id)
        } finally { f.close() }
    }

    @Test fun preparationWakesOnResourceChangesAndDoesNotSpinWhileWaiting()=runBlocking {
        val f=Fixture();val worker=launch { f.service.runPreparation() }
        try {
            val intent=f.avatar()
            withTimeout(5000) { while(f.store.resourceUploads().isEmpty()) delay(10) }
            delay(100);val generation=f.store.profileIntentChanges.value;delay(100);assertEquals(generation,f.store.profileIntentChanges.value)
            f.ready(intent)
            withTimeout(5000) { while(f.store.ownProfileWorks().isEmpty()) delay(10) }
            assertEquals(intent.operation,f.store.ownProfileWorks().single().command.operation)
        } finally { worker.cancelAndJoin();f.close() }
    }

    @Test fun explicitRetryKeepsUploadIdentityAndServerRetryFloor()=runBlocking {
        val f=Fixture();try {
            val intent=f.avatar();f.service.prepareNext();val upload=f.store.resourceUploads().single()
            val claim=f.store.claimResourceUpload(upload.id,id(),f.now)!!
            f.store.failResourceUpload(claim,ResourceUploadError.Transport,null,f.now+50000)
            f.service.prepareNext();assertEquals(ProfilePreparation.NeedsAttention,f.store.profileIntents().single().intent.preparation)
            assertEquals(intent.id,f.service.resumeOrReapply(intent.id).id)
            val resumed=f.store.resourceUploads().single();assertEquals(upload.request,resumed.request)
            assertFalse(resumed.execution.attention);assertEquals(f.now+50000,resumed.execution.retryAt)
            assertNull(f.store.claimResourceUpload(upload.id,id(),f.now))
        } finally { f.close() }
    }

    @Test fun fullUploadQueueDefersPreparationWithoutLosingItsSource()=runBlocking {
        val f=Fixture();try {
            f.service.refresh()
            repeat(32) {
                val source=f.source();val asset=f.store.resourceAssets().first { it.id==source.asset }
                f.store.prepareResourceUpload(source.id,asset.id,ResourceUploadRequest(source.id,source.id,asset.purpose,asset.contentType,asset.byteCount,asset.checksum,displayName=asset.displayName))
            }
            val intent=f.service.enqueue(f.remote,upload=f.source());assertFalse(f.service.prepareNext())
            assertEquals(ProfilePreparation.Pending,f.store.profileIntents().single().intent.preparation)
            f.cancelled(f.store.resourceUploads().first());assertTrue(f.service.prepareNext())
            assertEquals(intent.upload!!.id,f.store.resourceUploads().last().id)
            f.files.withOriginal(profile=ProfileOriginalConsumer(intent.id)) { assertTrue(it.exists()) }
        } finally { f.close() }
    }
    @Test fun importedAvatarAdmissionAndConsumerAreAtomicAndCommitProtectsBoundMedia()=runBlocking {
        val f=Fixture();try {
            val intent=f.imported();val source=intent.serverImport!!
            assertEquals(ProfileIntentPhase.PreparingAvatar,f.store.profileIntents().single().phase);assertEquals(source.request,f.store.resourceImports().single().request)
            assertFalse(f.store.resourceImports().single().retained);assertTrue(f.store.resourceUploads().isEmpty());assertFalse(f.service.prepareNext());assertTrue(f.store.ownProfileWorks().isEmpty())
            fails { f.store.cancelResourceImport(source.id) };fails { f.store.releaseResourceImport(source.id) }
            fails { f.service.enqueueImportedAvatar(f.service.refresh(),source) };assertEquals(1,f.store.profileIntents().size)
            f.reopen();assertEquals(intent,f.store.profileIntents().single().intent);f.importReady(intent)
            fails { f.store.releaseResourceImport(source.id) };assertTrue(f.service.prepareNext())
            val command=f.store.ownProfileWorks().single().command;assertEquals(source.request.targetMedia,(command.patch.avatar as ProfileAvatarPatch.Set).media);assertEquals(intent.operation,command.operation)
            fails { f.service.discard(intent.id) };fails { f.store.cancelResourceImport(source.id) }
            f.own.flush();val done=f.store.profileIntents().single();assertEquals(ProfileIntentPhase.Committed,done.phase);assertFalse(done.sourceRetained)
            assertTrue(f.store.resourceImports().single().businessBound);assertFalse(f.store.resourceImports().single().bindable(f.now));fails { f.store.cancelResourceImport(source.id) }
            assertFalse(f.service.prepareNext());f.reopen();assertTrue(f.store.resourceImports().single().businessBound);assertFalse(f.service.prepareNext())
        } finally { f.close() }
    }
    @Test fun unknownImportedProfileCommitRetainsConsumerUntilOriginalReceiptRecovers()=runBlocking {
        val f=Fixture();try {
            val intent=f.imported();f.importReady(intent);f.service.prepareNext();f.lose=true;f.own.flush()
            assertTrue(f.store.profileIntents().single().sourceRetained);assertFalse(f.store.resourceImports().single().businessBound)
            fails { f.service.discard(intent.id) };fails { f.store.cancelResourceImport(intent.serverImport!!.id) }
            val work=f.store.ownProfileWorks().single();f.reopen();f.now=work.nextAttempt
            f.own.flush();assertEquals(1,f.submissions);assertEquals(1,f.recoveries);assertEquals(ProfileIntentPhase.Committed,f.store.profileIntents().single().phase)
            assertEquals(intent.operation,f.store.ownProfileWorks().single().command.operation);assertTrue(f.store.resourceImports().single().businessBound)
        } finally { f.close() }
    }
    @Test fun retryUnknownImportPreservesOriginalRequestAndServerCooldown()=runBlocking {
        val f=Fixture();try {
            val intent=f.imported();val source=intent.serverImport!!;val floor=f.now+10000
            val claim=f.store.claimResourceImport(source.id,id(),f.now)!!;f.store.failResourceImport(claim,ResourceImportIssue.Unknown,null,floor)
            f.service.prepareNext();assertEquals(ProfilePreparation.NeedsAttention,f.store.profileIntents().single().intent.preparation)
            f.reopen();val resumed=f.service.resumeOrReapply(intent.id);assertEquals(intent.id,resumed.id);assertEquals(source,resumed.serverImport)
            assertEquals(1,f.store.resourceImports().size);assertEquals(floor,f.store.resourceImports().single().execution.serverRetryAt);assertNull(f.store.claimResourceImport(source.id,id(),floor-1))
            f.now=floor;f.importReady(intent);f.service.prepareNext();assertEquals(source.request.targetMedia,(f.store.ownProfileWorks().single().command.patch.avatar as ProfileAvatarPatch.Set).media)
        } finally { f.close() }
    }
    @Test fun rejectedProfileReapplicationUsesFreshImportAndMediaWhileKeepingSourceContext()=runBlocking {
        val f=Fixture();try {
            val intent=f.imported();f.importReady(intent);f.remote=f.remote.copy(revision=2,visibilityRevision=2);f.service.prepareNext();f.own.flush()
            assertEquals(OwnProfileStatus.Conflicted,f.store.ownProfileWorks().single().status);val original=intent.serverImport!!
            val next=f.service.resumeOrReapply(intent.id);val fresh=next.serverImport!!
            assertNotEquals(intent.operation,next.operation);assertEquals(2L,next.revision);assertNotEquals(original.id,fresh.id)
            assertNotEquals(original.request.operation,fresh.request.operation);assertNotEquals(original.request.targetMedia,fresh.request.targetMedia);assertEquals(original.request.source,fresh.request.source)
            assertFalse(f.store.profileIntents().first { it.intent.id==intent.id }.sourceRetained);assertTrue(f.store.resourceImports().first { it.id==original.id }.cancellationRequested)
            fails { f.store.cancelResourceImport(fresh.id) };f.importReady(next);f.service.prepareNext();f.own.flush()
            assertEquals(ProfileIntentPhase.Committed,f.store.profileIntents().first { it.intent.id==next.id }.phase);assertTrue(f.store.resourceImports().first { it.id==fresh.id }.businessBound)
        } finally { f.close() }
    }
    @Test fun discardingDuringImportKeepsCancellationAndLateReadyCannotFreezeProfile()=runBlocking {
        val f=Fixture();try {
            val intent=f.imported();val source=intent.serverImport!!;val claim=f.store.claimResourceImport(source.id,id(),f.now)!!
            f.service.discard(intent.id);assertTrue(f.store.resourceImports().single().cancellationRequested)
            f.store.finishResourceImport(claim,ResourceImportStatus(source.request.locator(f.actor),source.request.targetMedia,ResourceImportState.Ready,f.now+100000),f.now)
            f.reopen();f.service.prepareNext();assertTrue(f.store.ownProfileWorks().isEmpty());assertEquals(ProfileIntentPhase.Closed,f.store.profileIntents().single().phase)
            assertFalse(f.store.resourceImports().single().bindable(f.now));assertFalse(f.store.resourceImports().single().terminal)
        } finally { f.close() }
    }
    @Test fun sharedCapacityRejectsImportAdmissionAtomicallyAndDefersUploadPreparation()=runBlocking {
        val f=Fixture();try {
            val base=f.service.refresh();repeat(32) { val source=f.importSource();f.store.prepareResourceImport(source.id,source.request,f.now) }
            fails { f.service.enqueueImportedAvatar(base,f.importSource()) };assertTrue(f.store.profileIntents().isEmpty());assertEquals(32,f.store.resourceImports().size)
            val upload=f.service.enqueue(base,upload=f.source());assertFalse(f.service.prepareNext());assertTrue(f.store.resourceUploads().isEmpty())
            val first=f.store.resourceImports().first();val claim=f.store.claimResourceImport(first.id,id(),f.now)!!
            f.store.finishResourceImport(claim,ResourceImportStatus(first.request.locator(f.actor),first.request.targetMedia,ResourceImportState.Failed),f.now)
            assertTrue(f.service.prepareNext());assertEquals(upload.upload!!.id,f.store.resourceUploads().single().id)
        } finally { f.close() }
    }
    @Test fun expiredImportedAvatarReapplicationCannotReuseTheOldTarget()=runBlocking {
        val f=Fixture();try {
            val intent=f.imported();f.importReady(intent,f.now);f.service.prepareNext()
            assertEquals(ProfilePreparation.Expired,f.store.profileIntents().single().intent.preparation);assertTrue(f.store.ownProfileWorks().isEmpty())
            val next=f.service.resumeOrReapply(intent.id);assertNotEquals(intent.serverImport!!.request.targetMedia,next.serverImport!!.request.targetMedia)
            assertEquals(intent.serverImport!!.request.source,next.serverImport!!.request.source)
        } finally { f.close() }
    }

    @Test fun previousProfileAndImportTablesMigrateWithoutChangingFrozenIdentities()=runBlocking {
        val f=Fixture();try {
            val intent=f.service.enqueue(f.service.refresh(),name="旧版资料")
            val source=f.importSource();val work=f.store.prepareResourceImport(source.id,source.request,f.now)
            val path=java.io.File(context.noBackupFilesDir,"im-${f.store.resourceScope}.db")
            f.files.close();f.store.close()
            android.database.sqlite.SQLiteDatabase.openDatabase(path.path,null,android.database.sqlite.SQLiteDatabase.OPEN_READWRITE).use { db ->
                db.execSQL("DROP TABLE resource_import_consumers")
                db.execSQL("CREATE TABLE resource_imports_legacy(id TEXT PRIMARY KEY,operation TEXT NOT NULL UNIQUE,media TEXT NOT NULL UNIQUE,request TEXT NOT NULL,status TEXT,created INTEGER NOT NULL,cancelled INTEGER NOT NULL DEFAULT 0,confirmed INTEGER NOT NULL DEFAULT 0,retained INTEGER NOT NULL DEFAULT 1,execution TEXT NOT NULL DEFAULT '{}')")
                db.execSQL("INSERT INTO resource_imports_legacy SELECT id,operation,media,request,status,created,cancelled,confirmed,retained,execution FROM resource_imports")
                db.execSQL("DROP TABLE resource_imports");db.execSQL("ALTER TABLE resource_imports_legacy RENAME TO resource_imports")
                db.execSQL("CREATE TABLE profile_intents_legacy(id TEXT PRIMARY KEY,operation TEXT UNIQUE NOT NULL,upload_id TEXT,payload TEXT NOT NULL)")
                db.execSQL("INSERT INTO profile_intents_legacy SELECT id,operation,upload_id,payload FROM profile_intents")
                db.execSQL("DROP TABLE profile_intents");db.execSQL("ALTER TABLE profile_intents_legacy RENAME TO profile_intents")
            }
            f.reopen();assertEquals(intent,f.store.profileIntents().single().intent);assertEquals(work,f.store.resourceImports().single())
            val imported=f.service.enqueueImportedAvatar(f.service.refresh(),source)
            assertEquals(source,imported.serverImport);fails { f.store.cancelResourceImport(source.id) }
            f.reopen();assertEquals(source,f.store.profileIntents().first { it.intent.id==imported.id }.intent.serverImport)
        } finally { f.close() }
    }

}

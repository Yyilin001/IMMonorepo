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

class ResourceBusinessOwnerStorageTests {
    private val context=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private inner class Fixture {
        val actor=UserId(id());val device=DeviceId(id());var now=1700000000000L
        var store=SqliteClientStore(context,actor,device);var files=ManagedResourceFiles(context,store)
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
            files.close();store.close();store=SqliteClientStore(context,actor,device);files=ManagedResourceFiles(context,store)
            own=OwnProfileService(actor,transport,store) { now };service=ProfileIntentService(actor,own,store) { now }
        }
        suspend fun close() { files.close();store.close() }
    }
    private fun key(intent:ProfileIntent)=intent.upload?.let {ResourceTransferId(ResourceTransferKind.Upload,it.id)} ?: ResourceTransferId(ResourceTransferKind.ServerImport,intent.serverImport!!.id)
    @Test fun reviewedDispositionWithdrawsTheWholeUnsubmittedNameAndAvatarAndReleasesOwnerAcrossReopen()=runBlocking {
        val f=Fixture();try {
            val intent=f.service.enqueueImportedAvatar(f.service.refresh(),f.importSource(),"整条更改")
            val transfer=key(intent);val owner=ResourceBusinessOwner.Profile(intent.id)
            assertEquals(listOf(owner),f.store.resourceBusinessOwners(ResourceBusinessOwnerQuery(transfer)).entries.map {it.owner})
            val plan=f.store.planResourceProfileDisposition(transfer,intent.id)
            assertEquals(ResourceProfileDispositionEffect.WithdrawUnsubmittedChange,plan.effect);assertTrue(f.store.resourceHasBusinessOwner(transfer,owner))
            f.store.commitResourceProfileDisposition(plan);assertTrue(runCatching {f.store.commitResourceProfileDisposition(plan)}.isFailure)
            f.reopen();assertFalse(f.store.resourceHasBusinessOwner(transfer,owner));assertNull(f.store.resourceProfileIntent(transfer,intent.id))
            assertTrue(f.store.resourceBusinessOwners(ResourceBusinessOwnerQuery(transfer)).entries.isEmpty())
            assertTrue(f.store.ownProfileWorks().isEmpty());assertEquals("原名称",f.store.snapshot().ownProfile!!.identity!!.displayName)
            assertEquals(ProfilePreparation.Cancelled,f.store.profileIntents().single().intent.preparation);assertTrue(f.store.resourceImports().single().cancellationRequested)
        } finally {f.close()}
    }
    @Test fun freezingTheProfileCommandInvalidatesReviewWithoutReleasingItsSource()=runBlocking {
        val f=Fixture();try {
            val intent=f.imported();val transfer=key(intent);val plan=f.store.planResourceProfileDisposition(transfer,intent.id)
            f.importReady(intent);f.service.prepareNext();assertTrue(f.store.profileIntents().single().intent.frozen)
            assertTrue(runCatching {f.store.commitResourceProfileDisposition(plan)}.exceptionOrNull() is ResourceTransferActionUnavailable)
            assertTrue(runCatching {f.store.planResourceProfileDisposition(transfer,intent.id)}.exceptionOrNull() is ResourceTransferActionUnavailable)
            assertTrue(f.store.profileIntents().single().sourceRetained);assertFalse(f.store.resourceImports().single().cancellationRequested)
        } finally {f.close()}
    }
    @Test fun rejectedFinishedCommandReleasesItsAssociationWithoutRewritingCurrentProfile()=runBlocking {
        val f=Fixture();try {
            val intent=f.imported();val transfer=key(intent);f.importReady(intent);f.service.prepareNext()
            f.remote=f.remote.copy(revision=2,visibilityRevision=2,identity=f.remote.identity!!.copy(displayName="新的名称"));f.own.flush()
            val current=f.store.snapshot().ownProfile;val plan=f.store.planResourceProfileDisposition(transfer,intent.id)
            assertEquals(ResourceProfileDispositionEffect.ReleaseFinishedSource,plan.effect)
            f.store.commitResourceProfileDisposition(plan);f.reopen();assertEquals(current,f.store.snapshot().ownProfile)
            assertFalse(f.store.profileIntents().single().sourceRetained);assertFalse(f.store.resourceHasBusinessOwner(transfer,ResourceBusinessOwner.Profile(intent.id)))
        } finally {f.close()}
    }
    @Test fun forgedForeignAndReopenedPlansFailAndWriterFailureRollsBackTheWholeDisposition()=runBlocking {
        val f=Fixture();try {
            val intent=f.imported();val transfer=key(intent);val plan=f.store.planResourceProfileDisposition(transfer,intent.id)
            SqliteClientStore(context,f.actor,f.device).use {assertTrue(runCatching {it.commitResourceProfileDisposition(plan)}.isFailure)}
            assertTrue(runCatching {f.store.commitResourceProfileDisposition(plan.copy(effect=ResourceProfileDispositionEffect.ReleaseFinishedSource))}.isFailure)
            val fresh=f.store.planResourceProfileDisposition(transfer,intent.id)
            val path=java.io.File(context.noBackupFilesDir,"im-${f.store.resourceScope}.db")
            android.database.sqlite.SQLiteDatabase.openDatabase(path.path,null,0).use {it.execSQL("CREATE TRIGGER reject_owner BEFORE UPDATE OF payload ON profile_intents BEGIN SELECT RAISE(ABORT,'test failure'); END")}
            assertTrue(runCatching {f.store.commitResourceProfileDisposition(fresh)}.isFailure)
            assertTrue(f.store.resourceHasBusinessOwner(transfer,ResourceBusinessOwner.Profile(intent.id)));assertFalse(f.store.resourceImports().single().cancellationRequested)
            android.database.sqlite.SQLiteDatabase.openDatabase(path.path,null,0).use {it.execSQL("DROP TRIGGER reject_owner")}
            val reopened=f.store.planResourceProfileDisposition(transfer,intent.id);f.reopen();assertTrue(runCatching {f.store.commitResourceProfileDisposition(reopened)}.isFailure)
            f.store.commitResourceProfileDisposition(f.store.planResourceProfileDisposition(transfer,intent.id));assertFalse(f.store.profileIntents().single().sourceRetained)
        } finally {f.close()}
    }
    @Test fun oldProfileSchemaBackfillsLiveOwnersAndCreationTimeIdempotently()=runBlocking {
        val f=Fixture();try {
            val intent=f.imported();val transfer=key(intent);val before=f.store.resourceBusinessOwners(ResourceBusinessOwnerQuery(transfer))
            val path=java.io.File(context.noBackupFilesDir,"im-${f.store.resourceScope}.db");f.files.close();f.store.close()
            android.database.sqlite.SQLiteDatabase.openDatabase(path.path,null,0).use {db->
                db.execSQL("CREATE TABLE profile_intents_old(id TEXT PRIMARY KEY,operation TEXT UNIQUE NOT NULL,upload_id TEXT,payload TEXT NOT NULL,import_id TEXT)")
                db.execSQL("INSERT INTO profile_intents_old SELECT id,operation,upload_id,payload,import_id FROM profile_intents")
                db.execSQL("DROP TABLE profile_intents");db.execSQL("ALTER TABLE profile_intents_old RENAME TO profile_intents")
            }
            f.reopen();assertEquals(before,f.store.resourceBusinessOwners(ResourceBusinessOwnerQuery(transfer)));assertEquals(f.now,before.entries.single().createdAt)
            f.reopen();assertEquals(before,f.store.resourceBusinessOwners(ResourceBusinessOwnerQuery(transfer)))
        } finally {f.close()}
    }
}

package com.xmtx.im

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.im.platform.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class SystemAccountComposerTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val actor=UserId(id());private val device=DeviceId(id());private val peer=UserId(id());private val room=RoomId(id())
    private suspend fun until(test:()->Boolean)=withTimeout(10_000) {while(!test()) delay(10)}
    private suspend fun project(store:SqliteClientStore,kind:String,payload:String) {
        val cursor=store.cursor()
        store.commit(SyncBatch.newBuilder().setGeneration(cursor.generation.coerceAtLeast(1)).setNextSyncToken("next")
            .addRecords(SyncRecord.newBuilder().setSourceEventId(id()).setProjectionKind(kind).setUserSyncSequence(cursor.sequence+1).setPayload(ByteString.copyFromUtf8(payload))).build(),cursor)
    }
    private suspend fun legacy(store:SqliteClientStore) {
        project(store,"direct_room_profile","""{"room_id":"${room.value}","target_user_id":"${peer.value}","display_name":"系统通知","public_handle":"notice","account_kind":"system","revision":2,"updated_at_ms":1,"room_created_at_ms":1}""")
        val hash=MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") {"%02x".format(it)}
        SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$hash.db").path,null,SQLiteDatabase.OPEN_READWRITE).use {it.execSQL("DELETE FROM direct_account_kinds")}
    }
    private fun result(key:ProfileKey)=ProfileReadResult.Available(AuthorizedProfile(
        ProfileView(peer,PublicIdentity(peer,PublicHandle("notice"),"仅授权的名称",AccountKind.System),null,ProfileState.Active,2,1),
        ProfileLease(actor,device,key,2,1,1,ProfileAuthority(1,room,1,0),0,60_000)),System.nanoTime()+60_000_000_000)
    @Test fun legacyRoomLoadsPublicKindOnceAndReopenBlocksBeforeSendingCapabilityExists()=runBlocking(Dispatchers.Main) {
        var store=openBoundFixtureStore(context,actor,device);var files=ManagedResourceFiles(context,store)
        var state:ChatComposerState?=null;var repository:ChatComposerRepository?=null;var reads=0
        val reader=ProfilePresentationReading {keys->reads++;keys.map(::result).toPersistentList()}
        try {
            legacy(store);val draft=store.saveConversationText(store.conversationDraft(room),"保留正文",1)
            repository=ChatComposerRepository(context,actor,store,files,readProfiles=reader) {state=it}
            repository.foreground(true);repository.activate(room);until {state?.directAccountKind==AccountKind.System && state?.loading==false}
            assertNull(state!!.canSend);assertFalse(repository.beginPick(state!!.id));repository.send(state!!.id);delay(30)
            assertEquals(draft,store.conversationDraft(room));assertTrue(store.sendIntents().isEmpty());assertEquals(1,reads)
            repository.close();files.close();store.close();store=openBoundFixtureStore(context,actor,device);files=ManagedResourceFiles(context,store);state=null
            repository=ChatComposerRepository(context,actor,store,files,readProfiles=reader) {state=it}
            repository.foreground(true);repository.activate(room);until {state?.directAccountKind==AccountKind.System && state?.loading==false}
            assertEquals(1,reads);assertEquals(draft,state!!.draft)
        } finally {repository?.close();files.close();store.close()}
    }
    @Test fun nonCooperativeProfileReadCannotReplenishAfterInvalidationOrPageExit()=runBlocking(Dispatchers.Main) {
        val store=openBoundFixtureStore(context,actor,device);val files=ManagedResourceFiles(context,store)
        val entered=CompletableDeferred<Unit>();val gate=CompletableDeferred<Unit>();var state:ChatComposerState?=null
        val repository=ChatComposerRepository(context,actor,store,files,readProfiles=ProfilePresentationReading {keys->entered.complete(Unit);withContext(NonCancellable) {gate.await()};keys.map(::result).toPersistentList()}) {state=it}
        try {
            legacy(store);repository.foreground(true);repository.activate(room);entered.await()
            project(store,"profile_invalidation","""{"user_id":"${peer.value}","minimum_profile_revision":2,"profile_state":"hidden"}""")
            repository.activate(null);gate.complete(Unit);until {state==null}
            repository.close();assertNull(store.conversationSendingPolicy(room,actor).accountKind)
        } finally {gate.complete(Unit);repository.close();files.close();store.close()}
    }
}

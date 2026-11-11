package com.xmtx.im

import android.app.Application
import android.database.sqlite.SQLiteDatabase
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.im.platform.SqliteClientStore
import com.xmtx.imclientkit.generated.im.realtime.v2.RoomSyncState
import com.xmtx.imclientkit.generated.im.realtime.v2.Envelope
import com.xmtx.imclientkit.generated.im.realtime.v2.ReadReceiptReadersPage
import com.xmtx.imclientkit.generated.im.realtime.v2.ReadReceiptReader
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.json.JsonObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

/** Actual AppViewModel + SQLite, with no transport flushing and no global message bodies. */
class MessageOperationSourceTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private val actor=UserId(UUID.randomUUID().toString());private val device=DeviceId(UUID.randomUUID().toString())
    private val room=RoomId(UUID.randomUUID().toString());private val target=RoomId(UUID.randomUUID().toString())
    private fun id(n: Int)=MessageId(UUID(0,n.toLong()).toString())
    private lateinit var store: SqliteClientStore
    private lateinit var model: AppViewModel
    private lateinit var owners: ViewModelStore
    private val api=object: AuthenticatedTransport {
        override suspend fun request(path: String,payload: JsonObject?,query: Pair<String,String>?,maximumBytes: Long): EdgeResponse = error("No network request is allowed while preparing local work")
    }
    private fun field(name: String)=AppViewModel::class.java.getDeclaredField(name).apply {isAccessible=true}
    @Suppress("UNCHECKED_CAST") private fun state()=field("mutableState").get(model) as MutableStateFlow<AppState>
    private fun database(body: (SQLiteDatabase)->Unit) {
        val digest=MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") {"%02x".format(it)}
        SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$digest.db").path,null,SQLiteDatabase.OPEN_READWRITE).use(body)
    }
    private fun emptySnapshot()=ClientSnapshot(conversations=persistentListOf(Conversation(room,"来源"),Conversation(target,"目标")))
    private suspend fun clearGlobal()=withContext(Dispatchers.Main) {state().value=state().value.copy(snapshot=emptySnapshot(),error=null)}
    @Before fun setup()=runBlocking<Unit> {
        store=openBoundFixtureStore(context,actor,device)
        store.acceptState(room,RoomSyncState.newBuilder().setRoomId(room.value).setHead(4).setViewerMembershipRevision(1).build())
        database {db->for(n in 1..4) db.execSQL("INSERT INTO messages(id,room,sender,text,source_text,time,revision,sequence,accepted_sequence,withdrawn) VALUES (?,?,?,?,?,?,1,?,?,0)",
            arrayOf<Any>(id(n).value,room.value,actor.value,"消息 $n","消息 $n",n,n,n))}
        withContext(Dispatchers.Main) {
            model=AppViewModel(context.applicationContext as Application);owners=ViewModelStore().apply {put("operations",model)}
            (field("operation").get(model) as? Job)?.join()
            field("local").set(model,store);field("foreground").setBoolean(model,true)
            field("mutations").set(model,MessageMutationService(actor,MessageMutationClient(api),store))
            field("reactions").set(model,MessageReactionService(actor,MessageReactionClient(api),store))
            field("forwards").set(model,ForwardPlanService(actor,ForwardPlanClient(api),store))
            state().value=AppState(SessionUi.SignedIn(actor),emptySnapshot())
        }
    }
    @After fun cleanup()=runBlocking<Unit> {
        withContext(Dispatchers.Main) {owners.clear()}
        withTimeout(10000) {while(withContext(Dispatchers.Main) {field("local").get(model)!=null}) delay(10)}
    }
    @Test fun editAndReactionUsePersistedRevisionWithEmptyOrStaleGlobalBodies()=runBlocking<Unit> {
        assertTrue(withContext(Dispatchers.Main) {model.editMessage(room,id(1),1,"编辑正文")})
        assertEquals(id(1),store.mutationWorks().single().command.message)
        clearGlobal();withContext(Dispatchers.Main) {model.changeReaction(room,id(2),"👍",true)}
        assertEquals(id(2),store.reactionWorks().single().intent.message)
        // A stale global copy must not authorize a conflicting revision or withdrawn target.
        database {db->db.execSQL("UPDATE messages SET revision=2 WHERE id=?",arrayOf(id(3).value));db.execSQL("UPDATE messages SET withdrawn=1 WHERE id=?",arrayOf(id(4).value))}
        withContext(Dispatchers.Main) {
            state().value=state().value.copy(snapshot=emptySnapshot().copy(messages=persistentListOf(Message(id(3),room,actor,"过期",3),Message(id(4),room,actor,"撤回前",4))))
            assertFalse(model.editMessage(room,id(3),1,"旧版本编辑"));model.changeReaction(room,id(4),"👍",true)
        }
        assertEquals(1,store.mutationWorks().size);assertEquals(1,store.reactionWorks().size)
    }
    @Test fun sourcePageRefreshesOnPublishAndClosesBeforeAccountStorageIsReleased()=runBlocking<Unit> {
        val page=withContext(Dispatchers.Main) {model.openMessageSources(room)!!.also {it.select(persistentSetOf(id(1)))}}
        withTimeout(5000) {while(!page.state.value.loaded) delay(10)}
        assertEquals(1L,page.state.value.messages[id(1)]!!.revision)
        database {it.execSQL("UPDATE messages SET revision=2,text='新版本' WHERE id=?",arrayOf(id(1).value))}
        withContext(Dispatchers.Main) {
            AppViewModel::class.java.getDeclaredMethod("publishSnapshot",ClientSnapshot::class.java).apply {isAccessible=true}.invoke(model,emptySnapshot())
        }
        withTimeout(5000) {while(page.state.value.messages[id(1)]?.revision!=2L) delay(10)}
        withContext(Dispatchers.Main) {model.foreground(false)}
        page.awaitClosed();assertTrue(page.state.value.closed);assertTrue(page.state.value.messages.isEmpty())
        withContext(Dispatchers.Main) {field("foreground").setBoolean(model,true)}
        val next=withContext(Dispatchers.Main) {model.openMessageSources(room)!!.also {it.select(persistentSetOf(id(1)))}}
        withTimeout(5000) {while(!next.state.value.loaded) delay(10)}
        withContext(Dispatchers.Main) {owners.clear()};next.awaitClosed()
        assertTrue(next.state.value.closed);assertTrue(next.state.value.messages.isEmpty())
        withTimeout(10000) {while(withContext(Dispatchers.Main) {field("local").get(model)!=null}) delay(10)}
    }
    @Test fun forwardingFreezesSelectedRevisionsAndOrderEvenAfterEditOrDeletion()=runBlocking<Unit> {
        database {db->db.execSQL("UPDATE messages SET revision=7,text='新版' WHERE id=?",arrayOf(id(1).value));db.execSQL("DELETE FROM messages WHERE id=?",arrayOf(id(2).value))}
        val selected=persistentListOf(SelectedForwardMessage(id(1),1,20),SelectedForwardMessage(id(2),3,10))
        assertTrue(withContext(Dispatchers.Main) {model.forwardMessages(room,selected,persistentListOf(target))})
        val command=store.forwardWorks().single().command
        assertEquals(listOf(ForwardSource(room,id(2),3),ForwardSource(room,id(1),1)),command.sources)
        assertEquals(persistentListOf(target),command.targets)
        clearGlobal();store.unavailable(room)
        assertFalse(withContext(Dispatchers.Main) {model.forwardMessages(room,persistentListOf(SelectedForwardMessage(id(3),1,3)),persistentListOf(target))})
        assertEquals(1,store.forwardWorks().size)
    }
    @Test fun readerListValidatesPersistedOwnershipBeforeRequestAndRevisionAfterResponse()=runBlocking<Unit> {
        var requests=0
        var beforeReply: suspend ()->Unit={}
        val transport=object: EnvelopeTransport {
            override suspend fun request(body: Envelope.Builder): Envelope {
                requests++;beforeReply()
                return Envelope.newBuilder().setReadReceiptReadersPage(ReadReceiptReadersPage.newBuilder().setRoomId(room.value).setMessageId(id(1).value)
                    .addReaders(ReadReceiptReader.newBuilder().setUserId(actor.value))).build()
            }
        }
        withContext(Dispatchers.Main) {field("readClient").set(model,ReadReceiptClient(transport,api))}
        assertEquals(persistentListOf(actor),withContext(Dispatchers.Main) {model.readReaders(room,id(1),null)}.readers)
        beforeReply={database {it.execSQL("UPDATE messages SET revision=2 WHERE id=?",arrayOf(id(1).value))}}
        assertTrue(withContext(Dispatchers.Main) {runCatching {model.readReaders(room,id(1),null)}.isFailure})
        assertEquals(2,requests)
        database {it.execSQL("UPDATE messages SET sender=? WHERE id=?",arrayOf(UserId(UUID.randomUUID().toString()).value,id(1).value))}
        assertTrue(withContext(Dispatchers.Main) {runCatching {model.readReaders(room,id(1),null)}.isFailure})
        assertEquals(2,requests)
    }
    @Test fun withdrawalConfirmationRefreshUsesDatabaseNotGlobalSnapshot()=runBlocking<Unit> {
        withContext(Dispatchers.Main) {model.prepareWithdrawal(room,id(1))}
        withTimeout(5000) {while(model.state.value.withdrawalPrompt==null) delay(10)}
        val prompt=model.state.value.withdrawalPrompt!!
        suspend fun publish()=withContext(Dispatchers.Main) {
            AppViewModel::class.java.getDeclaredMethod("publishSnapshot",ClientSnapshot::class.java).apply {isAccessible=true}.invoke(model,emptySnapshot())
            (field("promptValidation").get(model) as? Job)?.join()
        }
        publish();assertEquals(prompt,model.state.value.withdrawalPrompt)
        database {it.execSQL("UPDATE messages SET revision=2 WHERE id=?",arrayOf(id(1).value))}
        publish();assertNull(model.state.value.withdrawalPrompt)
        withContext(Dispatchers.Main) {model.prepareWithdrawal(room,id(1))}
        withTimeout(5000) {while(model.state.value.withdrawalPrompt?.revision!=2L) delay(10)}
        database {it.execSQL("UPDATE messages SET withdrawn=1 WHERE id=?",arrayOf(id(1).value))}
        withContext(Dispatchers.Main) {model.confirmWithdrawal()}
        assertTrue(store.mutationWorks().isEmpty())
    }
    @Test fun dismissedOrBackgroundedPendingLookupCannotPresentAConfirmation()=runBlocking<Unit> {
        val mutex=SqliteClientStore::class.java.getDeclaredField("mutex").apply {isAccessible=true}.get(store) as Mutex
        suspend fun pending(dismiss: Boolean) {
            mutex.lock()
            try {
                withContext(Dispatchers.Main) {
                    model.prepareWithdrawal(room,id(1))
                    // Let the launched operation enter the store's suspended read.
                    yield()
                    if(dismiss) model.dismissWithdrawal() else field("foreground").setBoolean(model,false)
                }
            } finally {mutex.unlock()}
            withContext(Dispatchers.Main) {
                @Suppress("UNCHECKED_CAST") val jobs=(field("businessJobs").get(model) as Set<Job>).toList()
                jobs.forEach {it.join()}
            }
            assertNull(model.state.value.withdrawalPrompt)
        }
        pending(true);pending(false);assertTrue(store.mutationWorks().isEmpty())
    }
    @Test fun sendingPublishesMetadataAndRefreshesTheIndependentOutboxWindow()=runBlocking<Unit> {
        val page=withContext(Dispatchers.Main) {model.openTimelinePage(room)!!.also {it.latest()}}
        withTimeout(5000) {while(!page.state.value.loaded) delay(10)}
        withContext(Dispatchers.Main) {assertTrue(model.send(room,"即时本地回显"))}
        withTimeout(5000) {while(page.state.value.window.outbox.singleOrNull()?.text!="即时本地回显") delay(10)}
        withContext(Dispatchers.Main) {
            assertTrue(state().value.snapshot.messages.isEmpty());assertEquals("即时本地回显",state().value.snapshot.conversations.first {it.id==room}.preview)
            model.foreground(false)
        }
        page.awaitClosed();assertTrue(page.state.value.closed)
    }

}

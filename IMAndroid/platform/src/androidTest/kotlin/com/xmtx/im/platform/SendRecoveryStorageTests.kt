package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class SendRecoveryStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private val actor=UserId(UUID.randomUUID().toString());private val device=DeviceId(UUID.randomUUID().toString())
    private val room=RoomId(UUID.randomUUID().toString())
    private fun id(n: Int)=MessageId(UUID(0,n.toLong()).toString())
    private fun command(n: Int)=MessageCommand.text(actor,room,"等待发送 $n",600000+n.toLong(),id(10000+n).value)
    private fun store()=SqliteClientStore(context,actor,device)
    private fun database(body: (SQLiteDatabase)->Unit) {
        val digest=MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") {"%02x".format(it)}
        SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$digest.db").path,null,SQLiteDatabase.OPEN_READWRITE).use(body)
    }
    private suspend fun seed(s: SqliteClientStore,count: Int=300) {
        s.acceptState(room,RoomSyncState.newBuilder().setRoomId(room.value).setHead(count.toLong()).setViewerMembershipRevision(1).build())
        database {db->db.beginTransaction();try {
            for(n in 1..count) insert(db,id(n),n.toLong())
            db.setTransactionSuccessful()
        } finally {db.endTransaction()}}
    }
    private fun insert(db: SQLiteDatabase,message: MessageId,sequence: Long) {
        db.execSQL("INSERT INTO messages(id,room,sender,text,time,revision,sequence,accepted_sequence,withdrawn) VALUES (?,?,?,?,?,1,?,?,0)",
            arrayOf<Any>(message.value,room.value,actor.value,"正式消息 $sequence",sequence,sequence,sequence))
    }
    private fun receipt(command: MessageSendOperation,message: MessageId?=null)=MessageSendOperationReceipt.newBuilder()
        .setIdentity(MessageSendOperationIdentity.newBuilder().setAccountId(actor.value).setRoomId(room.value).setOperationId(command.clientMessageId))
        .setFingerprint(MessageSendOperationFingerprint.newBuilder().setVersion(command.fingerprintVersion).setDigest(command.fingerprint)).setResolvedAtMs(100000)
        .apply {if(message!=null) setAccepted(MessageSendOperationAcceptance.newBuilder().setMessageId(message.value).setRoomSequence(301)) else setRejected(MessageSendOperationRejection.newBuilder().setReasonValue(2))}.build()
    @Test fun restartQueriesPossibleSubmissionAndLeaseFencesLateWorkers()=runBlocking<Unit> {
        var s=store();try {
            seed(s,1);s.enqueue(command(1));val first=s.claimSend(1000)!!
            assertEquals(SendAction.Submit,first.action);assertTrue(first.state.submitted);assertNull(s.claimSend(1001))
            assertFalse(first.isRetry)
            s.close();s=store();assertNull(s.claimSend(2000))
            val recovery=s.claimSend(61001)!!;assertEquals(SendAction.Recover,recovery.action);assertEquals(first.command,recovery.command)
            assertTrue(recovery.isRetry)
            s.completeSend(first,receipt(command(1),id(9001)))
            assertEquals(1,s.pending().size)
            val stale=s.observeSend(first,61001)!!
            assertEquals(OperationExecutionState.AwaitingConfirmation,stale.execution)
            assertEquals(OperationSchedulingState.Claimed,stale.scheduling)
            assertNull(s.observeSend(first.copy(command=first.command.toBuilder().setText("altered").build()),61001))
            s.deferSend(first,first.state.copy(status=SendRecoveryStatus.NeedsAttention));assertNull(s.claimSend(61002))
            val wrong=receipt(command(1),id(9001)).toBuilder().setIdentity(MessageSendOperationIdentity.newBuilder().setAccountId(actor.value).setRoomId(room.value).setOperationId(id(9999).value)).build()
            assertTrue(runCatching {s.completeSend(recovery,wrong)}.isFailure);assertEquals(1,s.pending().size)
            s.completeSend(recovery.copy(command=recovery.command.toBuilder().setText("altered").build()),receipt(command(1),id(9001)))
            assertEquals(1,s.pending().size)
            s.completeSend(recovery,receipt(command(1),id(9001)));assertTrue(s.pending().isEmpty())
            assertEquals(OperationExecutionState.Committed,s.observeSend(recovery,61003)!!.execution)
            assertEquals(OperationSchedulingState.Finished,s.observeSend(recovery,61003)!!.scheduling)
            assertEquals(SendRecordStatus.AcceptedAwaitingProjection,s.sendHistory(room,actor).items.single().status)
        } finally {s.close()}
    }
    @Test fun neverSubmittedExpiryDoesNotCallNetworkAndDoesNotBlockFollowingMessages()=runBlocking<Unit> {
        val s=store();try {
            seed(s,1);s.enqueue(command(1));s.enqueue(MessageCommand.text(actor,room,"later",2000000,command(2).clientMessageId))
            val next=s.claimSend(1000000)!!;assertEquals(command(2).clientMessageId,next.command.clientMessageId)
            assertEquals(SendRecordStatus.ExpiredUnsubmitted,s.sendHistory(room,actor).items.last().status);assertEquals(Delivery.Failed,s.sendHistory(room,actor).items.last().delivery)
            assertEquals(Delivery.Failed,s.conversationTimeline(room,actor).outbox.first().delivery)
            s.resumeSend(room,actor,command(1).clientMessageId,1000001)
            assertEquals(SendRecordStatus.ExpiredUnsubmitted,s.sendHistory(room,actor).items.last().status)
        } finally {s.close()}
    }
    @Test fun pausedHeadsRespectRoomOrderingAndManualRecoveryPreservesCooldownAndIdentity()=runBlocking<Unit> {
        val s=store();try {
            seed(s,1);s.enqueue(command(1));s.enqueue(command(2));val first=s.claimSend(1000)!!
            s.deferSend(first,first.state.copy(status=SendRecoveryStatus.NeedsAttention,nextAt=90000))
            assertNull(s.claimSend(1001))
            val otherRoom=RoomId(UUID.randomUUID().toString());val other=MessageCommand.text(actor,otherRoom,"independent",200000)
            s.enqueue(other);val independent=s.claimSend(1001)!!;assertEquals(otherRoom.value,independent.command.roomId)
            s.deferSend(independent,independent.state.copy(status=SendRecoveryStatus.NeedsAttention))
            assertTrue(runCatching {s.resumeSend(room,UserId(UUID.randomUUID().toString()),first.command.clientMessageId,2000)}.isFailure)
            s.resumeSend(room,actor,first.command.clientMessageId,2000);assertNull(s.claimSend(89999))
            val resumed=s.claimSend(90000)!!;assertEquals(first.command,resumed.command);assertEquals(SendAction.Recover,resumed.action)
            assertTrue(resumed.isRetry)
            assertEquals(0,resumed.state.submitAttempts);assertEquals(1,resumed.state.recoveryAttempts)
            s.unavailable(room);s.completeSend(resumed,receipt(command(1),id(9001)));assertTrue(s.sendHistory(room,actor).items.isEmpty())
        } finally {s.close()}
    }
    @Test fun recoveryHasIndependentBoundedRoundAndLegacyRowsStartConservatively()=runBlocking<Unit> {
        var s=store();try {
            seed(s,1);s.enqueue(command(1));val submitted=s.claimSend(1000)!!
            s.deferSend(submitted,submitted.state.copy(submitAttempts=5,action=SendAction.Recover))
            for(n in 1..5) {
                val recovery=s.claimSend(1000+n.toLong())!!;assertEquals(SendAction.Recover,recovery.action);assertEquals(n,recovery.state.recoveryAttempts)
                s.deferSend(recovery,recovery.state)
            }
            assertNull(s.claimSend(1006));assertEquals(SendRecordStatus.NeedsAttention,s.sendHistory(room,actor).items.single().status)
            s.close()
            database {db->db.execSQL("ALTER TABLE outbox RENAME TO old_outbox");db.execSQL("CREATE TABLE outbox(id TEXT PRIMARY KEY,command BLOB NOT NULL,receipt BLOB)");db.execSQL("INSERT INTO outbox SELECT id,command,receipt FROM old_outbox ORDER BY rowid");db.execSQL("DROP TABLE old_outbox")}
            s=store();val legacy=s.claimSend(1000000)!!;assertEquals(SendAction.Recover,legacy.action);assertEquals(command(1),legacy.command)
            assertTrue(legacy.isRetry)
        } finally {s.close()}
    }

    @Test fun connectionWaitingSurvivesRestartAndAuthenticatedWakePreservesActionCooldownAndLeaseFences()=runBlocking<Unit> {
        var s=store();try {
            seed(s,1);s.enqueue(command(1));val first=s.claimSend(1000)!!
            s.deferSend(first,first.state.copy(action=SendAction.Submit,status=SendRecoveryStatus.WaitingForNetwork,nextAt=90000))
            s.close();s=store()
            val waiting=s.sendHistory(room,actor).items.single()
            assertEquals(SendRecordStatus.WaitingForNetwork,waiting.status);assertFalse(waiting.canReplaceText);assertFalse(waiting.canAbandonText)
            assertNull(s.claimSend(100000));s.resumeSend(room,actor,first.command.clientMessageId,100000)
            assertEquals(SendRecordStatus.WaitingForNetwork,s.sendHistory(room,actor).items.single().status)
            assertTrue(runCatching {s.resumeNetworkWaitingSends(UserId(UUID.randomUUID().toString()),2000)}.isFailure)
            s.resumeNetworkWaitingSends(actor,2000);assertNull(s.claimSend(89999))
            s.completeSend(first,receipt(first.command,id(9001)))
            val resumed=s.claimSend(90000)!!;assertEquals(first.command,resumed.command);assertEquals(SendAction.Submit,resumed.action)
            assertTrue(resumed.isRetry);assertNotEquals(first.token,resumed.token);assertEquals(1,resumed.state.submitAttempts)
            s.deferSend(first,first.state.copy(status=SendRecoveryStatus.NeedsAttention))
            s.deferSend(resumed,resumed.state.copy(action=SendAction.Recover,status=SendRecoveryStatus.WaitingForAuthentication,nextAt=100000))
            assertEquals(SendRecordStatus.WaitingForAuthentication,s.sendHistory(room,actor).items.single().status)
            s.close();s=store();s.resumeNetworkWaitingSends(actor,95000)
            assertNull(s.claimSend(99999));val recovered=s.claimSend(100000)!!
            assertEquals(SendAction.Recover,recovered.action);assertEquals(first.command,recovered.command)
            assertEquals(0,recovered.state.submitAttempts);assertEquals(1,recovered.state.recoveryAttempts)
            s.completeSend(recovered,receipt(recovered.command,id(9001)));assertTrue(s.pending().isEmpty())
        } finally {s.close()}
    }
    @Test fun connectionWakeTraversesBoundedBatchesWithoutRevivingRevokedRoomsOrOtherPauses()=runBlocking<Unit> {
        val s=store();try {
            val commands=(1..133).map {n->MessageCommand.text(actor,RoomId(UUID.randomUUID().toString()),"batch $n",600000)}
            for((index,cmd) in commands.withIndex()) {
                s.enqueue(cmd);val work=s.claimSend(1000)!!;assertEquals(cmd,work.command)
                val status=if(index==132) SendRecoveryStatus.NeedsAttention else if(index%2==0) SendRecoveryStatus.WaitingForNetwork else SendRecoveryStatus.WaitingForAuthentication
                s.deferSend(work,work.state.copy(action=if(index%2==0) SendAction.Submit else SendAction.Recover,status=status,nextAt=90000))
            }
            val denied=RoomId(commands[131].roomId);s.unavailable(denied)
            s.resumeNetworkWaitingSends(actor,2000);assertNull(s.claimSend(89999))
            val seen=mutableSetOf<String>()
            repeat(131) {
                val next=s.claimSend(90000)!!;assertTrue(seen.add(next.command.clientMessageId))
                val index=commands.indexOf(next.command);assertTrue(index in 0..130)
                assertEquals(if(index%2==0) SendAction.Submit else SendAction.Recover,next.action)
                assertEquals(1,next.state.submitAttempts+next.state.recoveryAttempts)
                s.deferSend(next,next.state.copy(status=SendRecoveryStatus.NeedsAttention))
            }
            assertNull(s.claimSend(90001));assertEquals(131,seen.size)
            assertEquals(SendRecordStatus.NeedsAttention,s.sendHistory(RoomId(commands.last().roomId),actor).items.single().status)
            s.acceptState(denied,RoomSyncState.newBuilder().setRoomId(denied.value).setViewerMembershipRevision(1).build())
            assertEquals(SendRecordStatus.WaitingForAuthentication,s.sendHistory(denied,actor).items.single().status)
            assertNull(s.claimSend(90002));s.resumeNetworkWaitingSends(actor,90002)
            assertEquals(commands[131],s.claimSend(90002)!!.command)
        } finally {s.close()}
    }
    @Test fun observationDistinguishesDurableRejectionConnectionWaitAndLocalAbandonment()=runBlocking<Unit> {
        val s=store();try {
            val first=command(1);s.enqueue(first);val claim=s.claimSend(1000)!!
            s.deferSend(claim,claim.state.copy(status=SendRecoveryStatus.WaitingForNetwork,nextAt=3000))
            assertEquals(OperationSchedulingState.WaitingForNetwork,s.observeSend(claim,2000)!!.scheduling)
            s.resumeNetworkWaitingSends(actor,3000);val recovered=s.claimSend(3000)!!
            s.completeSend(recovered,receipt(first))
            assertEquals(OperationExecutionState.Rejected,s.observeSend(recovered,3001)!!.execution)
            val second=command(2);s.enqueue(second);assertNull(s.claimSend(700000));s.abandonUnsentText(room,actor,second.clientMessageId)
            val abandoned=s.observeSend(SendAttempt(second,"unused",SendAction.Submit,SendRecovery(),false),3002)!!
            assertEquals(OperationExecutionState.CancelledLocally,abandoned.execution)
            assertEquals(OperationSchedulingState.Finished,abandoned.scheduling)
        } finally {s.close()}
    }

    @Test fun outboxPublishesDiagnosticOnlyAfterValidatedReceiptIsPersisted()=runBlocking<Unit> {
        val s=store();val diagnostics=NetworkDiagnostics()
        try {
            seed(s,1);val command=command(1);s.enqueue(command)
            val transport=object:EnvelopeTransport {
                override suspend fun request(body:Envelope.Builder):Envelope {
                    assertEquals(command,body.messageSendOperation)
                    assertEquals(0L,diagnostics.snapshot().operationRecorded)
                    return Envelope.newBuilder().setMessageSendOperationResult(MessageSendOperationResult.newBuilder()
                        .setReceipt(receipt(command,id(9001)))).build()
                }
            }
            kotlinx.coroutines.withContext(NetworkDiagnosticsScope(diagnostics)) {MessageOutbox(transport,s,{1000}).flush()}
            val sample=diagnostics.snapshot().operations.single()
            assertEquals(OperationKind.SendMessage,sample.kind);assertEquals(OperationWorkAction.Submit,sample.action)
            assertEquals(OperationExecutionState.Committed,sample.observation!!.execution)
            assertEquals(NetworkMetric.Certainty.ResponseReceived,sample.certainty)
            assertEquals(SendRecordStatus.AcceptedAwaitingProjection,s.sendHistory(room,actor).items.single().status)
        } finally {s.close()}
    }

}

package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*
import java.io.IOException
import java.util.UUID
import kotlin.test.*

class GroupOperationDiagnosticsTests {
    private fun id() = UUID.randomUUID().toString().uppercase()
    private val room = RoomId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private fun unresolved() = EdgeResponse(200, buildJsonObject { put("unresolved", buildJsonObject {}) })
    private fun closed(identity: JsonObject, digest: String) = EdgeResponse(200, directResult("receipt", buildJsonObject {
        put("identity", identity); put("fingerprint", fingerprintPayload(digest)); put("resolvedAtMilliseconds", 7000)
        put("outcome", buildJsonObject { put("closed", buildJsonObject {}) })
    }))
    private fun assertRecoveryPair(diagnostics: NetworkDiagnostics, kind: OperationKind) {
        val samples = diagnostics.snapshot().operations
        assertEquals(listOf(OperationWorkAction.Reconcile, OperationWorkAction.Submit), samples.map { it.action })
        assertTrue(samples.all { it.kind == kind && it.priority == NetworkWorkPriority.Recovery })
        assertEquals(NetworkMetric.Certainty.OutcomeUnknown, samples.first().certainty)
        assertEquals(OperationSchedulingState.BackingOff, samples.first().observation?.scheduling)
        assertEquals(OperationExecutionState.Closed, samples.last().observation?.execution)
        assertEquals(NetworkMetric.Certainty.ResponseReceived, samples.last().certainty)
    }
    @Test fun `all invitation actions prepare without dispatch metrics then recover legacy command before replay`() = runTest {
        val secret = InvitationSecret("A".repeat(43))
        val actions = listOf(InvitationAction.Create(300,5,7), InvitationAction.Revoke(id(),7),
            InvitationAction.Submit(id(),secret.digest,"join"), InvitationAction.Cancel(id()),
            InvitationAction.Decide(id(),true,7), InvitationAction.Decide(id(),false,7))
        for(action in actions) {
            val store = MemoryInvitations(); val secrets = MemoryInviteSecrets(); val diagnostics = NetworkDiagnostics(); var now = 1000L
            val edge = FakeEdge { _, _ -> val intent=store.records.single().intent
                EdgeResponse(200,directResult("admitted",InvitationAdmission(id(),intent.fingerprint,7,1000,110000).payload(intent))) }
            fun service() = InvitationService(actorId,InvitationClient(edge),store,secrets,{now},{now*1000000})
            withContext(NetworkDiagnosticsScope(diagnostics)) {
                val first = service(); first.enqueue(first.confirmation(room,action),secret.takeIf {action is InvitationAction.Submit}); first.flush()
                assertTrue(diagnostics.snapshot().operations.isEmpty())
                val prepared=store.records.single(); assertEquals(false,prepared.executionStarted)
                store.records=persistentListOf(Json.decodeFromString(Json.encodeToString(InvitationWork.serializer(),prepared.copy(executionStarted=null))))
                val command=requireNotNull(prepared.command()); secrets.failLoad=true
                edge.answer={path,body -> assertCommandAttempt(true);assertTrue(path.endsWith("recover"));assertEquals(prepared.intent.recovery(false),body);unresolved()}
                service().flush(); now=store.records.single().nextAttempt; secrets.failLoad=false
                edge.answer={path,body -> assertCommandAttempt(true);assertTrue(path.endsWith("submit"));assertEquals(command.submission(secret.takeIf {action is InvitationAction.Submit}),body);closed(prepared.intent.identity(),prepared.intent.fingerprint)}
                service().flush();assertEquals(command,store.records.single().command());assertTrue(secrets.items.isEmpty())
            }
            assertRecoveryPair(diagnostics,when(action) {
                is InvitationAction.Create,is InvitationAction.Revoke -> OperationKind.GroupInvite
                is InvitationAction.Submit,is InvitationAction.Cancel -> OperationKind.GroupJoinRequest
                is InvitationAction.Decide -> OperationKind.GroupJoinDecision
            })
        }
    }
    @Test fun `mute and removal preserve admission during legacy recovery and exclude preparation metrics`() = runTest {
        for(action in listOf(AdministrationAction.Mute(200000),AdministrationAction.Remove)) {
            val store=MemoryAdministration();val diagnostics=NetworkDiagnostics();var now=1000L
            val edge=FakeEdge {_,_ -> val intent=store.works.single().intent
                EdgeResponse(200,directResult("admitted",AdministrationAdmission(id(),intent.fingerprint,7,3,1000,110000).payload(intent))) }
            fun service()=AdministrationService(actorId,AdministrationClient(edge),store,{now},{now*1000000})
            withContext(NetworkDiagnosticsScope(diagnostics)) {
                val first=service();first.enqueue(first.confirmation(room,targetId,action,"ADMIN_ACTION",7));first.flush()
                assertTrue(diagnostics.snapshot().operations.isEmpty());val prepared=store.works.single();assertEquals(false,prepared.executionStarted)
                store.works=persistentListOf(Json.decodeFromString(Json.encodeToString(AdministrationWork.serializer(),prepared.copy(executionStarted=null))))
                val command=prepared.command()
                edge.answer={path,body -> assertCommandAttempt(true);assertTrue(path.endsWith("recover"));assertEquals(command.recovery(false),body);unresolved()}
                service().flush();now=store.works.single().nextAttempt
                edge.answer={path,body -> assertCommandAttempt(true);assertTrue(path.endsWith("submit"));assertEquals(command.payload(),body);closed(command.intent.identity(),command.fingerprint)}
                service().flush();assertEquals(command,store.works.single().command())
            }
            assertRecoveryPair(diagnostics,if(action is AdministrationAction.Mute) OperationKind.MemberMute else OperationKind.ModeratedMemberRemoval)
        }
    }
    @Test fun `legacy group queries before advancing and verified progress retains recovery priority without failure retry`() = runTest {
        val store=MemoryGroups();val diagnostics=NetworkDiagnostics();var now=1000L
        val command=GroupCreationCommand.create(actorId,"group",persistentListOf(targetId),now)
        store.works.add(GroupCreationWork(command))
        val edge=FakeEdge {path,body -> assertCommandAttempt(true);assertTrue(path.endsWith("recover"));assertEquals("query",body!!.string("action"));EdgeResponse(200,directResult("progress",groupProgress(command,0)))}
        fun service()=GroupCreationService(actorId,GroupCreationClient(edge),store,{now},{now*1000000})
        withContext(NetworkDiagnosticsScope(diagnostics)) {
            service().flush()
            edge.answer={path,_ -> assertTrue(path.endsWith("append"));assertFalse(currentCoroutineContext()[NetworkWorkIntent]!!.isRetry);assertEquals(NetworkWorkPriority.Recovery,currentCoroutineContext()[NetworkWorkIntent]!!.priority);EdgeResponse(200,directResult("progress",groupProgress(command,1)))}
            service().flush()
            edge.answer={path,_ -> assertTrue(path.endsWith("finalize"));assertFalse(currentCoroutineContext()[NetworkWorkIntent]!!.isRetry);assertEquals(NetworkWorkPriority.Recovery,currentCoroutineContext()[NetworkWorkIntent]!!.priority);EdgeResponse(200,directResult("receipt",groupReceipt(command)))}
            service().flush()
        }
        val samples=diagnostics.snapshot().operations
        assertEquals(3,samples.size);assertTrue(samples.all {it.kind==OperationKind.GroupRoom && it.priority==NetworkWorkPriority.Recovery})
        assertEquals(listOf(OperationWorkAction.Reconcile,OperationWorkAction.Submit,OperationWorkAction.Submit),samples.map {it.action})
        assertEquals(listOf(OperationExecutionState.Processing,OperationExecutionState.Processing,OperationExecutionState.Committed),samples.map {it.observation?.execution})
        assertEquals(NetworkMetric.Certainty.OutcomeUnknown,samples[1].certainty)
        assertEquals(NetworkMetric.Certainty.ResponseReceived,samples[2].certainty)
    }
    @Test fun `moderation admission is a durable step and lost submission remains unknown until recovered receipt`() = runTest {
        val store=MemoryModeration();val diagnostics=NetworkDiagnostics();var now=1000L
        val edge=FakeEdge {_,_ -> val intent=store.works.single().intent
            EdgeResponse(200,directResult("admitted",ModerationAdmission(id(),intent.fingerprint,1,1000,110000).payload(intent))) }
        fun service()=MessageModerationService(actorId,MessageModerationClient(edge),store,{now},{now*1000000})
        withContext(NetworkDiagnosticsScope(diagnostics)) {
            val first=service();first.enqueue(first.confirmation(ModerationBaseline(room,MessageId(id()),3,7,false),"ADMIN_ACTION"));first.flush()
            assertNotNull(store.works.single().admission);assertFalse(store.works.single().submissionStarted)
            edge.answer={path,_ -> assertTrue(path.endsWith("submit"));throw IOException("fixture lost reply")};first.flush()
            val frozen=store.works.single();now=frozen.nextAttempt
            edge.answer={path,body -> assertTrue(path.endsWith("recover"));assertEquals(frozen.intent.recovery(false),body);closed(frozen.intent.identity(),frozen.intent.fingerprint)}
            service().flush()
        }
        val samples=diagnostics.snapshot().operations;assertEquals(3,samples.size)
        assertEquals(listOf(OperationWorkAction.Submit,OperationWorkAction.Submit,OperationWorkAction.Reconcile),samples.map {it.action})
        assertEquals(listOf(NetworkMetric.Certainty.OutcomeUnknown,NetworkMetric.Certainty.OutcomeUnknown,NetworkMetric.Certainty.ResponseReceived),samples.map {it.certainty})
        assertEquals(OperationKind.Moderation,samples.last().kind);assertEquals(OperationExecutionState.Closed,samples.last().observation?.execution)
    }
}

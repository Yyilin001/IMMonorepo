package com.xmtx.im.client

import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*
import kotlin.test.*

class PreparedOperationDiagnosticsTests {
    @Test fun `four preference preparations are uncounted and legacy commands query before replay`()=runTest {
        val diagnostics=NetworkDiagnostics()
        for(value in preferenceValues) {
            val store=MemoryPreferences();var now=1000L
            val api=FakeEdge {_,_->EdgeResponse(200,preferenceBaseline(value))}
            fun service()=AccountPreferenceService(actorId,AccountPreferenceClient(api,actorId),store,{now},{now*1_000_000})
            withContext(NetworkDiagnosticsScope(diagnostics)) {
                val before=diagnostics.snapshot().operationRecorded
                val first=service();first.enqueue(PreferencePatch(value.kind,first=!value.first));first.flush()
                assertEquals(before,diagnostics.snapshot().operationRecorded)
                assertEquals(false,store.works.single().executionStarted)
                val frozen=store.works.single();val command=requireNotNull(frozen.command)
                store.works[0]=Json.decodeFromString(Json.encodeToString(PreferenceWork.serializer(),frozen.copy(executionStarted=null)))
                api.answer={path,body->assertCommandAttempt(true);assertTrue(path.endsWith("/recover"));assertEquals(command.recovery(false),body)
                    EdgeResponse(200,buildJsonObject {put("unresolved",buildJsonObject {})})}
                val restored=service();restored.flush();assertFalse(store.works.single().reconcile)
                now=store.works.single().nextAttemptMilliseconds
                api.answer={path,body->assertCommandAttempt(true);assertTrue(path.endsWith("/submit"));assertEquals(command.payload(),body)
                    EdgeResponse(200,directResult("receipt",preferenceReceipt(command)))}
                restored.flush();assertEquals(command,store.works.single().command)
            }
        }
        assertSamples(diagnostics,setOf(OperationKind.StrangerMessagePreference,OperationKind.UserAddPreference,
            OperationKind.ReadReceiptPreference,OperationKind.LiveActivityPreference),4)
    }

    @Test fun `six capability kinds preserve frozen admission through legacy recovery and replay`()=runTest {
        val diagnostics=NetworkDiagnostics()
        for(action in capabilityActions) {
            val store=MemoryCapabilities();var now=1000L
            val api=FakeEdge {_,_->val intent=store.works.single().intent;EdgeResponse(200,directResult("admitted",capabilityAdmission(intent).payload(intent)))}
            fun service()=GroupCapabilityService(actorId,GroupCapabilityClient(api),store,{now},{now*1_000_000})
            withContext(NetworkDiagnosticsScope(diagnostics)) {
                val before=diagnostics.snapshot().operationRecorded
                val first=service();first.enqueue(first.confirmation(capabilityRoom,action));first.flush()
                assertEquals(before,diagnostics.snapshot().operationRecorded)
                assertEquals(false,store.works.single().executionStarted)
                val frozen=store.works.single();val command=frozen.command()
                store.works[0]=Json.decodeFromString(Json.encodeToString(GroupCapabilityWork.serializer(),frozen.copy(executionStarted=null)))
                api.answer={path,body->assertCommandAttempt(true);assertTrue(path.endsWith("/recover"));assertEquals(command.recovery(false),body)
                    EdgeResponse(200,buildJsonObject {put("unresolved",buildJsonObject {})})}
                val restored=service();restored.flush();now=store.works.single().nextAttemptMilliseconds
                api.answer={path,body->assertCommandAttempt(true);assertTrue(path.endsWith("/submit"));assertEquals(command.payload(),body)
                    EdgeResponse(200,directResult("receipt",capabilityReceipt(command)))}
                restored.flush();assertEquals(command,store.works.single().command())
            }
        }
        assertSamples(diagnostics,setOf(OperationKind.PinnedMessage,OperationKind.GroupAnnouncement,OperationKind.GroupPermission,
            OperationKind.GroupRole,OperationKind.GroupOwnership,OperationKind.GroupDissolution),6)
    }

    @Test fun `membership preparation and legacy restart preserve admission incarnation and diagnostic state`()=runTest {
        val diagnostics=NetworkDiagnostics()
        for(action in MembershipAction.entries) {
            val store=MemoryMembership();var now=1000L
            val api=FakeEdge {_,_->val intent=store.works.single().intent;EdgeResponse(200,directResult("admitted",admission(intent).payload(intent)))}
            fun service()=MembershipService(actorId,MembershipClient(api),store,{now},{now*1_000_000})
            withContext(NetworkDiagnosticsScope(diagnostics)) {
                val before=diagnostics.snapshot().operationRecorded
                val first=service();first.enqueue(targetId,first.confirmation(capabilityRoom,action,7));first.flush()
                assertEquals(before,diagnostics.snapshot().operationRecorded)
                assertEquals(false,store.works.single().executionStarted)
                val frozen=store.works.single();val command=frozen.command()
                store.works[0]=Json.decodeFromString(Json.encodeToString(MembershipWork.serializer(),frozen.copy(executionStarted=null)))
                api.answer={path,body->assertCommandAttempt(true);assertTrue(path.endsWith("/recover"));assertEquals(command.recovery(false),body)
                    EdgeResponse(200,buildJsonObject {put("unresolved",buildJsonObject {})})}
                val restored=service();restored.flush();now=store.works.single().nextAttemptMilliseconds
                api.answer={path,body->assertCommandAttempt(true);assertTrue(path.endsWith("/submit"));assertEquals(command.payload(),body)
                    EdgeResponse(200,directResult("receipt",membershipReceipt(command)))}
                restored.flush();assertEquals(command,store.works.single().command())
            }
        }
        assertSamples(diagnostics,setOf(OperationKind.Membership),2)
    }

    private fun assertSamples(diagnostics:NetworkDiagnostics,kinds:Set<OperationKind>,commands:Int) {
        val samples=diagnostics.snapshot().operations
        assertEquals(commands*2,samples.size);assertEquals(kinds,samples.map {it.kind}.toSet())
        assertTrue(samples.all {it.priority==NetworkWorkPriority.Recovery})
        samples.chunked(2).forEach {pair->
            assertEquals(listOf(OperationWorkAction.Reconcile,OperationWorkAction.Submit),pair.map {it.action})
            assertEquals(NetworkMetric.Certainty.OutcomeUnknown,pair[0].certainty)
            assertEquals(OperationSchedulingState.BackingOff,pair[0].observation?.scheduling)
            assertEquals(OperationExecutionState.Committed,pair[1].observation?.execution)
            assertEquals(NetworkMetric.Certainty.ResponseReceived,pair[1].certainty)
        }
    }
}

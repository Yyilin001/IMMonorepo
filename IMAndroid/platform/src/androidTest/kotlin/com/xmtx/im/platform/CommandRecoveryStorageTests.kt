package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.util.UUID

class CommandRecoveryStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    @Test fun directCreationQueriesAfterCancellationAndOnlyThenResubmitsOriginalIdentity()=runBlocking {recover(false)}
    @Test fun relationshipQueriesAfterCancellationAndOnlyThenResubmitsOriginalIdentity()=runBlocking {recover(true)}
    private suspend fun recover(social:Boolean) {
        val actor=UserId(id());val device=DeviceId(id());val target=UserId(id())
        var store=SqliteClientStore(context,actor,device);var now=1000L;var calls=0
        val direct=DirectRoomCommand.create(actor,target,now)
        val relationship=SocialCommand(actor,target,id(),SocialAction.Block,0,116000)
        val operation=if(social) relationship.operation else direct.operation
        val transport=object:AuthenticatedTransport {
            override suspend fun request(path:String,payload:JsonObject?,query:Pair<String,String>?,maximumBytes:Long):EdgeResponse {
                val intent=requireNotNull(currentCoroutineContext()[NetworkWorkIntent]);calls++
                assertEquals(calls>1,intent.isRetry)
                assertEquals(if(calls==1) NetworkWorkPriority.Interactive else NetworkWorkPriority.Recovery,intent.priority)
                if(calls==2) {
                    assertTrue(path.endsWith("recover"));assertEquals(if(social) relationship.recovery(false) else direct.recovery(false),payload)
                    return EdgeResponse(200,buildJsonObject {put("unresolved",buildJsonObject {})})
                }
                assertTrue(path.endsWith("submit"));assertEquals(if(social) relationship.payload() else direct.payload(),payload)
                if(calls==1) throw CancellationException("fixture interruption") else throw IOException("fixture lost response")
            }
        }
        fun directService()=DirectRoomService(actor,DirectRoomClient(transport),store,{now},{now*1_000_000})
        fun socialService()=SocialService(actor,SocialClient(transport,actor),store,{now},{now*1_000_000})
        val diagnostics=NetworkDiagnostics()
        suspend fun flush() = kotlinx.coroutines.withContext(NetworkDiagnosticsScope(diagnostics)) {if(social) socialService().flush() else directService().flush()}
        suspend fun retry() {if(social) socialService().retry(operation) else directService().retry(operation)}
        try {
            if(social) {
                val proposal=store.saveSocialProposal(SocialProposal(id(),actor,target,SocialAction.Block))
                assertEquals(false,store.confirmSocial(proposal,relationship).executionStarted)
            } else assertEquals(false,store.prepareDirect(direct).executionStarted)
            try {flush();fail("expected interruption")} catch(_:CancellationException) {}
            store.close();store=SqliteClientStore(context,actor,device)
            if(social) {
                val work=store.socialWorks().single();assertEquals(true,work.executionStarted);assertEquals(true,work.reconcile)
                try {store.updateSocial(work,work.copy(executionStarted=false));fail("erased execution history")} catch(_:IllegalArgumentException) {}
            } else {
                val work=store.directWorks().single();assertEquals(true,work.executionStarted);assertEquals(true,work.reconcile)
                try {store.updateDirect(work,work.copy(executionStarted=false));fail("erased execution history")} catch(_:IllegalArgumentException) {}
            }
            retry();flush()
            store.close();store=SqliteClientStore(context,actor,device)
            assertEquals(false,if(social) store.socialWorks().single().reconcile else store.directWorks().single().reconcile)
            now=6000;retry();flush();assertEquals(3,calls)
            if(social) assertEquals(relationship,store.socialWorks().single().command) else assertEquals(direct,store.directWorks().single().command)
            if(social) {
                assertEquals(store.socialWorks().single(),store.socialWork(operation));assertNull(store.socialWork(id()))
            } else {
                assertEquals(store.directWorks().single(),store.directWork(operation));assertNull(store.directWork(id()))
            }
            val samples=diagnostics.snapshot().operations
            assertEquals(3,samples.size)
            assertTrue(samples.all {it.kind==if(social) OperationKind.UserBlock else OperationKind.DirectRoom})
            assertEquals(OperationStepMetric.Completion.Cancelled,samples.first().completion)
            assertTrue(samples.all {it.certainty==NetworkMetric.Certainty.OutcomeUnknown})
        } finally {store.close()}
    }
    @Test fun groupProgressClearsFailureRetryButRetainsRecoveryPriorityAcrossReopen()=runBlocking {
        val actor=UserId(id());val device=DeviceId(id());val room=RoomId(id())
        var store=SqliteClientStore(context,actor,device);var calls=0
        val command=GroupCreationCommand.create(actor,"群聊",persistentListOf(UserId(id())),1000)
        fun progress(accepted:Int,finalizing:Boolean)=buildJsonObject {
            put("identity",command.identity());put("fingerprint",buildJsonObject {put("version",1);put("digest",command.fingerprint)})
            put("roomID",buildJsonObject {put("rawValue",room.value)})
            put("phase",if(finalizing) "finalizing" else "staging");put("acceptedMemberCount",accepted);put("copiedMemberCount",0)
            put("acceptedPrefixDigest",buildJsonObject {put("version",1);put("digest",command.audienceDigest(accepted))})
        }
        val transport=object:AuthenticatedTransport {
            override suspend fun request(path:String,payload:JsonObject?,query:Pair<String,String>?,maximumBytes:Long):EdgeResponse {
                val intent=requireNotNull(currentCoroutineContext()[NetworkWorkIntent]);calls++
                assertEquals(calls==2,intent.isRetry)
                assertEquals(if(calls==1) NetworkWorkPriority.Interactive else NetworkWorkPriority.Recovery,intent.priority)
                val expected=when(calls) {1->"begin";2,5->"recover";3->"append";else->"finalize"};assertTrue(path.endsWith(expected))
                if(calls==1) throw CancellationException("fixture interruption")
                return EdgeResponse(200,buildJsonObject {put("progress",buildJsonObject {put("_0",progress(if(calls==2) 0 else 1,calls>=4))})})
            }
        }
        fun service()=GroupCreationService(actor,GroupCreationClient(transport),store,{1000},{0})
        try {
            assertEquals(false,store.prepareGroup(command).retryRequired)
            try {service().flush();fail("expected interruption")} catch(_:CancellationException) {}
            store.close();store=SqliteClientStore(context,actor,device)
            assertEquals(true,store.groupWorks().single().retryRequired);service().retry(command.operation)
            repeat(4) {
                service().flush();assertEquals(false,store.groupWorks().single().retryRequired)
                store.close();store=SqliteClientStore(context,actor,device)
            }
            assertEquals(5,calls);assertEquals(command,store.groupWorks().single().command)
        } finally {store.close()}
    }
}

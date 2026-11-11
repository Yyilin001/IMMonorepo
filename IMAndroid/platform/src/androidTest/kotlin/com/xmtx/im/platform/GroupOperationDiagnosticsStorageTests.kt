package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class GroupOperationDiagnosticsStorageTests {
    @Test fun legacyGroupRecoversOriginalCommandAndPersistsTerminalObservation() = exercise(0)
    @Test fun legacyInvitationRecoversOriginalIntentAndPersistsTerminalObservation() = exercise(1)
    @Test fun legacyAdministrationRecoversFrozenAdmissionAndPersistsTerminalObservation() = exercise(2)
    @Test fun moderationRecoveryObservesValidatedReceiptAcrossDatabaseReopen() = exercise(3)

    private fun exercise(type: Int) = runBlocking {
        fun id() = UUID.randomUUID().toString().uppercase()
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val actor=UserId(id());val device=DeviceId(id());val room=RoomId(id());val target=UserId(id())
        val file=accountDatabaseFile(context,actor,device);var store=SqliteClientStore(context,actor,device)
        val group=GroupCreationCommand.create(actor,"group",persistentListOf(target),1000)
        val invite=InvitationIntent(actor,room,id(),InvitationAction.Decide(id(),true,7),116000)
        val inviteAdmission=InvitationAdmission(id(),invite.fingerprint,7,1000,110000)
        val admin=AdministrationIntent(actor,room,id(),target,AdministrationAction.Mute(200000),"ADMIN_ACTION",7,116000)
        val adminAdmission=AdministrationAdmission(id(),admin.fingerprint,7,3,1000,110000)
        val adminCommand=AdministrationCommand(admin,adminAdmission)
        val moderation=ModerationIntent(actor,room,id(),MessageId(id()),"ADMIN_ACTION",3,7,116000)
        val moderationAdmission=ModerationAdmission(id(),moderation.fingerprint,1,1000,110000)
        val key=when(type) {0->group.operation;1->invite.key;2->admin.key;else->moderation.key}
        val identity=when(type) {0->group.identity();1->invite.identity();2->admin.identity();else->moderation.identity()}
        val fingerprint=when(type) {0->group.fingerprint;1->invite.fingerprint;2->adminCommand.fingerprint;else->moderation.fingerprint}
        val recovery=when(type) {0->group.recovery(false);1->invite.recovery(false);2->adminCommand.recovery(false);else->moderation.recovery(false)}
        var calls=0
        val edge=object:AuthenticatedTransport {
            override suspend fun request(path:String,payload:JsonObject?,query:Pair<String,String>?,maximumBytes:Long):EdgeResponse {
                calls++;assertEquals(1,calls);assertTrue(path.endsWith("recover"));assertEquals(recovery,payload)
                val network=requireNotNull(currentCoroutineContext()[NetworkWorkIntent]);assertTrue(network.isRetry);assertEquals(NetworkWorkPriority.Recovery,network.priority)
                return EdgeResponse(200,buildJsonObject {put("receipt",buildJsonObject {put("_0",buildJsonObject {
                    put("identity",identity);put("fingerprint",buildJsonObject {put("version",1);put("digest",fingerprint)})
                    put("resolvedAtMilliseconds",2000);put("outcome",buildJsonObject {put("closed",buildJsonObject {})})
                })})})
            }
        }
        val secrets=object:InvitationSecretStore {
            override suspend fun save(reference:String,actor:UserId,secret:InvitationSecret) {error("no bearer")}
            override suspend fun load(reference:String,actor:UserId):InvitationSecret = error("recovery must not load bearer")
            override suspend fun remove(reference:String,actor:UserId) {error("no bearer")}
        }
        suspend fun flush() {when(type) {
            0->GroupCreationService(actor,GroupCreationClient(edge),store,{1000},{0}).flush()
            1->InvitationService(actor,InvitationClient(edge),store,secrets,{1000},{0}).flush()
            2->AdministrationService(actor,AdministrationClient(edge),store,{1000},{0}).flush()
            else->MessageModerationService(actor,MessageModerationClient(edge),store,{1000},{0}).flush()
        }}
        fun reopen() {store.close();store=SqliteClientStore(context,actor,device)}
        suspend fun verify(terminal:Boolean) {when(type) {
            0->{val work=requireNotNull(store.groupWork(key));assertEquals(store.groupWorks().single(),work);assertEquals(group,work.command);assertEquals(terminal,work.terminal);assertNull(store.groupWork(id()))}
            1->{val work=requireNotNull(store.invitationWork(key));assertEquals(store.invitationWorks().single(),work);assertEquals(invite,work.intent);assertEquals(inviteAdmission,work.admission);assertEquals(terminal,work.terminal);assertNull(store.invitationWork(id()))}
            2->{val work=requireNotNull(store.administrationWork(key));assertEquals(store.administrationWorks().single(),work);assertEquals(adminCommand,work.command());assertEquals(terminal,work.terminal);assertNull(store.administrationWork(id()))}
            else->{val work=requireNotNull(store.moderationWork(key));assertEquals(store.moderationWorks().single(),work);assertEquals(moderation,work.intent);assertEquals(moderationAdmission,work.admission);assertEquals(terminal,work.terminal);assertNull(store.moderationWork(id()))}
        }}
        try {
            when(type) {
                0->{val fresh=store.prepareGroup(group);store.updateGroup(fresh,fresh.copy(retryRequired=null))}
                1->{val draft=store.prepareInvitation(invite,"old",null);store.updateInvitation(draft,draft.copy(status=InvitationStatus.Pending,admission=inviteAdmission,roundEnd=61000))}
                2->{val draft=store.prepareAdministration(admin,"old");store.updateAdministration(draft,draft.copy(status=AdministrationStatus.Pending,admission=adminAdmission,roundEnd=61000))}
                else->{val draft=store.enqueueModeration(ModerationWork(moderation,"old",roundEnd=61000));store.updateModeration(draft,draft.copy(admission=moderationAdmission))}
            }
            reopen();verify(false)
            val diagnostics=NetworkDiagnostics()
            withContext(NetworkDiagnosticsScope(diagnostics)) {flush();reopen();verify(true);flush()}
            assertEquals(1,calls)
            val sample=diagnostics.snapshot().operations.single()
            assertEquals(listOf(OperationKind.GroupRoom,OperationKind.GroupJoinDecision,OperationKind.MemberMute,OperationKind.Moderation)[type],sample.kind)
            assertEquals(OperationWorkAction.Reconcile,sample.action);assertEquals(NetworkWorkPriority.Recovery,sample.priority)
            assertEquals(OperationExecutionState.Closed,sample.observation?.execution);assertEquals(OperationSchedulingState.Finished,sample.observation?.scheduling)
            assertEquals(NetworkMetric.Certainty.ResponseReceived,sample.certainty)
        } finally {store.close();SQLiteDatabase.deleteDatabase(file)}
    }
}

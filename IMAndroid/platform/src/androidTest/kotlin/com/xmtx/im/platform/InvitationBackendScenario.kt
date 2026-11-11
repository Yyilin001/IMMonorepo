package com.xmtx.im.platform

import android.content.Context
import com.xmtx.im.client.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*

internal suspend fun verifyInvitationBackend(context: Context, a: Credentials, b: Credentials,
    first: SqliteClientStore, second: SqliteClientStore, api: AuthenticatedTransport, peerApi: AuthenticatedTransport,
    aSocket: RealtimeConnection, bSocket: RealtimeConnection, run: String): SqliteClientStore {
    var store = first
    val aClient = InvitationClient(api); val bClient = InvitationClient(peerApi)
    val aDirectory = InvitationDirectory(api); val bDirectory = InvitationDirectory(peerApi)
    val aSecrets = KeystoreInvitationSecrets(context, "https://invitation-e2e-$run", a.userId, a.deviceId)
    val bSecrets = KeystoreInvitationSecrets(context, "https://invitation-e2e-$run", b.userId, b.deviceId)
    fun owner() = InvitationService(a.userId, aClient, store, aSecrets)
    fun applicant(secrets: InvitationSecretStore = bSecrets) = InvitationService(b.userId, bClient, second, secrets)
    suspend fun settle(service: InvitationService, local: SqliteClientStore, work: InvitationWork): InvitationWork {
        withTimeout(30000) { while(!local.invitationWorks().first { it.intent.key == work.intent.key }.terminal) { service.flush(); delay(100) } }
        return local.invitationWorks().first { it.intent.key == work.intent.key }.also { assertEquals(InvitationStatus.Committed, it.status) }
    }
    val creator = GroupCreationService(a.userId, GroupCreationClient(api), store)
    val creation = creator.prepare("邀请验收 $run", persistentListOf())
    withTimeout(30000) { while(!store.groupWorks().first { it.command.operation == creation.command.operation }.terminal) { creator.flush(); delay(100) } }
    val room = requireNotNull(store.groupWorks().first { it.command.operation == creation.command.operation }.room)
    suspend fun createLink(loseReply: Boolean = false): InvitationLink {
        val service = owner(); val draft = service.enqueue(service.confirmation(room, InvitationAction.Create(600,5,aClient.baseline(room))))
        if(loseReply) {
            service.flush(); val frozen = store.invitationWorks().first { it.intent.key == draft.intent.key }; assertNotNull(frozen.admission)
            store.updateInvitation(frozen, frozen.copy(reconcile = true, submissionStarted = true, attempts = 1))
            assertEquals(InvitationStatus.Committed, (aClient.execute(frozen.intent, frozen.command(), recover = false) as InvitationResult.Receipt).status)
            store.close(); store = SqliteClientStore(context,a.userId,a.deviceId)
            settle(owner(), store, draft)
        } else settle(service, store, draft)
        val receipt = Json.parseToJsonElement(store.invitationWorks().first { it.intent.key == draft.intent.key }.receipt!!).jsonObject
        val invite = InvitationClient.decodeReceipt(draft.intent, receipt).valueID
        return aDirectory.links(room).single { it.invite == invite }
    }
    suspend fun submit(link: InvitationLink, loseReply: Boolean = false): String {
        val preview = bDirectory.preview(link.secret); assertEquals(room,preview.room); assertFalse(preview.alreadyMember)
        val service = applicant(); val work = service.enqueue(service.confirmation(room, InvitationAction.Submit(link.invite,link.secret.digest,"申请加入")),link.secret)
        val finished = if(loseReply) {
            service.flush(); val frozen = second.invitationWorks().first { it.intent.key == work.intent.key }
            second.updateInvitation(frozen, frozen.copy(reconcile = true, submissionStarted = true, attempts = 1))
            assertEquals(InvitationStatus.Committed,(bClient.execute(frozen.intent,frozen.command(),link.secret,recover = false) as InvitationResult.Receipt).status)
            val locked = object : InvitationSecretStore {
                override suspend fun save(reference: String, actor: UserId, secret: InvitationSecret) { error("recovery saved a bearer") }
                override suspend fun load(reference: String, actor: UserId): InvitationSecret { error("recovery loaded a bearer") }
                override suspend fun remove(reference: String, actor: UserId) = bSecrets.remove(reference,actor)
            }
            settle(applicant(locked),second,work)
        } else settle(service,second,work)
        assertNull(finished.secretReference); assertFalse(finished.releaseSecret)
        val request = InvitationClient.decodeReceipt(work.intent,Json.parseToJsonElement(finished.receipt!!).jsonObject).valueID!!
        assertEquals("pending",bDirectory.preview(link.secret).requestState)
        assertTrue(aDirectory.requests(room,pageSize = 1).requests.any { it.request == request && it.applicant == b.userId })
        return request
    }
    val cancelledLink = createLink(true); val cancelledRequest = submit(cancelledLink,true)
    val cancel = applicant(); settle(cancel,second,cancel.enqueue(cancel.confirmation(room,InvitationAction.Cancel(cancelledRequest))))
    assertEquals("cancelled",bDirectory.preview(cancelledLink.secret).requestState)
    assertTrue(aDirectory.requests(room).requests.isEmpty())
    val rejectedLink = createLink(); val rejectedRequest = submit(rejectedLink)
    val reject = owner(); settle(reject,store,reject.enqueue(reject.confirmation(room,InvitationAction.Decide(rejectedRequest,false,aClient.baseline(room)))))
    assertEquals("rejected",bDirectory.preview(rejectedLink.secret).requestState)
    val approvedLink = createLink(); val approvedRequest = submit(approvedLink)
    val revision = aClient.baseline(room); val approve = owner()
    val approval = settle(approve,store,approve.enqueue(approve.confirmation(room,InvitationAction.Decide(approvedRequest,true,revision))))
    assertEquals(revision + 1,aClient.baseline(room)); assertTrue(bDirectory.preview(approvedLink.secret).alreadyMember)
    assertEquals(approval.receipt,(aClient.execute(approval.intent,approval.command(),recover = false) as InvitationResult.Receipt).wire)
    assertEquals(revision + 1,aClient.baseline(room))
    // Approval receipts alone cannot materialize access. Independent authoritative sync does that.
    assertTrue(second.snapshot().conversations.none { it.id == room })
    withTimeout(30000) { while(second.snapshot().conversations.none { it.id == room }) { SyncEngine(bSocket,second).synchronize(); RoomSyncEngine(bSocket,second).synchronize(); delay(100) } }
    SyncEngine(aSocket,store).synchronize(); RoomSyncEngine(aSocket,store).synchronize()
    val revoke = owner(); settle(revoke,store,revoke.enqueue(revoke.confirmation(room,InvitationAction.Revoke(approvedLink.invite,aClient.baseline(room)))))
    assertTrue(aDirectory.links(room).none { it.invite == approvedLink.invite })
    val unattempted = owner(); val draft = unattempted.enqueue(unattempted.confirmation(room,InvitationAction.Create(600,5,aClient.baseline(room))))
    val reopened = owner(); reopened.flush(); assertEquals(InvitationStatus.DraftPaused,store.invitationWorks().first { it.intent.key == draft.intent.key }.status)
    reopened.closeOriginal(draft.intent.key); reopened.flush()
    assertEquals(InvitationStatus.Closed,store.invitationWorks().first { it.intent.key == draft.intent.key }.status)
    assertEquals(2,aDirectory.links(room).size)
    return store
}

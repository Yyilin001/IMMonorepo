package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import java.io.IOException
import kotlin.test.*

private val inviteActor = UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
private val inviteRoom = RoomId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
private const val inviteID = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
private const val requestID = "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"
internal class MemoryInvitations : InvitationStore {
    var records = persistentListOf<InvitationWork>()
    override suspend fun invitationWorks() = records
    override suspend fun prepareInvitation(intent: InvitationIntent, activation: String, secretReference: String?): InvitationWork {
        records.firstOrNull { it.intent.key == intent.key }?.let { require(it.intent == intent); return it }
        check(records.none { !it.terminal && it.intent.room == intent.room })
        return InvitationWork(intent, activation, secretReference = secretReference).also { records = records.add(it) }
    }
    override suspend fun replaceInvitationDraft(expected: InvitationWork, intent: InvitationIntent, activation: String): InvitationWork {
        val index = records.indexOf(expected); check(index >= 0 && expected.intent.action.sameProposal(intent.action))
        records = records.set(index, expected.copy(status = InvitationStatus.DraftCancelled, secretReference = null))
        return InvitationWork(intent, activation, secretReference = expected.secretReference, nextAttempt = expected.nextAttempt).also { records = records.add(it) }
    }
    override suspend fun updateInvitation(expected: InvitationWork, updated: InvitationWork) { val index = records.indexOf(expected); check(index >= 0 && expected.intent == updated.intent); records = records.set(index, updated) }
}
internal class MemoryInviteSecrets : InvitationSecretStore {
    val items = mutableMapOf<Pair<UserId,String>, InvitationSecret>(); var failLoad = false; var failRemove = false
    override suspend fun save(reference: String, actor: UserId, secret: InvitationSecret) { val old = items[actor to reference]; require(old == null || old == secret); items[actor to reference] = secret }
    override suspend fun load(reference: String, actor: UserId): InvitationSecret { if(failLoad) throw InvitationSecretUnavailable(); return items.getValue(actor to reference) }
    override suspend fun remove(reference: String, actor: UserId) { if(failRemove) throw InvitationSecretUnavailable(); items.remove(actor to reference) }
}
class InvitationTests {
    private val lines get() = javaClass.getResourceAsStream("/invitations-swift.txt")!!.bufferedReader().readLines()
    private fun wire(index: Int, offset: Int) = Json.parseToJsonElement(lines[index * 6 + offset]).jsonObject
    private val secret = InvitationSecret("A".repeat(43))
    private fun action(index: Int): InvitationAction = when(index) {
        0 -> InvitationAction.Create(300,5,7); 1 -> InvitationAction.Revoke(inviteID,7)
        2 -> InvitationAction.Submit(inviteID,secret.digest, invitationNote("\u200b\u00a0 你好 e\u0301 \n"))
        3 -> InvitationAction.Cancel(requestID); else -> InvitationAction.Decide(requestID,index == 4,7)
    }
    private fun intent(index: Int) = InvitationIntent(inviteActor,inviteRoom,"10000000-0000-0000-0000-%012d".format(index+1),action(index),116000)
    private fun admission(intent: InvitationIntent) = InvitationAdmission("EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE",intent.fingerprint,7,2000,110000)
    private fun receipt(intent: InvitationIntent, closed: Boolean = false) = buildJsonObject {
        put("identity",intent.identity());put("fingerprint",buildJsonObject {put("version",1);put("digest",intent.fingerprint)});put("resolvedAtMilliseconds",3000)
        put("outcome",buildJsonObject { if(closed) put("closed",buildJsonObject {}) else put("applied",buildJsonObject { put("_0",buildJsonObject { put("requestSubmitted",buildJsonObject {
            put("requestID",buildJsonObject {put("rawValue",requestID)});put("inviteID",buildJsonObject {put("rawValue",inviteID)})
        }) }) }) })
    }
    @Test fun `Swift six exact intent fingerprints admission submission and terminal receipts match`() = runTest {
        for(index in 0..5) {
            val intent = intent(index); assertEquals(lines[index*6],intent.fingerprint);assertEquals(wire(index,1),intent.payload());assertEquals(wire(index,5),intent.recovery(true))
            val api = FakeEdge { _, _ -> EdgeResponse(200,wire(index,2)) };val client = InvitationClient(api)
            val admitted = (client.admit(intent,secret.takeIf {index==2}) as InvitationAdmissionResult.Admitted).admission
            assertEquals(admission(intent),admitted);assertEquals(wire(index,3),InvitationCommand(intent,admitted).submission(secret.takeIf {index==2}))
            api.answer = { _, _ -> EdgeResponse(200,wire(index,4)) }
            val result = client.execute(intent) as InvitationResult.Receipt
            assertEquals(InvitationStatus.Committed,result.status);assertEquals(if(index==4) 8L else null,result.revision)
        }
    }
    @Test fun `receipts bind targets lifetime approve revision and reject nullable revision and strip unknown fields`() {
        for(index in 0..5) {
            val intent = intent(index);val value = wire(index,4).objectValue("receipt").objectValue("_0")
            assertFails { InvitationClient.decodeReceipt(intent.copy(operation="FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"),value) }
            val polluted = JsonObject(value + ("secretAuthorization" to JsonPrimitive(secret.rawValue)))
            val receipt = InvitationClient.decodeReceipt(intent,polluted)
            assertFalse(receipt.wire.contains(secret.rawValue));assertEquals(receipt,InvitationClient.decodeReceipt(intent,Json.parseToJsonElement(receipt.wire).jsonObject))
        }
        for((index,change) in listOf(0 to ("302000" to "302001"),4 to ("\"membershipRevision\":8" to "\"membershipRevision\":7"),5 to ("\"decision\":\"reject\"" to "\"decision\":\"approve\""))) {
            val (before,after) = change
            val value=Json.parseToJsonElement(wire(index,4).toString().replace(before,after)).jsonObject.objectValue("receipt").objectValue("_0")
            assertFails {InvitationClient.decodeReceipt(intent(index),value)}
        }
    }
    @Test fun `secret grammar matches Swift without canonical base64 restriction and notes trim Foundation whitespace`() {
        assertEquals("hello",invitationNote("\u200b\u00a0hello\u0085"));assertNull(invitationNote("\u200b \n"))
        assertEquals("e\u0301",invitationNote(" e\u0301 "));assertFails {invitationNote("中".repeat(167))}
        assertEquals(43,InvitationSecret("_".repeat(43)).rawValue.length)
        assertEquals(secret,invitationSecret(invitationURL(secret)));assertFalse(secret.toString().contains(secret.rawValue))
        assertFails {InvitationSecret("A".repeat(42))};assertFails {invitationSecret("https://group-invite?token=${secret.rawValue}")}
        assertFails {intent(2).admissionRequest(InvitationSecret("B".repeat(43)))};assertFails {intent(0).admissionRequest(secret)}
    }
    @Test fun `lost reply recovers original identity without unlocked secret and terminal release retries separately`() = runTest {
        val store=MemoryInvitations();val secrets=MemoryInviteSecrets();var now=1000L
        lateinit var intent: InvitationIntent
        val api=FakeEdge { path,_ -> if(path.endsWith("admissions")) EdgeResponse(200,directResult("admitted",admission(intent).payload(intent))) else {assertCommandAttempt(false);throw IOException()} }
        val client=InvitationClient(api);var service=InvitationService(inviteActor,client,store,secrets,{now},{now*1000000})
        val work=service.enqueue(service.confirmation(inviteRoom,action(2)),secret);intent=work.intent
        service.flush();service.flush();assertTrue(store.records.single().submissionStarted);assertTrue(store.records.single().reconcile)
        secrets.failLoad=true;secrets.failRemove=true;now=4000
        api.answer={path,body -> assertCommandAttempt(true); assertTrue(path.endsWith("recover"));assertEquals(intent.recovery(false),body);EdgeResponse(200,directResult("receipt",receipt(intent)))}
        service=InvitationService(inviteActor,client,store,secrets,{now},{now*1000000});service.flush()
        assertEquals(InvitationStatus.Committed,store.records.single().status);assertTrue(store.records.single().releaseSecret)
        secrets.failRemove=false;service.flush();assertNull(store.records.single().secretReference);assertTrue(secrets.items.isEmpty())
    }
    @Test fun `restart pauses unadmitted drafts and close original works without admission or bearer`() = runTest {
        val store=MemoryInvitations();val secrets=MemoryInviteSecrets();val api=FakeEdge {_,_->error("no network")};val client=InvitationClient(api)
        var service=InvitationService(inviteActor,client,store,secrets,{1000},{0})
        val work=service.enqueue(service.confirmation(inviteRoom,action(2)),secret)
        service=InvitationService(inviteActor,client,store,secrets,{1000},{0});service.flush();assertEquals(InvitationStatus.DraftPaused,store.records.single().status)
        secrets.failLoad=true;service.closeOriginal(work.intent.key)
        api.answer={_,body->assertCommandAttempt(false);assertEquals(work.intent.recovery(true),body);EdgeResponse(200,directResult("receipt",receipt(work.intent,true)))}
        service.flush();assertEquals(InvitationStatus.Closed,store.records.single().status);assertTrue(secrets.items.isEmpty())
    }
    @Test fun `terminal admission is queried under original identity before installing proof`() = runTest {
        val store=MemoryInvitations();val secrets=MemoryInviteSecrets();lateinit var intent:InvitationIntent
        val api=FakeEdge {_,_->EdgeResponse(200,directResult("terminal",receipt(intent)))}
        val service=InvitationService(inviteActor,InvitationClient(api),store,secrets,{1000},{0})
        intent=service.enqueue(service.confirmation(inviteRoom,action(2)),secret).intent;service.flush()
        assertNull(store.records.single().receipt);assertTrue(store.records.single().recoveryOnly)
        api.answer={_,body->assertCommandAttempt(false);assertEquals(intent.recovery(true),body);EdgeResponse(200,directResult("receipt",receipt(intent)))}
        service.flush();assertEquals(InvitationStatus.Committed,store.records.single().status)
    }
    @Test fun `preparation uses monotonic fence and explicit reconfirmation preserves server retry floor and secret reference`() = runTest {
        val store=MemoryInvitations();val secrets=MemoryInviteSecrets();var now=1000L;var mono=0L
        val api=FakeEdge {_,_->EdgeResponse(429,buildJsonObject {},"90")}
        val service=InvitationService(inviteActor,InvitationClient(api,{now}),store,secrets,{now},{mono})
        val confirmation=service.confirmation(inviteRoom,action(2));mono=116000000000;assertFails {service.enqueue(confirmation,secret)}
        mono=0;val work=service.enqueue(service.confirmation(inviteRoom,action(2)),secret);service.flush()
        assertEquals(InvitationStatus.DraftPaused,store.records.single().status);assertEquals(91000,store.records.single().nextAttempt)
        now=2000;val replacement=service.reconfirm(work.intent.key,service.confirmation(inviteRoom,action(2)))
        assertEquals(work.secretReference,replacement.secretReference);assertEquals(91000,replacement.nextAttempt);assertNull(store.records.first().secretReference)
        api.answer={_,_->error("before retry floor")};service.flush()
    }
}

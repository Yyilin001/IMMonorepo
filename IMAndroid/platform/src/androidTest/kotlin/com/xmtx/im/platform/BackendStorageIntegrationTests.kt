package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import org.junit.Assume.assumeTrue
import org.junit.Assert.*
import org.junit.Test
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.util.Base64
import java.util.UUID
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

/** Explicit opt-in; a private test CA is supplied as public certificate bytes, never by disabling TLS checks. */
class BackendStorageIntegrationTests {
    @Test fun realBackendPersistsCredentialsOperationsAndBidirectionalMessagesAcrossReopen() {
        val arguments = InstrumentationRegistry.getArguments()
        val endpoint = arguments.getString("e2eURL")
        assumeTrue("Requires explicit isolated backend instrumentation arguments", endpoint != null)
        val certificate = CertificateFactory.getInstance("X.509").generateCertificate(
            Base64.getDecoder().decode(requireNotNull(arguments.getString("e2eCA"))).inputStream())
        val trustStore = KeyStore.getInstance(KeyStore.getDefaultType()).apply { load(null); setCertificateEntry("test", certificate) }
        val managers = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(trustStore) }
        val ssl = SSLContext.getInstance("TLS").apply { init(null, managers.trustManagers, null) }
        val trustedHttp = OkHttpClient.Builder()
            .sslSocketFactory(ssl.socketFactory, managers.trustManagers.single() as X509TrustManager).build()
        val transport = AccountClient(endpoint!!, trustedHttp)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val run = UUID.randomUUID().toString().replace("-", "").take(12)
        val aSecrets = KeystoreSecretStore(context, "e2e-$run-a"); val bSecrets = KeystoreSecretStore(context, "e2e-$run-b")
        val aAuth = AuthSession(aSecrets, transport); val bAuth = AuthSession(bSecrets, transport)
        val port = requireNotNull(arguments.getString("e2eTLSPort")).toInt()
        val aSocket = RealtimeConnection("localhost", port, ssl.socketFactory)
        val bSocket = RealtimeConnection("localhost", port, ssl.socketFactory)
        var aStore: SqliteClientStore? = null; var bStore: SqliteClientStore? = null
        var phase="authentication"
        runBlocking {
            try {
                withTimeout(240_000) {
                    val password = UUID.randomUUID().toString() + "aA1!"
                    val a = aAuth.login("device_${run}_a", password, true, "device_${run}_a", "设备 A")
                    val b = bAuth.login("device_${run}_b", password, true, "device_${run}_b", "设备 B")
                    phase="bootstrap persistence and messages"
                    val bootstrap = bootstrapBackend(context, a, b, aAuth, bAuth, transport, aSocket, bSocket, run, aSecrets)
                    aStore = bootstrap.first; bStore = bootstrap.second
                    val api = bootstrap.api; val bApi = bootstrap.peerApi; val room = bootstrap.room
                    phase="Resource"
                    aStore = verifyResourceBackend(context,a,b,room,api,bApi,trustedHttp,run,aStore!!,aSocket)
                    phase="ProfileIntent"
                    aStore = verifyProfileIntentBackend(context,a,api,trustedHttp,aStore!!,run)
                    fun aSocial() = SocialService(a.userId, SocialClient(api, a.userId), aStore!!)
                    fun bSocial() = SocialService(b.userId, SocialClient(bApi, b.userId), bStore!!)
                    suspend fun settle(service: SocialService, store: SqliteClientStore, work: SocialWork, status: SocialWorkStatus = SocialWorkStatus.Committed) {
                        repeat(40) {
                            if (!store.socialWorks().first { it.command.operation == work.command.operation }.terminal) { service.flush(); delay(200) }
                        }
                        assertEquals(status, store.socialWorks().first { it.command.operation == work.command.operation }.status)
                    }
                    suspend fun syncSocial() = backendSync {
                        SyncEngine(aSocket, aStore!!).synchronize(); SyncEngine(bSocket, bStore!!).synchronize()
                    }
                    // The original social command is recovered from disk before its first submission.
                    phase="social projection"
                    val request = aSocial().enqueue(b.userId, SocialAction.Request)
                    aStore!!.close(); aStore = SqliteClientStore(context, a.userId, a.deviceId)
                    settle(aSocial(), aStore!!, request); syncSocial()
                    assertEquals(RelationshipState.Pending, aStore!!.snapshot().relationships.single().state)
                    assertEquals(a.userId, bStore!!.snapshot().relationships.single().requestedBy)
                    val staleService = aSocial()
                    val staleProposal = staleService.propose(b.userId, SocialAction.Remove)
                    val staleConfirmation = staleService.prepareConfirmation(staleProposal.id)
                    val accept = bSocial().enqueue(a.userId, SocialAction.Accept)
                    settle(bSocial(), bStore!!, accept); syncSocial()
                    assertEquals(b.userId, aStore!!.snapshot().contacts.single().id)
                    assertEquals(a.userId, bStore!!.snapshot().contacts.single().id)
                    val stale = staleService.confirm(staleConfirmation)
                    settle(staleService, aStore!!, stale, SocialWorkStatus.Conflicted)
                    assertEquals(request.command.expectedRevision + 1, stale.command.expectedRevision)
                    // A conflict never changes the accepted relationship or retries with a new revision.
                    staleService.retry(stale.command.operation); staleService.flush(); syncSocial()
                    assertEquals(RelationshipState.Accepted, aStore!!.snapshot().relationships.single().state)
                    val remove = aSocial().enqueue(b.userId, SocialAction.Remove)
                    settle(aSocial(), aStore!!, remove); syncSocial()
                    assertTrue(aStore!!.snapshot().contacts.isEmpty()); assertTrue(bStore!!.snapshot().relationships.isEmpty())
                    val again = aSocial().enqueue(b.userId, SocialAction.Request)
                    settle(aSocial(), aStore!!, again)
                    val reject = bSocial().enqueue(a.userId, SocialAction.Reject)
                    settle(bSocial(), bStore!!, reject); syncSocial()
                    assertTrue(aStore!!.snapshot().relationships.isEmpty()); assertTrue(bStore!!.snapshot().relationships.isEmpty())
                    val block = aSocial().enqueue(b.userId, SocialAction.Block)
                    settle(aSocial(), aStore!!, block); syncSocial()
                    assertEquals(b.userId, aStore!!.snapshot().blockedUsers.single().target)
                    assertFalse(SocialClient(bApi, b.userId).baseline(a.userId).blocked)
                    aStore!!.close(); aStore = SqliteClientStore(context, a.userId, a.deviceId)
                    assertEquals(b.userId, aStore!!.snapshot().blockedUsers.single().target)
                    val unblock = aSocial().enqueue(b.userId, SocialAction.Unblock)
                    settle(aSocial(), aStore!!, unblock); syncSocial()
                    assertTrue(aStore!!.snapshot().blockedUsers.isEmpty())
                    assertEquals(8, aStore!!.socialWorks().size + bStore!!.socialWorks().size) // Seven applied commands and one rejected stale revision.
                    phase="groups and membership"
                    fun groups() = GroupCreationService(a.userId, GroupCreationClient(api), aStore!!)
                    val creation = groups().prepare("Android 群聊 $run", kotlinx.collections.immutable.persistentListOf(b.userId))
                    groups().flush() // Begin only; the frozen audience and accepted prefix survive reopening.
                    assertEquals(0, aStore!!.groupWorks().single().progress?.accepted)
                    aStore!!.close(); aStore = SqliteClientStore(context, a.userId, a.deviceId)
                    val creator = groups()
                    withTimeout(45_000) {
                        while (!aStore!!.groupWorks().first { it.command.operation == creation.command.operation }.terminal) { creator.flush(); delay(200) }
                    }
                    val created = aStore!!.groupWorks().first { it.command.operation == creation.command.operation }
                    assertEquals(GroupCreationStatus.Created, created.status)
                    val groupRoom = requireNotNull(created.room)
                    syncSocial()
                    RoomSyncEngine(aSocket, aStore!!).synchronize(); RoomSyncEngine(bSocket, bStore!!).synchronize()
                    assertEquals(RoomKind.Group, aStore!!.snapshot().conversations.single { it.id == groupRoom }.kind)
                    assertEquals(creation.command.title, bStore!!.snapshot().conversations.single { it.id == groupRoom }.title)
                    phase="group avatar protocol"
                    verifyGroupAvatarBackend(context,a,b,groupRoom,api,bApi,trustedHttp,aStore!!,aSocket)
                    phase="group messages"
                    val groupText = "群消息 $run"
                    MessageOutbox(aSocket, aStore!!).send(a.userId, groupRoom, groupText)
                    withTimeout(30_000) {
                        while (bStore!!.snapshot().messages.none { it.roomId == groupRoom && it.text == groupText }) { RoomSyncEngine(bSocket, bStore!!).synchronize(); delay(200) }
                    }
                    val groupReply = "群回复 $run"
                    MessageOutbox(bSocket, bStore!!).send(b.userId, groupRoom, groupReply)
                    withTimeout(30_000) {
                        while (aStore!!.snapshot().messages.none { it.roomId == groupRoom && it.text == groupReply }) { RoomSyncEngine(aSocket, aStore!!).synchronize(); delay(200) }
                    }
                    aStore!!.close(); aStore = SqliteClientStore(context, a.userId, a.deviceId)
                    assertEquals(groupRoom, aStore!!.groupWorks().single().room)
                    assertTrue(aStore!!.snapshot().messages.any { it.roomId == groupRoom && it.text == groupReply })
                    val cancellation = groups().prepare("取消测试 $run", kotlinx.collections.immutable.persistentListOf())
                    val canceller = groups(); canceller.cancel(cancellation.command.operation); canceller.flush()
                    assertEquals(GroupCreationStatus.Closed, aStore!!.groupWorks().first { it.command.operation == cancellation.command.operation }.status)
                    val roster = MemberDirectory(aSocket).page(groupRoom)
                    assertEquals(2, roster.members.size); assertEquals(MemberRole.Owner, roster.actorRole)
                    val policies = MemberDirectory(aSocket).policies(groupRoom)
                    assertEquals(roster.revision, policies.membershipRevision)
                    assertTrue(policies.allows(MemberRole.Owner, GroupPermission.Remove))
                    fun aMembership() = MembershipService(a.userId, MembershipClient(api), aStore!!)
                    fun bMembership() = MembershipService(b.userId, MembershipClient(bApi), bStore!!)
                    suspend fun settleMember(service: MembershipService, store: SqliteClientStore, work: MembershipWork, expected: MembershipStatus = MembershipStatus.Committed) {
                        withTimeout(30_000) {
                            while (true) {
                                val saved = store.membershipWorks().first { it.intent.operation == work.intent.operation }
                                if (saved.terminal || saved.status in setOf(MembershipStatus.DraftPaused, MembershipStatus.NeedsAttention)) break
                                service.flush(); delay(200)
                            }
                        }
                        assertEquals(expected, store.membershipWorks().first { it.intent.operation == work.intent.operation }.status)
                    }
                    suspend fun awaitBAccess(revoked: Boolean) {
                        withTimeout(10000) {
                            do { syncSocial(); if((groupRoom in bStore!!.snapshot().revokedRooms) == revoked) break; delay(200) } while(true)
                        }
                    }
                    var manager = aMembership()
                    val removal = manager.enqueue(b.userId, manager.confirmation(groupRoom, MembershipAction.Remove, roster.revision))
                    manager.flush() // Freeze the admission, then reopen before dispatching the mutation.
                    val removalCommand = aStore!!.membershipWorks().single().command()
                    assertEquals(MembershipStatus.Pending, aStore!!.membershipWorks().single().status)
                    aStore!!.close(); aStore = SqliteClientStore(context, a.userId, a.deviceId)
                    manager = aMembership(); settleMember(manager, aStore!!, removal); awaitBAccess(true)
                    assertTrue(bStore!!.snapshot().messages.none { it.roomId == groupRoom })
                    assertTrue(bStore!!.snapshot().conversations.none { it.id == groupRoom })
                    var denied = false
                    try { MemberDirectory(bSocket).page(groupRoom) } catch (_: GatewayFailure) { denied = true }
                    assertTrue("Removed member retained directory access", denied)
                    assertTrue(bSocket.request(com.xmtx.imclientkit.generated.im.realtime.v2.Envelope.newBuilder()
                        .setHeartbeat(com.xmtx.imclientkit.generated.im.realtime.v2.Heartbeat.getDefaultInstance())).hasHeartbeatAck())
                    val revision = MemberDirectory(aSocket).page(groupRoom).revision
                    val addDraft = manager.enqueue(b.userId, manager.confirmation(groupRoom, MembershipAction.Add, revision))
                    aStore!!.close(); aStore = SqliteClientStore(context, a.userId, a.deviceId)
                    manager = aMembership(); manager.flush()
                    assertEquals(MembershipStatus.DraftPaused, aStore!!.membershipWorks().first { it.intent.operation == addDraft.intent.operation }.status)
                    val addition = manager.reconfirm(addDraft.intent.operation, manager.confirmation(groupRoom, MembershipAction.Add, MemberDirectory(aSocket).page(groupRoom).revision))
                    settleMember(manager, aStore!!, addition); awaitBAccess(false)
                    assertTrue(MemberDirectory(bSocket).page(groupRoom).members.any { it.user == b.userId })
                    // Replaying the original removal returns its old receipt and must not remove the new membership incarnation.
                    val replay = MembershipClient(api).execute(removalCommand, recover = false, close = false) as MembershipResult.Receipt
                    assertEquals(MembershipStatus.Committed, replay.status)
                    assertTrue(MemberDirectory(bSocket).page(groupRoom).members.any { it.user == b.userId })
                    val beforeLeave = MemberDirectory(aSocket).page(groupRoom)
                    val staleRemove = manager.enqueue(b.userId, manager.confirmation(groupRoom, MembershipAction.Remove, beforeLeave.revision))
                    manager.flush()
                    val selfManager = bMembership()
                    val leave = selfManager.enqueue(b.userId, selfManager.confirmation(groupRoom, MembershipAction.Remove, beforeLeave.revision))
                    settleMember(selfManager, bStore!!, leave)
                    settleMember(manager, aStore!!, staleRemove, MembershipStatus.Conflicted)
                    awaitBAccess(true)
                    assertTrue(bStore!!.snapshot().conversations.none { it.id == groupRoom })
                    assertEquals(1, MemberDirectory(aSocket).page(groupRoom).members.size)
                    suspend fun capabilityRound() {
                    // Group capability operations use the same durable admission model and exact CAS contracts.
                    manager = aMembership()
                    val readd = manager.enqueue(b.userId, manager.confirmation(groupRoom, MembershipAction.Add, MemberDirectory(aSocket).page(groupRoom).revision))
                    settleMember(manager, aStore!!, readd); awaitBAccess(false)
                    fun aCapabilities() = GroupCapabilityService(a.userId, GroupCapabilityClient(api), aStore!!)
                    fun bCapabilities() = GroupCapabilityService(b.userId, GroupCapabilityClient(bApi), bStore!!)
                    suspend fun settleCapability(service: GroupCapabilityService, store: SqliteClientStore, work: GroupCapabilityWork, expected: GroupCapabilityStatus = GroupCapabilityStatus.Committed) {
                        withTimeout(30_000) {
                            while(true) {
                                val saved = store.capabilityWorks().first { it.intent.operation == work.intent.operation }
                                if(saved.terminal || saved.status in setOf(GroupCapabilityStatus.DraftPaused, GroupCapabilityStatus.NeedsAttention)) break
                                service.flush(); delay(200)
                            }
                        }
                        assertEquals(expected, store.capabilityWorks().first { it.intent.operation == work.intent.operation }.status)
                    }
                    var capabilityService = aCapabilities()
                    val roleWork = capabilityService.enqueue(capabilityService.confirmation(groupRoom, GroupAction.Role(b.userId, MemberRole.Admin, MemberDirectory(aSocket).page(groupRoom).revision)))
                    capabilityService.flush()
                    val originalRoleCommand = aStore!!.capabilityWorks().single().command()
                    aStore!!.close(); aStore = SqliteClientStore(context, a.userId, a.deviceId)
                    capabilityService = aCapabilities(); settleCapability(capabilityService, aStore!!, roleWork)
                    assertEquals(MemberRole.Admin, MemberDirectory(bSocket).page(groupRoom).actorRole)
                    val policyBaseline = MemberDirectory(aSocket).policies(groupRoom)
                    val allowed = kotlinx.collections.immutable.persistentSetOf(GroupPermission.Send, GroupPermission.Invite)
                    val policyWork = capabilityService.enqueue(capabilityService.confirmation(groupRoom, GroupAction.Permissions(MemberRole.Member, allowed, policyBaseline.revision)))
                    settleCapability(capabilityService, aStore!!, policyWork)
                    assertEquals(allowed, MemberDirectory(bSocket).policies(groupRoom).member)
                    val emptyPolicy = capabilityService.enqueue(capabilityService.confirmation(groupRoom, GroupAction.Permissions(MemberRole.Member, kotlinx.collections.immutable.persistentSetOf(), MemberDirectory(aSocket).policies(groupRoom).revision)))
                    settleCapability(capabilityService, aStore!!, emptyPolicy)
                    assertTrue(MemberDirectory(aSocket).policies(groupRoom).member.isEmpty())
                    // Conflict is obtained after admission, rather than fabricating a receipt or rebasing a stale intent.
                    val staleRevision = MemberDirectory(aSocket).page(groupRoom).revision
                    val staleRole = capabilityService.enqueue(capabilityService.confirmation(groupRoom, GroupAction.Role(b.userId, MemberRole.Member, staleRevision)))
                    capabilityService.flush()
                    // A separate direct command models another device, leaving the original durable work untouched.
                    val competingIntent = GroupCapabilityIntent(a.userId, groupRoom, UUID.randomUUID().toString().uppercase(), GroupAction.Role(b.userId, MemberRole.Member, staleRevision), System.currentTimeMillis() + 115000)
                    val competingAdmission = (GroupCapabilityClient(api).admit(competingIntent) as GroupCapabilityAdmissionResult.Admitted).admission
                    assertEquals(GroupCapabilityStatus.Committed, (GroupCapabilityClient(api).execute(GroupCapabilityCommand(competingIntent, competingAdmission), false, false) as GroupCapabilityResult.Receipt).status)
                    settleCapability(capabilityService, aStore!!, staleRole, GroupCapabilityStatus.Conflicted)
                    // An old admitted role command cannot overwrite the newer role when replayed.
                    assertEquals(GroupCapabilityStatus.Committed, (GroupCapabilityClient(api).execute(originalRoleCommand, false, false) as GroupCapabilityResult.Receipt).status)
                    assertEquals(MemberRole.Member, MemberDirectory(bSocket).page(groupRoom).actorRole)
                    suspend fun awaitMetadata(predicate: (ClientSnapshot) -> Boolean) {
                        withTimeout(15000) {
                            while(true) {
                                RoomSyncEngine(aSocket, aStore!!).synchronize(); RoomSyncEngine(bSocket, bStore!!).synchronize()
                                if(predicate(aStore!!.snapshot()) && predicate(bStore!!.snapshot())) break
                                delay(200)
                            }
                        }
                    }
                    awaitMetadata { snapshot -> snapshot.memberAccess.any { it.room == groupRoom && it.user == b.userId && it.role == MemberRole.Member } &&
                        snapshot.rolePolicies.any { it.room == groupRoom && it.role == MemberRole.Member && it.permissions.isEmpty() } }
                    val announcement = capabilityService.enqueue(capabilityService.confirmation(groupRoom, GroupAction.Announcement("安卓群公告 $run", 0)))
                    settleCapability(capabilityService, aStore!!, announcement)
                    awaitMetadata { it.announcements.any { value -> value.room == groupRoom && value.body == "安卓群公告 $run" } }
                    val clearAnnouncement = capabilityService.enqueue(capabilityService.confirmation(groupRoom, GroupAction.Announcement("", 1)))
                    settleCapability(capabilityService, aStore!!, clearAnnouncement)
                    awaitMetadata { it.announcements.any { value -> value.room == groupRoom && value.body.isEmpty() && value.revision == 2L } }
                    val messageID = aStore!!.snapshot().messages.first { it.roomId == groupRoom }.id
                    val pin = GroupCapabilityClient(api).pinBaseline(groupRoom, messageID)
                    val pinWork = capabilityService.enqueue(capabilityService.confirmation(groupRoom, GroupAction.Pin(messageID, true, pin.sequence)))
                    settleCapability(capabilityService, aStore!!, pinWork)
                    assertTrue(GroupCapabilityClient(api).pinBaseline(groupRoom, messageID).pinned)
                    awaitMetadata { it.pins.any { value -> value.room == groupRoom && value.message == messageID } }
                    aStore!!.close(); aStore = SqliteClientStore(context, a.userId, a.deviceId); capabilityService = aCapabilities()
                    assertTrue(aStore!!.snapshot().pins.any { it.room == groupRoom && it.message == messageID })
                    assertEquals(2L, aStore!!.snapshot().announcements.first { it.room == groupRoom }.revision)
                    assertEquals(MemberRole.Member,aStore!!.snapshot().memberAccess.first { it.room == groupRoom && it.user == b.userId }.role)
                    assertTrue(aStore!!.snapshot().rolePolicies.first { it.room == groupRoom && it.role == MemberRole.Member }.permissions.isEmpty())
                    val unpinBaseline = GroupCapabilityClient(api).pinBaseline(groupRoom, messageID)
                    val unpinWork = capabilityService.enqueue(capabilityService.confirmation(groupRoom, GroupAction.Pin(messageID, false, unpinBaseline.sequence)))
                    settleCapability(capabilityService, aStore!!, unpinWork)
                    awaitMetadata { it.pins.none { value -> value.room == groupRoom && value.message == messageID } }

                    val transfer = capabilityService.enqueue(capabilityService.confirmation(groupRoom, GroupAction.Transfer(b.userId, MemberDirectory(aSocket).page(groupRoom).revision)))
                    settleCapability(capabilityService, aStore!!, transfer)
                    assertEquals(MemberRole.Owner, MemberDirectory(bSocket).page(groupRoom).actorRole)
                    assertEquals(MemberRole.Member, MemberDirectory(aSocket).page(groupRoom).actorRole)
                    awaitMetadata { snapshot -> snapshot.memberAccess.any { it.room == groupRoom && it.user == b.userId && it.role == MemberRole.Owner } &&
                        snapshot.memberAccess.any { it.room == groupRoom && it.user == a.userId && it.role == MemberRole.Member } }
                    syncSocial()
                    val newOwner = bCapabilities()
                    val dissolution = newOwner.enqueue(newOwner.confirmation(groupRoom, GroupAction.Dissolve(MemberDirectory(bSocket).page(groupRoom).revision)))
                    settleCapability(newOwner, bStore!!, dissolution)
                    withTimeout(10000) {
                        while(groupRoom !in aStore!!.snapshot().revokedRooms || groupRoom !in bStore!!.snapshot().revokedRooms) { syncSocial(); delay(200) }
                    }
                    assertTrue(aStore!!.snapshot().conversations.none { it.id == groupRoom })
                    assertTrue(bStore!!.snapshot().conversations.none { it.id == groupRoom })
                    assertTrue(groupRoom in aStore!!.snapshot().revokedRooms && groupRoom in bStore!!.snapshot().revokedRooms)
                    assertTrue(aStore!!.snapshot().announcements.none { it.room == groupRoom } && bStore!!.snapshot().announcements.none { it.room == groupRoom })
                    assertTrue(aStore!!.snapshot().pins.none { it.room == groupRoom } && bStore!!.snapshot().pins.none { it.room == groupRoom })
                    assertTrue(listOf(aStore!!,bStore!!).all { store -> store.snapshot().memberAccess.none { it.room == groupRoom } && store.snapshot().rolePolicies.none { it.room == groupRoom } })

                    }
                    capabilityRound()

                    suspend fun preferenceRound() {
                        val client = AccountPreferenceClient(api, a.userId)
                        fun service() = AccountPreferenceService(a.userId, client, aStore!!)
                        suspend fun settled(worker: AccountPreferenceService, work: PreferenceWork, status: PreferenceStatus = PreferenceStatus.Committed): PreferenceWork {
                            withTimeout(30000) {
                                while(!aStore!!.preferenceWorks().first { it.operation == work.operation }.terminal) { worker.flush(); delay(200) }
                            }
                            return aStore!!.preferenceWorks().first { it.operation == work.operation }.also { assertEquals(status, it.status) }
                        }
                        suspend fun direct(command: PreferenceCommand): PreferenceResult.Receipt {
                            var recover = false
                            return withTimeout(30000) {
                                var receipt: PreferenceResult.Receipt? = null
                                while(receipt == null) {
                                    when(val result = client.execute(command, recover, false)) {
                                        is PreferenceResult.Receipt -> receipt = result
                                        is PreferenceResult.Deferred -> { recover = true; delay(maxOf(200, result.delayMilliseconds)) }
                                        PreferenceResult.Unresolved -> { recover = false; delay(200) }
                                        PreferenceResult.Conflict -> fail("unexpected fingerprint conflict")
                                    }
                                }
                                receipt
                            }
                        }
                        for(kind in PreferenceKind.entries) {
                            val baseline = client.baseline(kind)
                            val patch = if(baseline.value.second != null) PreferencePatch(kind, second = !baseline.value.second!!) else PreferencePatch(kind, first = !baseline.value.first)
                            var worker = service(); var work = worker.enqueue(patch)
                            aStore!!.close(); aStore = SqliteClientStore(context, a.userId, a.deviceId)
                            worker = service(); worker.flush()
                            assertEquals(PreferenceStatus.DraftPaused, aStore!!.preferenceWorks().first { it.operation == work.operation }.status)
                            work = worker.reconfirm(work.operation); worker.flush()
                            val frozen = aStore!!.preferenceWorks().first { it.operation == work.operation }
                            val command = requireNotNull(frozen.command)
                            assertEquals(patch.apply(baseline.value), command.value)
                            aStore!!.close(); aStore = SqliteClientStore(context, a.userId, a.deviceId)
                            val committed = settled(service(), frozen)
                            assertEquals(command, committed.command)
                            assertEquals(command.value, aStore!!.preferenceSnapshots().first { it.value.kind == kind }.value)
                            // A competing device changes the baseline after the local command freezes.
                            worker = service(); work = worker.enqueue(PreferencePatch(kind, first = !command.value.first)); worker.flush()
                            val old = requireNotNull(aStore!!.preferenceWorks().first { it.operation == work.operation }.command)
                            val remote = old.copy(operation = UUID.randomUUID().toString().uppercase(), value = baseline.value, deadline = System.currentTimeMillis() + 115000)
                            assertEquals(PreferenceStatus.Committed, direct(remote).status)
                            settled(worker, work, PreferenceStatus.Conflicted)
                            // The receipt replay preserves its original result, without reverting newer settings.
                            assertEquals(PreferenceStatus.Committed, direct(command).status)
                            assertEquals(baseline.value, client.baseline(kind).value)
                            withTimeout(10000) {
                                while(aStore!!.preferenceSnapshots().first { it.value.kind == kind }.revision < remote.revision + 1) { syncSocial(); delay(200) }
                            }
                            assertEquals(PreferenceSnapshot(a.userId, baseline.value, remote.revision + 1), aStore!!.preferenceSnapshots().first { it.value.kind == kind })
                        }
                        aStore!!.close(); aStore = SqliteClientStore(context, a.userId, a.deviceId)
                        assertEquals(4, aStore!!.snapshot().preferences.size)
                        assertTrue(aStore!!.preferenceWorks().all { it.terminal })
                    }
                    phase="account preferences"
                    preferenceRound()

                    phase="Personal"
                    aStore = verifyPersonalBackend(context, a, requireNotNull(room), aStore!!, bStore!!, api, aSocket, bSocket, run, password, transport, port, ssl.socketFactory)

                    phase="Reaction"
                    aStore = verifyReactionBackend(context, a, b, requireNotNull(room), aStore!!, bStore!!, api, bApi, aSocket, bSocket)
                    phase="Forward"
                    aStore = verifyForwardBackend(context, a, b, requireNotNull(room), aStore!!, bStore!!, api, aSocket, bSocket, run)
                    phase="Mutation"
                    aStore = verifyMutationBackend(context, a, b, requireNotNull(room), aStore!!, bStore!!, api, bApi, aSocket, bSocket, run)
                    phase="Invitation"
                    aStore = verifyInvitationBackend(context, a, b, aStore!!, bStore!!, api, bApi, aSocket, bSocket, run)
                    phase="Administration"
                    aStore = verifyAdministrationBackend(context, a, b, aStore!!, bStore!!, api, bApi, aSocket, bSocket, run)
                    phase="MessageModeration"
                    aStore = verifyMessageModerationBackend(context, a, b, aStore!!, bStore!!, api, bApi, aSocket, bSocket, run)
                    phase="PolicyRecovery"
                    aStore = verifyPolicyRecoveryBackend(context, a, b, aStore!!, bStore!!, api, aSocket, bSocket, run)
                    phase="ReadReceipt"
                    aStore = verifyReadReceiptBackend(context, a, b, requireNotNull(room), aStore!!, bStore!!, api, bApi, aSocket, bSocket, run)
                    phase="ProfilePresentation"
                    verifyProfilePresentationBackend(a, b, aStore!!, api, bApi, aSocket, run)
                    phase="NameOperation"
                    aStore = verifyNameOperationBackend(context, a, b, aStore!!, bStore!!, api, bApi, run)
                    phase="OwnProfile"
                    aStore = verifyOwnProfileBackend(context, a, b, aStore!!, api, bApi, transport, run, password)
                    phase="Device"
                    verifyDeviceBackend(context, a, api, transport, run, password)
                    phase="Password"
                    verifyPasswordBackend(context, transport, run)



                }
            } catch(error: Throwable) { throw AssertionError("Backend storage failed during $phase",error) } finally {
                aSocket.close(); bSocket.close(); aStore?.close(); bStore?.close()
                withContext(NonCancellable) { withTimeout(45_000) { aAuth.logout(); bAuth.logout() } }
            }
        }
    }
}

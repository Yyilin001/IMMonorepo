package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.runBlocking
import org.junit.Test
import org.junit.Assert.*
import java.util.UUID
import kotlinx.serialization.json.*

class StorageTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    @Test fun invalidBatchRollsBackThenRestartRetainsValidReceiptAndOutbox() = runBlocking {
        val account = UserId(UUID.randomUUID().toString()); val device = DeviceId(UUID.randomUUID().toString())
        val store = SqliteClientStore(context, account, device)
        val command = MessageCommand.text(account, RoomId("room"), "待发送", 1000, "operation")
        store.enqueue(command)
        val batch = SyncBatch.newBuilder().setGeneration(1).setNextSyncToken("opaque").setSyncReceipt("receipt").setCapabilityProfile("base")
            .addRecords(SyncRecord.newBuilder().setUserSyncSequence(1).setSourceEventId("event").setProjectionKind("message").setPayload(ByteString.copyFromUtf8("{}"))).build()
        try { store.commit(batch, SyncCursor()); fail("invalid payload accepted") } catch (_: ClientFailure.Protocol) { }
        assertEquals(SyncCursor(), store.cursor())
        val payload = """{"target_user_id":"friend","state":"accepted","updated_at_ms":1}"""
        val valid = batch.toBuilder().setRecords(0, batch.getRecords(0).toBuilder().setProjectionKind("relationship").setPayload(ByteString.copyFromUtf8(payload))).build()
        store.commit(valid, SyncCursor()); store.close()
        val reopened = SqliteClientStore(context, account, device)
        assertEquals(SyncCursor(1, 1, "opaque", "receipt"), reopened.cursor())
        assertEquals(command, reopened.pending().single()); reopened.close()
        val other = SqliteClientStore(context, account, DeviceId(UUID.randomUUID().toString()))
        assertTrue(other.pending().isEmpty()); assertEquals(SyncCursor(), other.cursor()); other.close()
    }
    @Test fun membershipRevocationPurgesMessagesAndFencesLateContent() = runBlocking {
        val store = SqliteClientStore(context, UserId("me"), DeviceId(UUID.randomUUID().toString()))
        fun record(sequence: Long, kind: String, payload: String) = SyncRecord.newBuilder().setUserSyncSequence(sequence)
            .setSourceEventId("event-$sequence").setProjectionKind(kind).setPayload(ByteString.copyFromUtf8(payload)).build()
        fun batch(vararg records: SyncRecord) = SyncBatch.newBuilder().setGeneration(1).setCapabilityProfile("base")
            .setNextSyncToken("token").setSyncReceipt("receipt").addAllRecords(records.toList()).build()
        val message = """{"event_type":"message.accepted","message_id":"m","room_id":"room","sender_user_id":"sender","text":"private","room_sequence":1,"message_revision":1,"server_created_at_ms":1}"""
        store.acceptState(RoomId("room"), RoomSyncState.newBuilder().setOwnerEpoch(1).setViewerMembershipRevision(1).setHead(3).setUnreadCount(3).build())
        val page = GroupEventPage.newBuilder().setRoomId("room").setNextRoomSequence(1)
            .addEvents(GroupEvent.newBuilder().setRoomSequence(1).setSourceEventId("message-event").setProjectionKind("message").setPayload(ByteString.copyFromUtf8(message))).build()
        store.commitRoom(page, RoomCursor())
        assertEquals("private", store.snapshot().messages.single().text)
        val removed = """{"event_type":"membership_changed","room_id":"room","membership_revision":2,"target_user_id":"me","action":"remove"}"""
        store.commit(batch(record(1, "membership", removed)), store.cursor())
        try { store.commitRoom(page.toBuilder().setNextRoomSequence(2).clearEvents()
            .addEvents(page.getEvents(0).toBuilder().setRoomSequence(2).setPayload(ByteString.copyFromUtf8(message.replace("\"room_sequence\":1", "\"room_sequence\":2")))).build(), RoomCursor(1)); fail("revoked page accepted") }
        catch (_: ClientFailure.Protocol) { }
        assertTrue(store.snapshot().messages.isEmpty()); assertTrue(store.snapshot().conversations.isEmpty())
        assertTrue(RoomId("room") in store.snapshot().revokedRooms)
        try { store.enqueue(MessageCommand.text(UserId("me"), RoomId("room"), "pending", 1000)); fail("revoked room accepted a new draft") }
        catch (_: IllegalStateException) { }
        assertTrue(store.pending().isEmpty()); store.close()
    }
    @Test fun invalidSnapshotPrevalidationPreservesExistingLiveProjection() = runBlocking {
        val store = SqliteClientStore(context, UserId("me"), DeviceId(UUID.randomUUID().toString()))
        store.enqueue(MessageCommand.text(UserId("me"), RoomId("room"), "pending", 1000))
        try {
            store.validateSnapshot(kotlinx.collections.immutable.persistentListOf(SnapshotItem("message", "key", "event", 1, ByteString.copyFromUtf8("{}"))))
            fail("invalid shadow accepted")
        } catch (_: ClientFailure.Protocol) { }
        assertEquals("pending", store.snapshot().messages.single().text); assertEquals(SyncCursor(), store.cursor()); store.close()
    }
    @Test fun directRoomWorkSurvivesReopenCoalescesAndRejectsUnboundReceipt() = runBlocking {
        val account = UserId(UUID.randomUUID().toString()); val device = DeviceId(UUID.randomUUID().toString())
        val target = UserId(UUID.randomUUID().toString())
        val command = DirectRoomCommand.create(account, target, 1000)
        val store = SqliteClientStore(context, account, device)
        val original = store.prepareDirect(command)
        assertEquals(original, store.prepareDirect(DirectRoomCommand.create(account, target, 2000)))
        val processing = original.copy(processing = true, attempts = 1, nextAttemptMilliseconds = 5000)
        store.updateDirect(original, processing); store.close()
        val reopened = SqliteClientStore(context, account, device)
        assertEquals(processing, reopened.directWorks().single())
        val room = RoomId(UUID.randomUUID().toString())
        fun proof(cmd: DirectRoomCommand) = buildJsonObject {
            put("identity", cmd.identity()); put("fingerprint", cmd.fingerprintPayload()); put("resolvedAtMilliseconds", 3000)
            put("outcome", buildJsonObject { put("opened", buildJsonObject {
                put("roomID", buildJsonObject { put("rawValue", room.value) }); put("createdAtMilliseconds", 2000)
            }) })
        }.toString()
        try {
            reopened.updateDirect(processing, processing.copy(status = DirectWorkStatus.Opened, room = room,
                receipt = proof(DirectRoomCommand.create(account, target, 1000))))
            fail("foreign receipt accepted")
        } catch (_: ClientFailure.Protocol) { }
        assertEquals(processing, reopened.directWorks().single())
        reopened.updateDirect(processing, processing.copy(status = DirectWorkStatus.Opened, room = room, receipt = proof(command)))
        assertEquals(room, reopened.snapshot().directOperations.single().room)
        // The receipt grants no profile or room-content access by itself.
        assertTrue(reopened.snapshot().conversations.isEmpty())
        reopened.close()
        val other = SqliteClientStore(context, account, DeviceId(UUID.randomUUID().toString()))
        assertTrue(other.directWorks().isEmpty()); other.close()
    }
    @Test fun socialConfirmationIsAtomicAndReceiptsNeverGrantRelationshipProjection() = runBlocking {
        val account = UserId(UUID.randomUUID().toString()); val target = UserId(UUID.randomUUID().toString())
        val device = DeviceId(UUID.randomUUID().toString())
        val proposal = SocialProposal(UUID.randomUUID().toString().uppercase(), account, target, SocialAction.Request)
        var store = SqliteClientStore(context, account, device)
        store.saveSocialProposal(proposal)
        assertEquals(proposal, store.saveSocialProposal(proposal.copy(id = UUID.randomUUID().toString().uppercase())))
        store.close(); store = SqliteClientStore(context, account, device)
        assertEquals(proposal, store.socialProposals().single())
        val command = SocialCommand(account, target, UUID.randomUUID().toString().uppercase(), SocialAction.Request, 0, 601000)
        val original = store.confirmSocial(proposal, command)
        try { store.confirmSocial(proposal, command); fail("proposal consumed twice") } catch (_: IllegalStateException) { }
        try { store.saveSocialProposal(proposal); fail("duplicate active relationship command accepted") } catch (_: IllegalStateException) { }
        assertTrue(store.socialProposals().isEmpty())
        store.close(); store = SqliteClientStore(context, account, device)
        assertEquals(original, store.socialWorks().single())
        fun receipt(fingerprint: String) = buildJsonObject {
            put("identity", command.identity()); put("fingerprint", buildJsonObject { put("version", 1); put("digest", fingerprint) })
            put("resolvedAtMilliseconds", 2000)
            put("outcome", buildJsonObject { put("applied", buildJsonObject { put("_0", buildJsonObject {
                put("relationship", buildJsonObject { put("state", "pending"); put("revision", 1) })
            }) }) })
        }.toString()
        try { store.updateSocial(original, original.copy(status = SocialWorkStatus.Committed, receipt = receipt("foreign"))); fail("unbound receipt accepted") }
        catch (_: ClientFailure.Protocol) { }
        assertEquals(original, store.socialWorks().single())
        store.updateSocial(original, original.copy(status = SocialWorkStatus.Committed, receipt = receipt(command.fingerprint)))
        assertTrue(store.snapshot().relationships.isEmpty()); assertTrue(store.snapshot().contacts.isEmpty())
        store.close()
    }
    @Test fun socialProjectionRollbackAndReopenPreserveOwnRelationshipAndBlockState() = runBlocking {
        val actor = UserId(UUID.randomUUID().toString()); val target = UserId(UUID.randomUUID().toString())
        val device = DeviceId(UUID.randomUUID().toString()); var store = SqliteClientStore(context, actor, device)
        fun record(sequence: Long, kind: String, payload: String) = SyncRecord.newBuilder().setUserSyncSequence(sequence)
            .setSourceEventId("social-$sequence").setProjectionKind(kind).setPayload(ByteString.copyFromUtf8(payload)).build()
        fun batch(vararg records: SyncRecord) = SyncBatch.newBuilder().setGeneration(1).setCapabilityProfile("base")
            .setNextSyncToken("token").setSyncReceipt("receipt").addAllRecords(records.toList()).build()
        val pending = record(1, "relationship", """{"target_user_id":"${target.value}","state":"pending","requested_by_user_id":"${target.value}","updated_at_ms":1}""")
        val badBlock = record(2, "user_block", """{"target_user_id":"${target.value}","is_blocked":"wrong","updated_at_ms":1}""")
        try { store.commit(batch(pending, badBlock), SyncCursor()); fail("invalid block accepted") } catch (_: ClientFailure.Protocol) { }
        assertEquals(SyncCursor(), store.cursor()); assertTrue(store.snapshot().relationships.isEmpty())
        val blocked = record(2, "user_block", """{"target_user_id":"${target.value}","is_blocked":true,"updated_at_ms":1}""")
        store.commit(batch(pending, blocked), SyncCursor()); store.close(); store = SqliteClientStore(context, actor, device)
        assertEquals(target, store.snapshot().relationships.single().requestedBy)
        assertEquals(target, store.snapshot().blockedUsers.single().target); assertTrue(store.snapshot().contacts.isEmpty())
        val accepted = record(3, "relationship", """{"target_user_id":"${target.value}","state":"accepted","updated_at_ms":2}""")
        val unblocked = record(4, "user_block", """{"target_user_id":"${target.value}","is_blocked":false,"updated_at_ms":2}""")
        store.commit(batch(accepted, unblocked), store.cursor())
        assertEquals(target, store.snapshot().contacts.single().id); assertTrue(store.snapshot().blockedUsers.isEmpty()); store.close()
    }
    @Test fun groupCreationPersistsCanonicalPagesAndRejectsRegressedOrForeignEvidence() = runBlocking {
        val actor = UserId(UUID.randomUUID().toString()); val device = DeviceId(UUID.randomUUID().toString())
        val members = kotlinx.collections.immutable.persistentListOf(UserId(UUID.randomUUID().toString()))
        val command = GroupCreationCommand.create(actor, "群聊", members, 1000)
        var store = SqliteClientStore(context, actor, device)
        val work = store.prepareGroup(command)
        assertEquals(work, store.prepareGroup(GroupCreationCommand.create(actor, "群聊", members, 2000)))
        try { store.prepareGroup(GroupCreationCommand.create(actor, "不同群聊", members, 2000)); fail("active group replaced") } catch (_: IllegalStateException) { }
        val room = RoomId(UUID.randomUUID().toString())
        val progress = GroupCreationProgress(room, GroupCreationPhase.Staging, 1, 0, command.audienceDigest())
        val staged = work.copy(progress = progress, reconcile = true)
        store.updateGroup(work, staged); store.close(); store = SqliteClientStore(context, actor, device)
        assertEquals(staged, store.groupWorks().single())
        assertEquals(1, store.groupWorks().single().command.page(0)["memberUserIDs"]!!.jsonArray.size)
        try { store.updateGroup(staged, staged.copy(progress = progress.copy(accepted = 0, prefixDigest = command.audienceDigest(0)))); fail("regressed progress accepted") }
        catch (_: ClientFailure.Protocol) { }
        val cancelled = staged.copy(cancellationRequested = true)
        store.updateGroup(staged, cancelled)
        try { store.updateGroup(cancelled, staged); fail("cancellation lost") } catch (_: IllegalArgumentException) { }
        fun receipt(targetRoom: RoomId) = buildJsonObject {
            put("identity", command.identity()); put("fingerprint", buildJsonObject { put("version", 1); put("digest", command.fingerprint) })
            put("resolvedAtMilliseconds", 2000)
            put("outcome", buildJsonObject { put("created", buildJsonObject {
                put("roomID", buildJsonObject { put("rawValue", targetRoom.value) }); put("title", command.title)
                put("capacityClass", command.capacity.wire); put("memberCount", 2)
            }) })
        }.toString()
        val foreignRoom = RoomId(UUID.randomUUID().toString())
        try { store.updateGroup(cancelled, cancelled.copy(status = GroupCreationStatus.Created, room = foreignRoom, receipt = receipt(foreignRoom))); fail("receipt changed room identity") }
        catch (_: ClientFailure.Protocol) { }
        store.updateGroup(cancelled, cancelled.copy(status = GroupCreationStatus.Created, room = room, receipt = receipt(room)))
        assertTrue(store.snapshot().conversations.isEmpty())
        store.close(); store = SqliteClientStore(context, actor, device)
        assertEquals(room, store.snapshot().groupCreations.single().room); assertTrue(store.groupWorks().single().cancellationRequested); store.close()
    }
    @Test fun membershipDraftReplacementIsAtomicAndFrozenAdmissionCannotBeRenewed() = runBlocking {
        val actor = UserId(UUID.randomUUID().toString()); val target = UserId(UUID.randomUUID().toString()); val device = DeviceId(UUID.randomUUID().toString())
        val room = RoomId(UUID.randomUUID().toString())
        val intent = MembershipIntent(actor, room, UUID.randomUUID().toString().uppercase(), target, MembershipAction.Remove, 7, 116000)
        var store = SqliteClientStore(context, actor, device)
        val work = store.prepareMembership(intent, "old-activation")
        val paused = work.copy(status = MembershipStatus.DraftPaused, preparationAttempts = 1, nextAttemptMilliseconds = 90000)
        store.updateMembership(work, paused); store.close(); store = SqliteClientStore(context, actor, device)
        assertEquals(paused, store.membershipWorks().single())
        val replacementIntent = intent.copy(operation = UUID.randomUUID().toString().uppercase(), revision = 8)
        try { store.replaceMembershipDraft(paused, replacementIntent.copy(target = actor), "new"); fail("draft target silently changed") } catch (_: IllegalArgumentException) { }
        assertEquals(paused, store.membershipWorks().single())
        val replacement = store.replaceMembershipDraft(paused, replacementIntent, "new")
        assertEquals(90000L, replacement.nextAttemptMilliseconds)
        assertEquals(MembershipStatus.DraftCancelled, store.membershipWorks().first { it.intent == intent }.status)
        val admission = MembershipAdmission(UUID.randomUUID().toString().uppercase(), replacementIntent.fingerprint, MembershipAction.Remove, 8, 3, 2000, 110000)
        val pending = replacement.copy(executionStarted = true,status = MembershipStatus.Pending, admission = admission)
        store.updateMembership(replacement, pending); store.close(); store = SqliteClientStore(context, actor, device)
        try { store.updateMembership(pending, pending.copy(executionStarted = false)); fail("erased execution evidence") } catch (_: IllegalArgumentException) { }
        assertEquals(pending, store.membershipWorks().first { it.intent == replacementIntent })
        try { store.updateMembership(pending, pending.copy(admission = admission.copy(id = UUID.randomUUID().toString().uppercase()))); fail("admission replaced") }
        catch (_: IllegalArgumentException) { }
        val command = pending.command()
        val receipt = buildJsonObject {
            put("identity", command.intent.identity()); put("fingerprint", buildJsonObject { put("version", 1); put("digest", command.fingerprint) })
            put("resolvedAtMilliseconds", 3000)
            put("outcome", buildJsonObject { put("changed", buildJsonObject { put("_0", buildJsonObject {
                put("membershipRevision", 9); put("roomSequence", 40); put("eventID", buildJsonObject { put("rawValue", UUID.randomUUID().toString()) })
            }) }) })
        }.toString()
        store.updateMembership(pending, pending.copy(status = MembershipStatus.Committed, receipt = receipt))
        assertTrue(store.snapshot().conversations.isEmpty()); store.close()
    }
    @Test fun capabilityDraftReplacementAndFrozenProofRemainAccountBoundAcrossReopen() = runBlocking {
        val actor = UserId(UUID.randomUUID().toString()); val target = UserId(UUID.randomUUID().toString()); val device = DeviceId(UUID.randomUUID().toString())
        val room = RoomId(UUID.randomUUID().toString())
        val intent = GroupCapabilityIntent(actor, room, UUID.randomUUID().toString().uppercase(), GroupAction.Role(target, MemberRole.Admin, 7), 116000)
        var store = SqliteClientStore(context, actor, device)
        val work = store.prepareCapability(intent, "old")
        val paused = work.copy(status = GroupCapabilityStatus.DraftPaused, nextAttemptMilliseconds = 90000)
        store.updateCapability(work, paused); store.close(); store = SqliteClientStore(context, actor, device)
        assertEquals(paused, store.capabilityWorks().single())
        val fresh = intent.copy(operation = UUID.randomUUID().toString().uppercase(), action = GroupAction.Role(target, MemberRole.Admin, 8))
        try { store.replaceCapabilityDraft(paused, fresh.copy(action = GroupAction.Role(target, MemberRole.Member, 8)), "new"); fail("desired role changed without a new action") } catch (_: IllegalArgumentException) { }
        assertEquals(paused, store.capabilityWorks().single())
        val replacement = store.replaceCapabilityDraft(paused, fresh, "new")
        assertEquals(90000L, replacement.nextAttemptMilliseconds)
        val admission = GroupCapabilityAdmission(UUID.randomUUID().toString().uppercase(), fresh.fingerprint, 2000, 110000, 3)
        val pending = replacement.copy(executionStarted = true,status = GroupCapabilityStatus.Pending, admission = admission)
        store.updateCapability(replacement, pending); store.close(); store = SqliteClientStore(context, actor, device)
        try { store.updateCapability(pending, pending.copy(executionStarted = false)); fail("erased execution evidence") } catch (_: IllegalArgumentException) { }
        assertEquals(pending, store.capabilityWorks().first { it.intent == fresh })
        try { store.updateCapability(pending, pending.copy(admission = admission.copy(id = UUID.randomUUID().toString().uppercase()))); fail("frozen admission renewed") } catch (_: IllegalArgumentException) { }
        val command = pending.command()
        val receipt = buildJsonObject {
            put("identity", fresh.identity()); put("fingerprint", buildJsonObject { put("version", 1); put("digest", command.fingerprint) }); put("resolvedAtMilliseconds", 3000)
            put("outcome", buildJsonObject { put("applied", buildJsonObject { put("_0", buildJsonObject { put("memberRole", buildJsonObject {
                put("targetUserID", buildJsonObject { put("rawValue", target.value) }); put("role", "admin"); put("membershipRevision", 9); put("roomSequence", 40)
            }) }) }) })
        }.toString()
        store.updateCapability(pending, pending.copy(status = GroupCapabilityStatus.Committed, receipt = receipt))
        assertTrue(store.snapshot().conversations.isEmpty()); assertEquals(2, store.snapshot().capabilityOperations.size)
        store.close()
    }
    @Test fun encryptedJournalRoundTripsAtomicallyWithoutPlaintext() = runBlocking {
        val name = "test-${UUID.randomUUID()}"; val store = KeystoreSecretStore(context, name)
        assertNull(store.read()); store.write("secret-refresh-token")
        assertEquals("secret-refresh-token", KeystoreSecretStore(context, name).read())
        assertFalse(java.io.File(context.noBackupFilesDir, "$name.enc").readBytes().toString(Charsets.UTF_8).contains("secret-refresh-token"))
        store.delete(); assertNull(store.read())
    }
    @Test fun attachmentCommandSurvivesReopenAndUnknownReplyWithoutChangingMediaOrFingerprint()=runBlocking {
        val actor=UserId(UUID.randomUUID().toString());val device=DeviceId(UUID.randomUUID().toString());val room=RoomId(UUID.randomUUID().toString())
        val media=kotlinx.collections.immutable.persistentListOf(UUID.randomUUID().toString().uppercase(),UUID.randomUUID().toString().uppercase())
        val command=MessageCommand.withMedia(actor,room,"",media,System.currentTimeMillis()+60000)
        var store=SqliteClientStore(context,actor,device)
        try {
            store.enqueue(command);store.close();store=SqliteClientStore(context,actor,device);assertEquals(command,store.pending().single())
            val transport=object: EnvelopeTransport {
                override suspend fun request(body: Envelope.Builder): Envelope { assertEquals(command,body.build().messageSendOperation);throw java.io.IOException("unknown outcome") }
            }
            assertTrue(runCatching { MessageOutbox(transport,store).flush() }.exceptionOrNull() is java.io.IOException)
            store.close();store=SqliteClientStore(context,actor,device);assertEquals(media,store.pending().single().mediaIdsList);assertEquals(command.fingerprint,store.pending().single().fingerprint)
        } finally { store.close() }
    }

}

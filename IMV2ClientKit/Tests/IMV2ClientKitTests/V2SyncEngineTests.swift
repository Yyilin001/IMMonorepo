import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 client sync")
struct V2SyncEngineTests {
    @Test("moderation sync facts are durably projected before acknowledgement")
    func moderationProjectionIsApplied() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let payload = try JSONSerialization.data(withJSONObject: [
            "event_type": "member.muted",
            "room_id": "00000000-0000-0000-0000-000000000220",
            "room_sequence": 4,
            "actor_user_id": "00000000-0000-0000-0000-000000000221",
            "target_user_id": "00000000-0000-0000-0000-000000000222",
            "mute_until_ms": 1_750_000_300_000,
            "server_created_at_ms": 1_750_000_000_000,
        ])
        let record = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000223"), projectionKind: "moderation", payload: payload)
        _ = try await store.apply(.init(generation: 1, records: [record], nextSyncToken: .init("moderation-token"), receipt: .init("moderation-receipt"), hasMore: false, capabilityProfile: "base"))

        let action = try #require(await store.moderationActions().first)
        #expect(action.roomSequence == 4)
        #expect(action.targetUserID.rawValue == "00000000-0000-0000-0000-000000000222")
        #expect(action.muteUntil == Date(timeIntervalSince1970: 1_750_000_300))
    }

    @Test("trusted room control facts become a durable current-state projection")
    func roomControlProjectionIsApplied() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let roomID = "00000000-0000-0000-0000-000000000260"
        let actorID = "00000000-0000-0000-0000-000000000261"
        let frozen = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000262"), projectionKind: "moderation", payload: try JSONSerialization.data(withJSONObject: ["event_type": "room.frozen", "room_id": roomID, "room_sequence": 5, "actor_user_id": actorID, "server_created_at_ms": 1_750_000_000_000]))
        let unfrozen = try V2ClientSyncRecord(sequence: 2, sourceEventID: .init("00000000-0000-0000-0000-000000000263"), projectionKind: "moderation", payload: try JSONSerialization.data(withJSONObject: ["event_type": "room.unfrozen", "room_id": roomID, "room_sequence": 6, "actor_user_id": actorID, "server_created_at_ms": 1_750_000_001_000]))
        _ = try await store.apply(.init(generation: 1, records: [frozen, unfrozen], nextSyncToken: .init("room-control-token"), receipt: .init("room-control-receipt"), hasMore: false, capabilityProfile: "base"))

        let control = try #require(await store.roomControl(roomID: .init(roomID)))
        #expect(control.isFrozen == false)
        #expect(control.roomSequence == 6)
        #expect(control.actorUserID.rawValue == actorID)
    }

    @Test("group room identity arrives before its first message")
    func roomProfileProjectionIsApplied() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let roomID = "00000000-0000-0000-0000-000000000267"
        let record = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-000000000268"),
            projectionKind: "room",
            payload: try JSONSerialization.data(withJSONObject: [
                "event_type": "room.created", "room_id": roomID, "title": "项目群",
                "owner_user_id": "00000000-0000-0000-0000-000000000269",
                "membership_revision": 1,
                "created_at_ms": 1_750_000_000_000,
            ])
        )
        _ = try await store.apply(.init(generation: 1, records: [record], nextSyncToken: .init("room-token"), receipt: .init("room-receipt"), hasMore: false, capabilityProfile: "base"))
        let profile = try #require(await store.roomProfile(roomID: .init(roomID)))
        #expect(profile.title == "项目群")
        #expect(try await store.conversationSummaries().isEmpty)
    }

    @Test("a member added after group creation receives a compact room profile")
    func membershipProjectionBootstrapsAddedMemberRoomIdentity() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let roomID = "00000000-0000-0000-0000-000000000270"
        let record = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-000000000271"),
            projectionKind: "membership",
            payload: try JSONSerialization.data(withJSONObject: [
                "event_type": "membership_changed", "room_id": roomID, "title": "后加入的群",
                "owner_user_id": "00000000-0000-0000-0000-000000000272",
                "target_user_id": "00000000-0000-0000-0000-000000000273",
                "action": "add", "membership_revision": 2,
                "created_at_ms": 1_750_000_000_000, "server_created_at_ms": 1_750_000_001_000,
            ])
        )
        _ = try await store.apply(.init(generation: 1, records: [record], nextSyncToken: .init("member-token"), receipt: .init("member-receipt"), hasMore: false, capabilityProfile: "base"))

        let profile = try #require(await store.roomProfile(roomID: .init(roomID)))
        #expect(profile.title == "后加入的群")
        #expect(profile.membershipRevision == 2)
    }

    @Test("local store applies an incremental batch once and accepts an exact retry")
    func incrementalApplyIsIdempotent() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let mentionUserID = "00000000-0000-0000-0000-000000000280"
        let record = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000201"), projectionKind: "message", payload: messagePayload(text: "payload", mentionedUserIDs: [mentionUserID], mentionsEveryone: true))
        let batch = V2ClientSyncBatch(
            generation: 1,
            records: [record],
            nextSyncToken: try .init("token-1"),
            receipt: try .init("receipt-1"),
            hasMore: false,
            capabilityProfile: "base"
        )

        #expect(try await store.apply(batch).appliedSequence == 1)
        #expect(try await store.apply(batch).appliedSequence == 1)
        #expect(try await store.events() == [record])
        let projection = try #require(await store.messages(in: .init("00000000-0000-0000-0000-000000000220")).first)
        #expect(projection.text == "payload")
        #expect(projection.roomSequence == 1)
        #expect(projection.mentions == [.user(try .init(mentionUserID)), .everyone])
    }

    @Test("conversation summaries use the latest durable message per room")
    func conversationSummariesAreDerivedFromProjections() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let roomA = "00000000-0000-0000-0000-000000000220"
        let roomB = "00000000-0000-0000-0000-000000000230"
        let records = [
            try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-0000000002c1"), projectionKind: "message", payload: messagePayload(roomID: roomA, roomSequence: 1, messageID: "00000000-0000-0000-0000-0000000002d1", text: "older", createdAtMilliseconds: 1_750_000_000_000)),
            try V2ClientSyncRecord(sequence: 2, sourceEventID: .init("00000000-0000-0000-0000-0000000002c2"), projectionKind: "message", payload: messagePayload(roomID: roomB, roomSequence: 1, messageID: "00000000-0000-0000-0000-0000000002d2", text: "other room", createdAtMilliseconds: 1_750_000_001_000)),
            try V2ClientSyncRecord(sequence: 3, sourceEventID: .init("00000000-0000-0000-0000-0000000002c3"), projectionKind: "message", payload: messagePayload(roomID: roomA, roomSequence: 2, messageID: "00000000-0000-0000-0000-0000000002d3", text: "latest", createdAtMilliseconds: 1_750_000_002_000)),
        ]
        _ = try await store.apply(.init(generation: 1, records: records, nextSyncToken: .init("summary-token"), receipt: .init("summary-receipt"), hasMore: false, capabilityProfile: "base"))

        let summaries = try await store.conversationSummaries()
        #expect(summaries.map(\.roomID.rawValue) == [roomA, roomB])
        #expect(summaries.map(\.lastMessage.text) == ["latest", "other room"])
        #expect(try await store.messages(in: try .init(roomA)).map(\.text) == ["older", "latest"])
    }

    @Test("social sync records become durable local privacy and relationship projections")
    func socialProjectionsConverge() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let target = "00000000-0000-0000-0000-000000000290"
        let relationship = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000291"), projectionKind: "relationship", payload: socialPayload(["target_user_id": target, "state": "pending", "requested_by_user_id": target, "updated_at_ms": 1_750_000_000_000]))
        let block = try V2ClientSyncRecord(sequence: 2, sourceEventID: .init("00000000-0000-0000-0000-000000000292"), projectionKind: "user_block", payload: socialPayload(["target_user_id": target, "is_blocked": true, "updated_at_ms": 1_750_000_001_000]))
        let preference = try V2ClientSyncRecord(sequence: 3, sourceEventID: .init("00000000-0000-0000-0000-000000000293"), projectionKind: "stranger_message_permission", payload: socialPayload(["allows_stranger_messages": false, "updated_at_ms": 1_750_000_002_000]))
        _ = try await store.apply(.init(generation: 1, records: [relationship, block, preference], nextSyncToken: .init("social-token"), receipt: .init("social-receipt"), hasMore: false, capabilityProfile: "base"))

        let storedRelationship = try #require(await store.relationships().first)
        #expect(storedRelationship.targetUserID.rawValue == target)
        #expect(storedRelationship.state == .pending)
        #expect(try await store.blocks().map(\.targetUserID.rawValue) == [target])
        #expect(try await store.strangerMessagePreference()?.allowsStrangerMessages == false)
    }

    @Test("malformed message projections roll back the entire sync batch")
    func invalidMessagePayloadIsNotAcknowledgedOrPersisted() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let record = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000221"), projectionKind: "message", payload: Data("not-json".utf8))
        let batch = try V2ClientSyncBatch(generation: 1, records: [record], nextSyncToken: .init("invalid-token"), receipt: .init("invalid-receipt"), hasMore: false, capabilityProfile: "base")

        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
            try await store.apply(batch)
        }
        #expect(try await store.cursor() == nil)
        #expect(try await store.events().isEmpty)
    }

    @Test("withdrawal becomes a durable tombstone without losing canonical message order")
    func withdrawalTombstoneIsApplied() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let accepted = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000223"), projectionKind: "message", payload: messagePayload(text: "remove me"))
        let withdrawn = try V2ClientSyncRecord(sequence: 2, sourceEventID: .init("00000000-0000-0000-0000-000000000224"), projectionKind: "message", payload: withdrawalPayload())
        _ = try await store.apply(.init(generation: 1, records: [accepted, withdrawn], nextSyncToken: .init("withdraw-token"), receipt: .init("withdraw-receipt"), hasMore: false, capabilityProfile: "base"))

        let message = try #require(await store.messages(in: .init("00000000-0000-0000-0000-000000000220")).first)
        #expect(message.isWithdrawn)
        #expect(message.messageRevision == 2)
        #expect(message.roomSequence == 1)
    }

    @Test("moderator redaction becomes the same durable tombstone projection")
    func redactionTombstoneIsApplied() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let accepted = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-0000000002a1"), projectionKind: "message", payload: messagePayload(text: "moderate me"))
        let redacted = try V2ClientSyncRecord(sequence: 2, sourceEventID: .init("00000000-0000-0000-0000-0000000002a2"), projectionKind: "message", payload: redactionPayload())
        _ = try await store.apply(.init(generation: 1, records: [accepted, redacted], nextSyncToken: .init("redaction-token"), receipt: .init("redaction-receipt"), hasMore: false, capabilityProfile: "base"))

        let message = try #require(await store.messages(in: .init("00000000-0000-0000-0000-000000000220")).first)
        #expect(message.isWithdrawn)
        #expect(message.messageRevision == 2)
        #expect(try await store.events().map(\.sourceEventID) == [accepted.sourceEventID, redacted.sourceEventID])
    }

    @Test("reaction add and remove converge as a set without changing message content")
    func reactionSetProjectionConverges() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let accepted = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000227"), projectionKind: "message", payload: messagePayload(text: "react to me"))
        let added = try V2ClientSyncRecord(sequence: 2, sourceEventID: .init("00000000-0000-0000-0000-000000000228"), projectionKind: "message", payload: reactionPayload(action: "add"))
        let removed = try V2ClientSyncRecord(sequence: 3, sourceEventID: .init("00000000-0000-0000-0000-000000000229"), projectionKind: "message", payload: reactionPayload(action: "remove"))
        _ = try await store.apply(.init(generation: 1, records: [accepted, added, removed], nextSyncToken: .init("reaction-token"), receipt: .init("reaction-receipt"), hasMore: false, capabilityProfile: "base"))

        #expect(try await store.reactions(for: .init("00000000-0000-0000-0000-000000000001")).isEmpty)
        #expect(try await store.messages(in: .init("00000000-0000-0000-0000-000000000220")).first?.text == "react to me")
    }

    @Test("revision-fenced edit replaces text but cannot overwrite a tombstone")
    func editProjectionReplacesOnlyTheCurrentRevision() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let accepted = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000230"), projectionKind: "message", payload: messagePayload(text: "before"))
        let edited = try V2ClientSyncRecord(sequence: 2, sourceEventID: .init("00000000-0000-0000-0000-000000000231"), projectionKind: "message", payload: editPayload(text: "after", revision: 2))
        _ = try await store.apply(.init(generation: 1, records: [accepted, edited], nextSyncToken: .init("edit-token"), receipt: .init("edit-receipt"), hasMore: false, capabilityProfile: "base"))

        let message = try #require(await store.messages(in: .init("00000000-0000-0000-0000-000000000220")).first)
        #expect(message.text == "after")
        #expect(message.messageRevision == 2)
        #expect(!message.isWithdrawn)
    }

    @Test("a tombstone received before its projection is retained and applied when the projection arrives")
    func withdrawalTombstoneSurvivesProjectionReordering() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let withdrawn = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000225"), projectionKind: "message", payload: withdrawalPayload())
        let accepted = try V2ClientSyncRecord(sequence: 2, sourceEventID: .init("00000000-0000-0000-0000-000000000226"), projectionKind: "message", payload: messagePayload(roomSequence: 2, messageID: "00000000-0000-0000-0000-000000000001", text: "already removed"))

        _ = try await store.apply(.init(generation: 1, records: [withdrawn, accepted], nextSyncToken: .init("withdraw-reordered-token"), receipt: .init("withdraw-reordered-receipt"), hasMore: false, capabilityProfile: "base"))

        let message = try #require(await store.messages(in: .init("00000000-0000-0000-0000-000000000220")).first)
        #expect(message.isWithdrawn)
        #expect(message.messageRevision == 2)
        #expect(message.roomSequence == 2)
    }

    @Test("V2 local database and SQLite sidecars are excluded from backup")
    func localStoreExcludesManagedArtifactsFromBackup() async throws {
        #if canImport(Darwin)
        let directory = try backupEligibleTestDirectory()
        let testRoot = directory.deletingLastPathComponent()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: testRoot)
        }
        let url = directory.appendingPathComponent("v2.sqlite")
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)

        try await store.refreshBackupExclusion()
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                #expect(try sidecar.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
            }
        }
        #else
        // The Darwin backup exclusion resource value does not exist on Linux.
        // SQLite behavior remains covered by the other local-store tests.
        #endif
    }

    @Test("engine persists before acknowledgement and records the acknowledged watermark")
    func engineAcknowledgesOnlyAfterApply() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let record = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000202"), projectionKind: "message", payload: messagePayload(text: "ack"))
        let transport = FakeTransport(pullResult: .ready(.init(
            generation: 1,
            records: [record],
            nextSyncToken: try .init("token-2"),
            receipt: try .init("receipt-2"),
            hasMore: false,
            capabilityProfile: "base"
        )))
        let engine = V2SyncEngine(transport: transport, store: store, capabilityProfile: "base")

        #expect(try await engine.synchronizeOnce() == .synchronized(appliedThrough: 1, hasMore: false))
        #expect(await transport.acknowledgements() == [.init(generation: 1, sequence: 1, receipt: try .init("receipt-2"))])
        #expect(try await store.cursor()?.serverAcknowledgedSequence == 1)
        #expect(try await store.cursor()?.syncToken == .init("token-2"))
    }

    @Test("a mismatched persisted receipt cannot advance the acknowledged watermark")
    func receiptFencesAcknowledgement() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let record = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000205"), projectionKind: "message", payload: messagePayload(text: "receipt"))
        _ = try await store.apply(.init(
            generation: 1,
            records: [record],
            nextSyncToken: try .init("token-3"),
            receipt: try .init("receipt-3"),
            hasMore: false,
            capabilityProfile: "base"
        ))

        await #expect(throws: V2ClientSyncError.acknowledgementReceiptMismatch) {
            try await store.markServerAcknowledged(generation: 1, sequence: 1, receipt: .init("wrong-receipt"))
        }
        #expect(try await store.cursor()?.serverAcknowledgedSequence == 0)
    }

    @Test("a batch for an unnegotiated capability profile is never persisted or acknowledged")
    func rejectsUnsupportedCapabilityProfile() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let transport = FakeTransport(pullResult: .ready(.init(
            generation: 1,
            records: [],
            nextSyncToken: try .init("token-unsupported"),
            receipt: try .init("receipt-unsupported"),
            hasMore: false,
            capabilityProfile: "future-profile"
        )))
        let engine = V2SyncEngine(transport: transport, store: store, capabilityProfile: "base")

        await #expect(throws: V2ClientSyncError.unsupportedCapabilityProfile) {
            _ = try await engine.synchronizeOnce()
        }
        #expect(try await store.cursor() == nil)
        #expect(await transport.acknowledgements().isEmpty)
    }

    @Test("sync values outside SQLite's signed integer domain are rejected atomically")
    func rejectsUnpersistableUnsignedSequences() async throws {
        let limitExceeded = UInt64(Int64.max) + 1

        let oversizedRecordStore = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let oversizedRecord = V2ClientSyncRecord(
            sequence: limitExceeded,
            sourceEventID: try .init("00000000-0000-0000-0000-0000000002b1"),
            projectionKind: "message",
            payload: messagePayload(text: "must not persist")
        )
        await #expect(throws: V2ClientSyncError.storageRangeExceeded) {
            try await oversizedRecordStore.apply(.init(generation: 1, records: [oversizedRecord], nextSyncToken: try .init("range-token-1"), receipt: try .init("range-receipt-1"), hasMore: false, capabilityProfile: "base"))
        }
        #expect(try await oversizedRecordStore.cursor() == nil)
        #expect(try await oversizedRecordStore.events().isEmpty)

        let oversizedProjectionStore = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let oversizedProjection = V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: try .init("00000000-0000-0000-0000-0000000002b2"),
            projectionKind: "message",
            payload: messagePayload(roomSequence: limitExceeded, text: "must not persist")
        )
        await #expect(throws: V2ClientSyncError.storageRangeExceeded) {
            try await oversizedProjectionStore.apply(.init(generation: 1, records: [oversizedProjection], nextSyncToken: try .init("range-token-2"), receipt: try .init("range-receipt-2"), hasMore: false, capabilityProfile: "base"))
        }
        #expect(try await oversizedProjectionStore.cursor() == nil)
        #expect(try await oversizedProjectionStore.events().isEmpty)
    }

    @Test("snapshot reset stays fenced until durable snapshot acknowledgement")
    func resetSnapshotFence() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let snapshotID = try SnapshotID("00000000-0000-0000-0000-000000000203")
        let reset = V2ClientResetRequired(
            snapshotID: snapshotID,
            generation: 2,
            baseSequence: 7,
            manifestDigest: "digest",
            expiresAt: .distantFuture
        )
        let transport = FakeTransport(pullResult: .resetRequired(reset))
        let engine = V2SyncEngine(transport: transport, store: store, capabilityProfile: "base")

        #expect(try await engine.synchronizeOnce() == .resetPending(reset))
        #expect(try await store.cursor()?.state == .resetPending)
        try await engine.completePendingReset()
        let cursor = try #require(await store.cursor())
        #expect(cursor.state == .ready)
        #expect(cursor.generation == 2)
        #expect(cursor.appliedSequence == 7)
        #expect(cursor.serverAcknowledgedSequence == 7)
        #expect(await transport.snapshotAcknowledgementCount() == 1)
    }

    @Test("verified snapshot swap atomically rebuilds the message projection")
    func snapshotSwapRebuildsMessages() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let reset = try V2ClientResetRequired(snapshotID: .init("00000000-0000-0000-0000-000000000230"), generation: 2, baseSequence: 3, manifestDigest: "snapshot-projection", expiresAt: .distantFuture)
        let snapshotMessage = try V2SnapshotMessageProjection(
            sourceEventID: .init("00000000-0000-0000-0000-000000000231"),
            messageID: .init("00000000-0000-0000-0000-000000000232"),
            roomID: .init("00000000-0000-0000-0000-000000000233"),
            roomSequence: 7,
            messageRevision: 2,
            senderUserID: .init("00000000-0000-0000-0000-000000000234"),
            text: "from snapshot",
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            isWithdrawn: true,
            reactions: [try .init(actorUserID: .init("00000000-0000-0000-0000-000000000235"), reaction: "👍")]
        )
        let engine = V2SyncEngine(
            transport: ProjectionSnapshotTransport(reset: reset, payload: try V2SnapshotProjectionCodec.encode(messages: [snapshotMessage])),
            store: store,
            capabilityProfile: "base"
        )

        #expect(try await engine.synchronizeOnce() == .resetPending(reset))
        try await engine.completePendingReset()
        let restored = try #require(await store.messages(in: snapshotMessage.roomID).first)
        #expect(restored.messageID == snapshotMessage.messageID)
        #expect(restored.text == "from snapshot")
        #expect(restored.messageRevision == 2)
        #expect(restored.isWithdrawn)
        #expect(try await store.reactions(for: snapshotMessage.messageID) == [.init(roomID: snapshotMessage.roomID, messageID: snapshotMessage.messageID, actorUserID: .init("00000000-0000-0000-0000-000000000235"), reaction: "👍")])
        #expect(try await store.reactions(in: snapshotMessage.roomID) == [.init(roomID: snapshotMessage.roomID, messageID: snapshotMessage.messageID, actorUserID: .init("00000000-0000-0000-0000-000000000235"), reaction: "👍")])
        #expect(try await store.cursor()?.appliedSequence == 3)
    }

    @Test("verified snapshot replaces social projections together with messages")
    func snapshotSwapRebuildsSocialProjections() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let oldRelationshipTarget = "00000000-0000-0000-0000-000000000241"
        let oldBlockTarget = "00000000-0000-0000-0000-000000000242"
        let existing = [
            try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000243"), projectionKind: "relationship", payload: socialPayload(["target_user_id": oldRelationshipTarget, "state": "pending", "requested_by_user_id": oldRelationshipTarget, "updated_at_ms": 1_750_000_000_000])),
            try V2ClientSyncRecord(sequence: 2, sourceEventID: .init("00000000-0000-0000-0000-000000000244"), projectionKind: "user_block", payload: socialPayload(["target_user_id": oldBlockTarget, "is_blocked": true, "updated_at_ms": 1_750_000_000_000])),
            try V2ClientSyncRecord(sequence: 3, sourceEventID: .init("00000000-0000-0000-0000-000000000245"), projectionKind: "stranger_message_permission", payload: socialPayload(["allows_stranger_messages": false, "updated_at_ms": 1_750_000_000_000]))
        ]
        _ = try await store.apply(.init(generation: 1, records: existing, nextSyncToken: .init("before-social-reset"), receipt: .init("before-social-reset-receipt"), hasMore: false, capabilityProfile: "base"))

        let reset = try V2ClientResetRequired(snapshotID: .init("00000000-0000-0000-0000-000000000246"), generation: 2, baseSequence: 6, manifestDigest: "social-snapshot", expiresAt: .distantFuture)
        let relationship = try V2SnapshotRelationshipProjection(targetUserID: .init("00000000-0000-0000-0000-000000000247"), state: .accepted, requestedByUserID: nil, updatedAt: Date(timeIntervalSince1970: 1_750_000_010))
        let userBlock = V2SnapshotUserBlockProjection(targetUserID: try .init("00000000-0000-0000-0000-000000000248"), isBlocked: true, updatedAt: Date(timeIntervalSince1970: 1_750_000_011))
        let preference = V2SnapshotStrangerMessagePreference(allowsStrangerMessages: true, updatedAt: Date(timeIntervalSince1970: 1_750_000_012))
        let page = try V2SnapshotProjectionPage(messages: [], relationships: [relationship], userBlocks: [userBlock], strangerMessagePreference: preference)
        let engine = V2SyncEngine(transport: ProjectionSnapshotTransport(reset: reset, payload: try V2SnapshotProjectionCodec.encode(page)), store: store, capabilityProfile: "base")

        #expect(try await engine.synchronizeOnce() == .resetPending(reset))
        try await engine.completePendingReset()
        #expect(try await store.relationships() == [.init(targetUserID: relationship.targetUserID, state: .accepted, requestedByUserID: nil, updatedAt: relationship.updatedAt)])
        #expect(try await store.blocks() == [.init(targetUserID: userBlock.targetUserID, isBlocked: true, updatedAt: userBlock.updatedAt)])
        #expect(try await store.strangerMessagePreference() == .init(allowsStrangerMessages: true, updatedAt: preference.updatedAt))
        #expect(try await store.events().isEmpty)
    }

    @Test("verified snapshot replaces moderation projections together with all other reset state")
    func snapshotSwapRebuildsModerationProjections() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let existingPayload = try JSONSerialization.data(withJSONObject: [
            "event_type": "member.muted",
            "room_id": "00000000-0000-0000-0000-000000000251",
            "room_sequence": 1,
            "actor_user_id": "00000000-0000-0000-0000-000000000252",
            "target_user_id": "00000000-0000-0000-0000-000000000253",
            "mute_until_ms": 1_750_000_100_000,
            "server_created_at_ms": 1_750_000_000_000,
        ])
        let existing = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000254"), projectionKind: "moderation", payload: existingPayload)
        _ = try await store.apply(.init(generation: 1, records: [existing], nextSyncToken: .init("before-moderation-reset"), receipt: .init("before-moderation-reset-receipt"), hasMore: false, capabilityProfile: "base"))

        let reset = try V2ClientResetRequired(snapshotID: .init("00000000-0000-0000-0000-000000000255"), generation: 2, baseSequence: 4, manifestDigest: "moderation-snapshot", expiresAt: .distantFuture)
        let action = try V2SnapshotModerationProjection(
            sourceEventID: .init("00000000-0000-0000-0000-000000000256"),
            roomID: .init("00000000-0000-0000-0000-000000000257"),
            roomSequence: 2,
            actorUserID: .init("00000000-0000-0000-0000-000000000258"),
            targetUserID: .init("00000000-0000-0000-0000-000000000259"),
            muteUntil: Date(timeIntervalSince1970: 1_750_000_600),
            createdAt: Date(timeIntervalSince1970: 1_750_000_010)
        )
        let roomControl = try V2SnapshotRoomControlProjection(
            sourceEventID: .init("00000000-0000-0000-0000-000000000264"),
            roomID: .init("00000000-0000-0000-0000-000000000265"),
            roomSequence: 3,
            actorUserID: .init("00000000-0000-0000-0000-000000000266"),
            isFrozen: true,
            createdAt: Date(timeIntervalSince1970: 1_750_000_011)
        )
        let roomProfile = try V2SnapshotRoomProfileProjection(
            sourceEventID: .init("00000000-0000-0000-0000-000000000267"),
            roomID: .init("00000000-0000-0000-0000-000000000268"),
            title: "重置群聊",
            ownerUserID: .init("00000000-0000-0000-0000-000000000269"),
            membershipRevision: 1,
            createdAt: Date(timeIntervalSince1970: 1_750_000_012)
        )
        let page = try V2SnapshotProjectionPage(messages: [], relationships: [], userBlocks: [], strangerMessagePreference: nil, moderationActions: [action], roomControls: [roomControl], roomProfiles: [roomProfile])
        let engine = V2SyncEngine(transport: ProjectionSnapshotTransport(reset: reset, payload: try V2SnapshotProjectionCodec.encode(page)), store: store, capabilityProfile: "base")

        #expect(try await engine.synchronizeOnce() == .resetPending(reset))
        try await engine.completePendingReset()
        #expect(try await store.moderationActions() == [.init(snapshotProjection: action)])
        #expect(try await store.roomControl(roomID: roomControl.roomID)?.isFrozen == true)
        #expect(try await store.roomProfile(roomID: roomProfile.roomID)?.title == "重置群聊")
        #expect(try await store.events().isEmpty)
    }

    @Test("an interrupted snapshot keeps the ready projection and resumes only missing pages")
    func snapshotStagingResumesAfterInterruption() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let existing = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000209"), projectionKind: "message", payload: messagePayload(text: "ready"))
        _ = try await store.apply(.init(generation: 1, records: [existing], nextSyncToken: .init("before-reset"), receipt: .init("before-receipt"), hasMore: false, capabilityProfile: "base"))
        let reset = try V2ClientResetRequired(snapshotID: .init("00000000-0000-0000-0000-000000000210"), generation: 2, baseSequence: 4, manifestDigest: "reset-digest", expiresAt: .distantFuture)
        let transport = ResumableSnapshotTransport(reset: reset)
        let engine = V2SyncEngine(transport: transport, store: store, capabilityProfile: "base")

        #expect(try await engine.synchronizeOnce() == .resetPending(reset))
        await #expect(throws: SnapshotInterruption.once) {
            try await engine.completePendingReset()
        }
        #expect(try await store.events() == [existing])
        #expect(try await store.cursor()?.state == .resetPending)

        try await engine.completePendingReset()
        #expect(try await store.events().isEmpty)
        #expect(try await store.cursor()?.state == .ready)
        #expect(await transport.pageRequests() == [0, 1, 1])
        #expect(await transport.snapshotAcknowledgements() == 1)
    }

    @Test("availability-driven sync drains all contiguous batches")
    func drainsUntilCaughtUp() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let first = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000206"), projectionKind: "message", payload: messagePayload(text: "first"))
        let second = try V2ClientSyncRecord(sequence: 2, sourceEventID: .init("00000000-0000-0000-0000-000000000207"), projectionKind: "message", payload: messagePayload(roomSequence: 2, text: "second"))
        let transport = SequencedTransport(results: [
            .ready(.init(generation: 1, records: [first], nextSyncToken: try .init("token-4"), receipt: try .init("receipt-4"), hasMore: true, capabilityProfile: "base")),
            .ready(.init(generation: 1, records: [second], nextSyncToken: try .init("token-5"), receipt: try .init("receipt-5"), hasMore: false, capabilityProfile: "base")),
        ])
        let engine = V2SyncEngine(transport: transport, store: store, capabilityProfile: "base")

        #expect(try await engine.synchronizeUntilCaughtUp() == .synchronized(appliedThrough: 2, hasMore: false))
        #expect(await transport.pullCount() == 2)
        #expect(try await store.events() == [first, second])
    }

    @Test("availability runner turns a hint into durable sync work")
    func availabilityRunnerTriggersSync() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let record = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000208"), projectionKind: "message", payload: messagePayload(text: "hint"))
        let engine = V2SyncEngine(
            transport: FakeTransport(pullResult: .ready(.init(generation: 1, records: [record], nextSyncToken: try .init("token-6"), receipt: try .init("receipt-6"), hasMore: false, capabilityProfile: "base"))),
            store: store,
            capabilityProfile: "base"
        )
        let runner = V2AvailabilityDrivenSyncRunner(source: OneHintThenStopSource(), syncEngine: engine)

        await #expect(throws: AvailabilityStop.finished) {
            try await runner.run()
        }
        #expect(try await store.events() == [record])
    }

    @Test("availability runner flushes durable commands after the projection is synchronized")
    func availabilityRunnerFlushesAfterSync() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let record = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000209"), projectionKind: "message", payload: messagePayload(text: "flush"))
        let engine = V2SyncEngine(
            transport: FakeTransport(pullResult: .ready(.init(generation: 1, records: [record], nextSyncToken: try .init("token-7"), receipt: try .init("receipt-7"), hasMore: false, capabilityProfile: "base"))),
            store: store,
            capabilityProfile: "base"
        )
        let flushRecorder = AvailabilityFlushRecorder()
        let runner = V2AvailabilityDrivenSyncRunner(
            source: OneHintThenStopSource(),
            syncEngine: engine,
            afterSynchronization: { await flushRecorder.record() }
        )

        await #expect(throws: AvailabilityStop.finished) {
            try await runner.run()
        }

        #expect(try await store.events() == [record])
        #expect(await flushRecorder.count() == 1)
    }
}

private actor FakeTransport: V2ClientSyncTransport {
    private let pullResult: V2ClientPullResult
    private var acknowledgementsLog: [Acknowledgement] = []
    private var snapshotAcknowledgements = 0

    init(pullResult: V2ClientPullResult) { self.pullResult = pullResult }
    func pull(syncToken _: V2SyncToken?, maxRecords _: Int) -> V2ClientPullResult { pullResult }
    func acknowledge(generation: UInt64, highestContiguousSequence: UInt64, receipt: V2SyncReceipt) { acknowledgementsLog.append(.init(generation: generation, sequence: highestContiguousSequence, receipt: receipt)) }
    func fetchSnapshotManifest(for reset: V2ClientResetRequired) throws -> V2ClientSnapshotManifest { try .init(reset: reset, pageDigests: ["page-0"], nextSyncToken: .init("snapshot-token"), receipt: .init("snapshot-receipt"), capabilityProfile: "base") }
    func fetchSnapshotPage(for _: V2ClientSnapshotManifest, index: Int) throws -> V2ClientSnapshotPage { .init(index: index, digest: "page-\(index)", payload: emptySnapshotPayload()) }
    func acknowledgeSnapshot(_: V2ClientSnapshotManifest) { snapshotAcknowledgements += 1 }
    func acknowledgements() -> [Acknowledgement] { acknowledgementsLog }
    func snapshotAcknowledgementCount() -> Int { snapshotAcknowledgements }
}

private struct Acknowledgement: Equatable, Sendable {
    let generation: UInt64
    let sequence: UInt64
    let receipt: V2SyncReceipt
}

private actor SequencedTransport: V2ClientSyncTransport {
    private var results: [V2ClientPullResult]
    private var pulls = 0

    init(results: [V2ClientPullResult]) { self.results = results }

    func pull(syncToken _: V2SyncToken?, maxRecords _: Int) throws -> V2ClientPullResult {
        pulls += 1
        guard !results.isEmpty else { throw V2ClientSyncError.invalidRecordOrdering }
        return results.removeFirst()
    }

    func acknowledge(generation _: UInt64, highestContiguousSequence _: UInt64, receipt _: V2SyncReceipt) {}
    func fetchSnapshotManifest(for _: V2ClientResetRequired) throws -> V2ClientSnapshotManifest { throw V2ClientSyncError.snapshotMismatch }
    func fetchSnapshotPage(for _: V2ClientSnapshotManifest, index _: Int) throws -> V2ClientSnapshotPage { throw V2ClientSyncError.snapshotMismatch }
    func acknowledgeSnapshot(_: V2ClientSnapshotManifest) {}
    func pullCount() -> Int { pulls }
}

private enum SnapshotInterruption: Error { case once }

private actor ResumableSnapshotTransport: V2ClientSyncTransport {
    private let reset: V2ClientResetRequired
    private var didInterrupt = false
    private var requestedPages: [Int] = []
    private var acknowledgements = 0

    init(reset: V2ClientResetRequired) { self.reset = reset }

    func pull(syncToken _: V2SyncToken?, maxRecords _: Int) -> V2ClientPullResult { .resetRequired(reset) }
    func acknowledge(generation _: UInt64, highestContiguousSequence _: UInt64, receipt _: V2SyncReceipt) {}
    func fetchSnapshotManifest(for reset: V2ClientResetRequired) throws -> V2ClientSnapshotManifest {
        try .init(reset: reset, pageDigests: ["page-0", "page-1"], nextSyncToken: .init("after-reset"), receipt: .init("reset-receipt"), capabilityProfile: "base")
    }
    func fetchSnapshotPage(for _: V2ClientSnapshotManifest, index: Int) throws -> V2ClientSnapshotPage {
        requestedPages.append(index)
        if index == 1, !didInterrupt {
            didInterrupt = true
            throw SnapshotInterruption.once
        }
        return .init(index: index, digest: "page-\(index)", payload: emptySnapshotPayload())
    }
    func acknowledgeSnapshot(_: V2ClientSnapshotManifest) { acknowledgements += 1 }
    func pageRequests() -> [Int] { requestedPages }
    func snapshotAcknowledgements() -> Int { acknowledgements }
}

private struct ProjectionSnapshotTransport: V2ClientSyncTransport {
    let reset: V2ClientResetRequired
    let payload: Data

    func pull(syncToken _: V2SyncToken?, maxRecords _: Int) -> V2ClientPullResult { .resetRequired(reset) }
    func acknowledge(generation _: UInt64, highestContiguousSequence _: UInt64, receipt _: V2SyncReceipt) {}
    func fetchSnapshotManifest(for reset: V2ClientResetRequired) throws -> V2ClientSnapshotManifest {
        try .init(reset: reset, pageDigests: ["page-0"], nextSyncToken: .init("projection-token"), receipt: .init("projection-receipt"), capabilityProfile: "base")
    }
    func fetchSnapshotPage(for _: V2ClientSnapshotManifest, index: Int) -> V2ClientSnapshotPage { .init(index: index, digest: "page-0", payload: payload) }
    func acknowledgeSnapshot(_: V2ClientSnapshotManifest) {}
}

private enum AvailabilityStop: Error { case finished }

private actor OneHintThenStopSource: V2SyncAvailabilityHintSource {
    private var emitted = false

    func nextAvailabilityHint() throws -> V2SyncAvailabilityHint {
        guard !emitted else { throw AvailabilityStop.finished }
        emitted = true
        return .init(eventID: 1, highWatermark: 1)
    }
}

private actor AvailabilityFlushRecorder {
    private var flushes = 0
    func record() { flushes += 1 }
    func count() -> Int { flushes }
}

private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "im-v2-client-\(UUID().uuidString).sqlite")
}

#if canImport(Darwin)
private func backupEligibleTestDirectory() throws -> URL {
    guard let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        throw CocoaError(.fileNoSuchFile)
    }
    let directory = applicationSupport
        .appendingPathComponent("IMV2ClientKitTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
#endif

private let testInstallationBinding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)

private func messagePayload(roomID: String = "00000000-0000-0000-0000-000000000220", roomSequence: UInt64 = 1, messageID: String? = nil, text: String, mentionedUserIDs: [String] = [], mentionsEveryone: Bool = false, createdAtMilliseconds: Int64 = 1_750_000_000_000) -> Data {
    try! JSONEncoder().encode(TestMessagePayload(roomID: roomID, roomSequence: roomSequence, messageID: messageID, text: text, mentionedUserIDs: mentionedUserIDs, mentionsEveryone: mentionsEveryone, createdAtMilliseconds: createdAtMilliseconds))
}

private func socialPayload(_ value: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

private struct TestMessagePayload: Encodable {
    let eventType = "message.accepted"
    let messageID: String
    let roomID: String
    let roomSequence: UInt64
    let messageRevision: UInt64 = 1
    let senderUserID = "00000000-0000-0000-0000-000000000222"
    let text: String
    let mentionedUserIDs: [String]
    let mentionsEveryone: Bool
    let serverCreatedAtMilliseconds: Int64

    init(roomID: String, roomSequence: UInt64, messageID: String?, text: String, mentionedUserIDs: [String], mentionsEveryone: Bool, createdAtMilliseconds: Int64) {
        self.messageID = messageID ?? String(format: "00000000-0000-0000-0000-%012llu", roomSequence)
        self.roomID = roomID
        self.roomSequence = roomSequence
        self.text = text
        self.mentionedUserIDs = mentionedUserIDs
        self.mentionsEveryone = mentionsEveryone
        self.serverCreatedAtMilliseconds = createdAtMilliseconds
    }

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case messageID = "message_id"
        case roomID = "room_id"
        case roomSequence = "room_sequence"
        case messageRevision = "message_revision"
        case senderUserID = "sender_user_id"
        case text
        case mentionedUserIDs = "mention_user_ids"
        case mentionsEveryone = "mentions_everyone"
        case serverCreatedAtMilliseconds = "server_created_at_ms"
    }
}

private func withdrawalPayload() -> Data {
    try! JSONEncoder().encode(TestWithdrawalPayload(eventType: "message.withdrawn"))
}

private func redactionPayload() -> Data {
    try! JSONEncoder().encode(TestWithdrawalPayload(eventType: "message.redacted"))
}

private func reactionPayload(action: String) -> Data {
    try! JSONEncoder().encode(TestReactionPayload(action: action))
}

private func editPayload(text: String, revision: UInt64) -> Data {
    try! JSONEncoder().encode(TestEditPayload(text: text, messageRevision: revision))
}

private struct TestEditPayload: Encodable {
    let eventType = "message.edited"
    let roomID = "00000000-0000-0000-0000-000000000220"
    let messageID = "00000000-0000-0000-0000-000000000001"
    let text: String
    let messageRevision: UInt64
    enum CodingKeys: String, CodingKey { case eventType = "event_type"; case roomID = "room_id"; case messageID = "message_id"; case text; case messageRevision = "message_revision" }
}

private struct TestReactionPayload: Encodable {
    let eventType = "message.reaction_changed"
    let roomID = "00000000-0000-0000-0000-000000000220"
    let messageID = "00000000-0000-0000-0000-000000000001"
    let actorUserID = "00000000-0000-0000-0000-000000000222"
    let reaction = "👍"
    let action: String
    enum CodingKeys: String, CodingKey { case eventType = "event_type"; case roomID = "room_id"; case messageID = "message_id"; case actorUserID = "actor_user_id"; case reaction; case action }
}

private struct TestWithdrawalPayload: Encodable {
    let eventType: String
    let roomID = "00000000-0000-0000-0000-000000000220"
    let messageID = "00000000-0000-0000-0000-000000000001"
    let messageRevision: UInt64 = 2

    init(eventType: String) { self.eventType = eventType }
    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case roomID = "room_id"
        case messageID = "message_id"
        case messageRevision = "message_revision"
    }
}

private func emptySnapshotPayload() -> Data {
    try! V2SnapshotProjectionCodec.encode(messages: [])
}

import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 client sync")
struct V2SyncEngineTests {
    @Test("favorite collection uses a stable bounded keyset cursor")
    func favoriteCollectionPagination() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let roomID = "00000000-0000-0000-0000-000000000180"
        let messageIDs = [
            "00000000-0000-0000-0000-000000000181",
            "00000000-0000-0000-0000-000000000182",
            "00000000-0000-0000-0000-000000000183",
        ]
        var records: [V2ClientSyncRecord] = []
        for (index, messageID) in messageIDs.enumerated() {
            records.append(try .init(
                sequence: UInt64(index + 1),
                sourceEventID: .init("00000000-0000-0000-0000-00000000018\(index + 4)"),
                projectionKind: "message",
                payload: messagePayload(
                    roomID: roomID,
                    roomSequence: UInt64(index + 1),
                    messageID: messageID,
                    text: "favorite-\(index + 1)",
                    createdAtMilliseconds: 1_750_000_000_000 + Int64(index)
                )
            ))
        }
        for (index, messageID) in messageIDs.enumerated() {
            records.append(try .init(
                sequence: UInt64(index + 4),
                sourceEventID: .init("00000000-0000-0000-0000-00000000019\(index + 1)"),
                projectionKind: "message_favorite",
                payload: JSONSerialization.data(withJSONObject: [
                    "room_id": roomID,
                    "message_id": messageID,
                    "is_favorited": true,
                    "updated_at_ms": 1_750_000_100_000 + index,
                ])
            ))
        }
        _ = try await store.apply(.init(
            generation: 1,
            records: records,
            nextSyncToken: .init("favorite-page-token"),
            receipt: .init("favorite-page-receipt"),
            hasMore: false,
            capabilityProfile: "base"
        ))

        let first = try await store.favoritedMessages(limit: 2)
        #expect(first.messages.map(\.messageID.rawValue) == [messageIDs[2], messageIDs[1]])
        let cursor = try #require(first.nextCursor)
        let second = try await store.favoritedMessages(before: cursor, limit: 2)
        #expect(second.messages.map(\.messageID.rawValue) == [messageIDs[0]])
        #expect(second.nextCursor == nil)
    }

    @Test("conversation preferences and favorites support room-scoped batch reads")
    func conversationPreferenceBatchReads() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let firstRoomID = try RoomID("00000000-0000-0000-0000-000000000201")
        let secondRoomID = try RoomID("00000000-0000-0000-0000-000000000202")
        let firstMessageID = try MessageID("00000000-0000-0000-0000-000000000203")
        let secondMessageID = try MessageID("00000000-0000-0000-0000-000000000204")
        let records = try [
            V2ClientSyncRecord(
                sequence: 1,
                sourceEventID: .init("00000000-0000-0000-0000-000000000205"),
                projectionKind: "conversation_state",
                payload: JSONSerialization.data(withJSONObject: [
                    "room_id": firstRoomID.rawValue,
                    "is_pinned": true,
                    "is_archived": false,
                    "mute_until_ms": 1_750_000_100_000,
                    "updated_at_ms": 1_750_000_000_000,
                ])
            ),
            V2ClientSyncRecord(
                sequence: 2,
                sourceEventID: .init("00000000-0000-0000-0000-000000000206"),
                projectionKind: "conversation_state",
                payload: JSONSerialization.data(withJSONObject: [
                    "room_id": secondRoomID.rawValue,
                    "is_pinned": false,
                    "is_archived": true,
                    "mute_until_ms": 0,
                    "updated_at_ms": 1_750_000_000_001,
                ])
            ),
            V2ClientSyncRecord(
                sequence: 3,
                sourceEventID: .init("00000000-0000-0000-0000-000000000207"),
                projectionKind: "message_favorite",
                payload: JSONSerialization.data(withJSONObject: [
                    "room_id": firstRoomID.rawValue,
                    "message_id": firstMessageID.rawValue,
                    "is_favorited": true,
                    "updated_at_ms": 1_750_000_000_002,
                ])
            ),
            V2ClientSyncRecord(
                sequence: 4,
                sourceEventID: .init("00000000-0000-0000-0000-000000000208"),
                projectionKind: "message_favorite",
                payload: JSONSerialization.data(withJSONObject: [
                    "room_id": secondRoomID.rawValue,
                    "message_id": secondMessageID.rawValue,
                    "is_favorited": true,
                    "updated_at_ms": 1_750_000_000_003,
                ])
            ),
        ]

        _ = try await store.apply(.init(
            generation: 1,
            records: records,
            nextSyncToken: .init("batch-read-token"),
            receipt: .init("batch-read-receipt"),
            hasMore: false,
            capabilityProfile: "base"
        ))

        let states = try await store.conversationStates()
        #expect(states.count == 2)
        #expect(states[firstRoomID]?.isPinned == true)
        #expect(states[firstRoomID]?.muteUntil == Date(timeIntervalSince1970: 1_750_000_100))
        #expect(states[secondRoomID]?.isArchived == true)
        #expect(states[secondRoomID]?.muteUntil == nil)
        #expect(try await store.favoritedMessageIDs(in: firstRoomID) == Set([firstMessageID]))
        #expect(try await store.favoritedMessageIDs(in: secondRoomID) == Set([secondMessageID]))
    }

    @Test("private activity is projected separately from messages and disables only the direct composer")
    func privateTimelineActivityAndCapabilityAreApplied() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let roomID = "00000000-0000-0000-0000-000000000210"
        let activity = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-000000000211"),
            projectionKind: "timeline_activity",
            payload: try JSONSerialization.data(withJSONObject: [
                "event_type": "direct_message_restricted",
                "room_id": roomID,
                "timeline_sequence": 2,
                "server_created_at_ms": 1_750_000_000_000,
            ])
        )
        let capability = try V2ClientSyncRecord(
            sequence: 2,
            sourceEventID: .init("00000000-0000-0000-0000-000000000211"),
            projectionKind: "direct_sending_capability",
            payload: try JSONSerialization.data(withJSONObject: [
                "room_id": roomID,
                "can_send": false,
                "updated_at_ms": 1_750_000_000_000,
            ])
        )
        _ = try await store.apply(.init(generation: 1, records: [activity, capability], nextSyncToken: .init("activity-token"), receipt: .init("activity-receipt"), hasMore: false, capabilityProfile: "base"))

        #expect(try await store.messages(in: .init(roomID)).isEmpty)
        let projected = try #require(await store.timelineActivities(in: .init(roomID)).first)
        #expect(projected.kind == .directMessageRestricted)
        #expect(projected.timelineSequence == 2)
        #expect(try await store.directSendingCapability(roomID: .init(roomID))?.canSend == false)
    }

    @Test("conversation timeline uses stable keyset pages across messages and activities")
    func conversationTimelineUsesUnifiedKeysetPages() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let roomID = "00000000-0000-0000-0000-000000000212"
        let records: [V2ClientSyncRecord] = try (1...5).map { sequence in
            if sequence.isMultiple(of: 2) {
                return try .init(
                    sequence: UInt64(sequence),
                    sourceEventID: .init(String(format: "00000000-0000-0000-0000-%012d", 220 + sequence)),
                    projectionKind: "timeline_activity",
                    payload: JSONSerialization.data(withJSONObject: [
                        "event_type": "direct_message_restricted",
                        "room_id": roomID,
                        "timeline_sequence": sequence,
                        "server_created_at_ms": 1_750_000_000_000 + sequence,
                    ])
                )
            }
            return try .init(
                sequence: UInt64(sequence),
                sourceEventID: .init(String(format: "00000000-0000-0000-0000-%012d", 220 + sequence)),
                projectionKind: "message",
                payload: messagePayload(
                    roomID: roomID,
                    roomSequence: UInt64(sequence),
                    messageID: String(format: "00000000-0000-0000-0000-%012d", 230 + sequence),
                    text: "message-\(sequence)"
                )
            )
        }
        _ = try await store.apply(.init(
            generation: 1,
            records: records,
            nextSyncToken: .init("timeline-page-token"),
            receipt: .init("timeline-page-receipt"),
            hasMore: false,
            capabilityProfile: "base"
        ))

        let newest = try await store.conversationTimelinePage(in: .init(roomID), limit: 3)
        #expect((newest.messages.map(\.timelineSequence) + newest.activities.map(\.timelineSequence)).sorted() == [3, 4, 5])
        let cursor = try #require(newest.olderCursor)
        #expect(cursor.timelineSequence == 3)

        let older = try await store.conversationTimelinePage(in: .init(roomID), before: cursor, limit: 3)
        #expect((older.messages.map(\.timelineSequence) + older.activities.map(\.timelineSequence)).sorted() == [1, 2])
        #expect(older.olderCursor == nil)
    }

    @Test("media presentation metadata survives durable message projection")
    func mediaPresentationProjectionIsApplied() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let roomID = "00000000-0000-0000-0000-000000000218"
        let mediaID = "00000000-0000-0000-0000-000000000219"
        let record = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-00000000021a"),
            projectionKind: "message",
            payload: try JSONSerialization.data(withJSONObject: [
                "event_type": "message.accepted",
                "message_id": "00000000-0000-0000-0000-00000000021b",
                "room_id": roomID,
                "room_sequence": 1,
                "message_revision": 1,
                "sender_user_id": "00000000-0000-0000-0000-00000000021c",
                "text": "图片",
                "media_ids": [mediaID],
                "media_presentations": [[
                    "media_id": mediaID,
                    "kind": "image",
                    "content_type": "image/jpeg",
                    "byte_count": 2_048,
                ]],
                "mention_user_ids": [],
                "mentions_everyone": false,
                "server_created_at_ms": 1_750_000_000_000,
            ])
        )
        _ = try await store.apply(.init(generation: 1, records: [record], nextSyncToken: .init("media-token"), receipt: .init("media-receipt"), hasMore: false, capabilityProfile: "base"))

        let message = try #require(await store.messages(in: .init(roomID)).first)
        #expect(message.mediaPresentations == [try .init(mediaID: .init(mediaID), kind: .image, contentType: "image/jpeg", byteCount: 2_048)])
    }

    @Test("forward attribution survives live sync and local projection")
    func forwardAttributionProjectionIsApplied() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let roomID = "00000000-0000-0000-0000-000000000250"
        let sourceMessageID = "00000000-0000-0000-0000-000000000251"
        let sourceSenderID = "00000000-0000-0000-0000-000000000252"
        let record = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-000000000253"),
            projectionKind: "message",
            payload: try JSONSerialization.data(withJSONObject: [
                "event_type": "message.accepted",
                "message_id": "00000000-0000-0000-0000-000000000254",
                "room_id": roomID,
                "room_sequence": 1,
                "message_revision": 1,
                "sender_user_id": "00000000-0000-0000-0000-000000000255",
                "text": "转发内容",
                "forwarded_from_message_id": sourceMessageID,
                "forwarded_from_user_id": sourceSenderID,
                "server_created_at_ms": 1_750_000_000_000,
            ])
        )

        _ = try await store.apply(.init(generation: 1, records: [record], nextSyncToken: .init("forward-token"), receipt: .init("forward-receipt"), hasMore: false, capabilityProfile: "base"))

        let message = try #require(await store.messages(in: .init(roomID)).first)
        let expectedAttribution = try V2ForwardedMessageAttribution(messageID: .init(sourceMessageID), senderUserID: .init(sourceSenderID))
        #expect(message.forwardedFrom == expectedAttribution)
    }

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
        let page = try await store.conversationListPage(isArchived: false, limit: 10)
        #expect(page.entries.map(\.roomID.rawValue) == [roomID])
        #expect(page.entries.first?.lastMessage == nil)
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

    @Test("a hybrid membership projection enrolls the room in cursor synchronization")
    func hybridMembershipProjectionRegistersRoomLog() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let roomID = "00000000-0000-0000-0000-000000000274"
        let record = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-000000000275"),
            projectionKind: "membership",
            payload: try JSONSerialization.data(withJSONObject: [
                "event_type": "membership_changed", "room_id": roomID, "title": "大群",
                "owner_user_id": "00000000-0000-0000-0000-000000000276",
                "target_user_id": "00000000-0000-0000-0000-000000000277",
                "action": "add", "membership_revision": 2,
                "delivery_mode": "large_group_hybrid",
                "created_at_ms": 1_750_000_000_000, "server_created_at_ms": 1_750_000_001_000,
            ])
        )
        _ = try await store.apply(.init(generation: 1, records: [record], nextSyncToken: .init("hybrid-member-token"), receipt: .init("hybrid-member-receipt"), hasMore: false, capabilityProfile: "base"))

        #expect(try await store.knownHybridGroupRoomIDs() == [try .init(roomID)])
        try await store.deactivateHybridGroupRoom(roomID: .init(roomID))
        #expect(try await store.knownHybridGroupRoomIDs().isEmpty)
        #expect(try await store.roomProfile(roomID: .init(roomID))?.deliveryMode == nil)
    }

    @Test("a room-log page and its cursor commit atomically and accept an exact retry")
    func hybridGroupEventPageIsDurableAndIdempotent() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let roomID: RoomID = try .init("00000000-0000-0000-0000-000000000278")
        let event = try V2ClientGroupEvent(
            sourceEventID: .init("00000000-0000-0000-0000-000000000279"),
            roomSequence: 3,
            projectionKind: "message",
            payload: messagePayload(roomID: roomID.rawValue, roomSequence: 3, messageID: "00000000-0000-0000-0000-00000000027a", text: "从群日志拉取")
        )
        let page = V2ClientGroupEventPage(roomID: roomID, events: [event], nextRoomSequence: 3, hasMore: false)

        #expect(try await store.applyGroupEventPage(page) == 3)
        #expect(try await store.applyGroupEventPage(page) == 3)
        #expect(try await store.groupEventCursor(roomID: roomID) == 3)
        #expect(try await store.messages(in: roomID).map(\.text) == ["从群日志拉取"])
    }

    @Test("snapshot reset preserves the authorized hybrid room-log projection and cursor")
    func snapshotPreservesHybridRoomLogOwnership() async throws {
        let store = try GRDBV2LocalSyncStore(
            databaseURL: temporaryDatabaseURL(),
            installationBinding: testInstallationBinding
        )
        let roomID = try RoomID("00000000-0000-0000-0000-0000000002b0")
        let membershipEventID = try EventID("00000000-0000-0000-0000-0000000002b1")
        let membershipPayload = try JSONSerialization.data(withJSONObject: [
            "event_type": "membership_changed",
            "room_id": roomID.rawValue,
            "title": "重置后仍保留的大群",
            "owner_user_id": "00000000-0000-0000-0000-0000000002b2",
            "target_user_id": "00000000-0000-0000-0000-0000000002b3",
            "action": "add",
            "membership_revision": 2,
            "delivery_mode": "large_group_hybrid",
            "created_at_ms": 1_750_000_000_000,
            "server_created_at_ms": 1_750_000_001_000,
        ])
        _ = try await store.apply(.init(
            generation: 1,
            records: [.init(
                sequence: 1,
                sourceEventID: membershipEventID,
                projectionKind: "membership",
                payload: membershipPayload
            )],
            nextSyncToken: .init("hybrid-before-reset"),
            receipt: .init("hybrid-before-reset-receipt"),
            hasMore: false,
            capabilityProfile: "base"
        ))

        let roomEvent = try V2ClientGroupEvent(
            sourceEventID: .init("00000000-0000-0000-0000-0000000002b4"),
            roomSequence: 7,
            projectionKind: "message",
            payload: messagePayload(
                roomID: roomID.rawValue,
                roomSequence: 7,
                messageID: "00000000-0000-0000-0000-0000000002b5",
                text: "room-log-owned"
            )
        )
        let roomPage = V2ClientGroupEventPage(
            roomID: roomID,
            events: [roomEvent],
            nextRoomSequence: 7,
            hasMore: false
        )
        _ = try await store.applyGroupEventPage(roomPage)

        let reset = try V2ClientResetRequired(
            snapshotID: .init("00000000-0000-0000-0000-0000000002b6"),
            generation: 2,
            baseSequence: 1,
            expiresAt: .distantFuture
        )
        let snapshotItem = try V2SnapshotProjectionItem(
            key: .init(projectionKind: "room", entityKey: roomID.rawValue),
            sourceEventID: membershipEventID,
            sequence: 1,
            payload: membershipPayload
        )
        let transport = try ProjectionSnapshotTransport(
            reset: reset,
            pages: [.init(items: [snapshotItem])]
        )
        let engine = V2SyncEngine(
            transport: transport,
            store: store,
            capabilityProfile: "base"
        )

        #expect(try await engine.synchronizeOnce() == .resetPending(reset))
        try await engine.completePendingReset()

        #expect(try await store.groupEventCursor(roomID: roomID) == 7)
        #expect(try await store.messages(in: roomID).map(\.text) == ["room-log-owned"])
        #expect(try await store.applyGroupEventPage(roomPage) == 7)
    }

    @Test("one group-log pull reports durable progress for a foreground caller")
    func hybridGroupEventPullReportsProgress() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let roomID: RoomID = try .init("00000000-0000-0000-0000-00000000027b")
        let event = try V2ClientGroupEvent(
            sourceEventID: .init("00000000-0000-0000-0000-00000000027c"),
            roomSequence: 1,
            projectionKind: "message",
            payload: messagePayload(roomID: roomID.rawValue, roomSequence: 1, messageID: "00000000-0000-0000-0000-00000000027d", text: "前台轮询")
        )
        let transport = GroupEventTransportFake(page: .init(roomID: roomID, events: [event], nextRoomSequence: 1, hasMore: true))
        let engine = V2GroupEventSyncEngine(transport: transport, store: store)

        #expect(try await engine.synchronizeOnePage(roomID: roomID) == .init(appliedEventCount: 1, hasMore: true))
        #expect(try await store.groupEventCursor(roomID: roomID) == 1)
        #expect(try await store.messages(in: roomID).map(\.text) == ["前台轮询"])
    }

    @Test("a standard-group foreground preview stays outside durable group cursors and personal ACKs")
    func standardGroupForegroundPreviewIsTransientAndIdempotent() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let roomID: RoomID = try .init("00000000-0000-0000-0000-00000000028a")
        let profile = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-00000000028b"),
            projectionKind: "membership",
            payload: try JSONSerialization.data(withJSONObject: [
                "event_type": "membership_changed", "room_id": roomID.rawValue, "title": "普通群",
                "owner_user_id": "00000000-0000-0000-0000-00000000028c",
                "target_user_id": "00000000-0000-0000-0000-00000000028d",
                "action": "add", "membership_revision": 2,
                "delivery_mode": "standard_fanout",
                "created_at_ms": 1_750_000_000_000, "server_created_at_ms": 1_750_000_001_000,
            ])
        )
        let delivered = try V2ClientSyncRecord(
            sequence: 2,
            sourceEventID: .init("00000000-0000-0000-0000-00000000028e"),
            projectionKind: "message",
            payload: messagePayload(roomID: roomID.rawValue, roomSequence: 2, messageID: "00000000-0000-0000-0000-00000000028f", text: "可靠投递")
        )
        _ = try await store.apply(.init(generation: 1, records: [profile, delivered], nextSyncToken: .init("standard-preview-token"), receipt: .init("standard-preview-receipt"), hasMore: false, capabilityProfile: "base"))

        let preview = try V2ClientGroupEvent(
            sourceEventID: .init("00000000-0000-0000-0000-000000000290"),
            roomSequence: 3,
            projectionKind: "message",
            payload: messagePayload(roomID: roomID.rawValue, roomSequence: 3, messageID: "00000000-0000-0000-0000-000000000291", text: "前台预览")
        )
        let transport = GroupEventTransportFake(page: .init(roomID: roomID, events: [preview], nextRoomSequence: 3, hasMore: false))
        let engine = V2ForegroundGroupEventPreviewEngine(transport: transport, store: store)

        #expect(try await store.groupDeliveryMode(roomID: roomID) == .standardFanout)
        #expect(try await engine.synchronizeOnePage(roomID: roomID) == .init(appliedEventCount: 1, hasMore: false))
        #expect(await transport.requestedCursors() == [2])
        #expect(try await store.messages(in: roomID).map(\.text) == ["可靠投递", "前台预览"])
        #expect(try await store.groupEventCursor(roomID: roomID) == 0)
        #expect(try await store.cursor()?.appliedSequence == 2)

        // A retry is safe and still does not create a durable room-log ACK.
        #expect(try await engine.synchronizeOnePage(roomID: roomID).appliedEventCount == 1)
        #expect(try await store.groupEventCursor(roomID: roomID) == 0)
    }

    @Test("a forbidden hybrid room is deactivated without blocking normal synchronization")
    func forbiddenHybridRoomStopsFutureCursorPulls() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let roomID = "00000000-0000-0000-0000-00000000027e"
        let record = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-00000000027f"),
            projectionKind: "membership",
            payload: try JSONSerialization.data(withJSONObject: [
                "event_type": "membership_changed", "room_id": roomID, "title": "已移出的大群",
                "owner_user_id": "00000000-0000-0000-0000-000000000280",
                "target_user_id": "00000000-0000-0000-0000-000000000281",
                "action": "remove", "membership_revision": 3,
                "delivery_mode": "large_group_hybrid",
                "created_at_ms": 1_750_000_000_000, "server_created_at_ms": 1_750_000_001_000,
            ])
        )
        _ = try await store.apply(.init(generation: 1, records: [record], nextSyncToken: .init("removed-hybrid-token"), receipt: .init("removed-hybrid-receipt"), hasMore: false, capabilityProfile: "base"))
        let engine = V2GroupEventSyncEngine(transport: ForbiddenGroupEventTransport(), store: store)

        _ = try await engine.synchronizeBackgroundKnownRooms(maximumPages: 1)

        #expect(try await store.knownHybridGroupRoomIDs().isEmpty)
    }

    @Test("background hybrid maintenance is page-bounded and round-robin fair")
    func backgroundHybridMaintenanceIsBoundedAndFair() async throws {
        let first = try RoomID("00000000-0000-0000-0000-0000000002a0")
        let second = try RoomID("00000000-0000-0000-0000-0000000002a1")
        let store = BackgroundGroupEventStoreFake(roomIDs: [first, second])
        let transport = BackgroundGroupEventTransportFake()
        let engine = V2GroupEventSyncEngine(transport: transport, store: store)

        let firstPass = try await engine.synchronizeBackgroundKnownRooms(maximumPages: 3)
        #expect(firstPass == .init(processedPageCount: 3, appliedEventCount: 0, mayHaveRemainingWork: true))
        #expect(await transport.requestedRoomIDs() == [first, second, first])

        let secondPass = try await engine.synchronizeBackgroundKnownRooms(maximumPages: 1)
        #expect(secondPass == .init(processedPageCount: 1, appliedEventCount: 0, mayHaveRemainingWork: true))
        #expect(await transport.requestedRoomIDs() == [first, second, first, second])
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

        let page = try await store.conversationListPage(isArchived: false, limit: 10)
        #expect(page.entries.map(\.roomID.rawValue) == [roomA, roomB])
        #expect(page.entries.compactMap(\.lastMessage?.text) == ["latest", "other room"])
        #expect(try await store.messages(in: try .init(roomA)).map(\.text) == ["older", "latest"])
    }

    @Test("conversation list uses an indexed stable keyset across pinned, empty, and archived rooms")
    func conversationListPagination() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let pinned = "00000000-0000-0000-0000-000000000401"
        let tiedFirst = "00000000-0000-0000-0000-000000000402"
        let tiedSecond = "00000000-0000-0000-0000-000000000403"
        let emptyGroup = "00000000-0000-0000-0000-000000000404"
        let archived = "00000000-0000-0000-0000-000000000405"
        let records = try [
            V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000411"), projectionKind: "message", payload: messagePayload(roomID: pinned, roomSequence: 1, messageID: "00000000-0000-0000-0000-000000000421", text: "pinned", createdAtMilliseconds: 1_750_000_001_000)),
            V2ClientSyncRecord(sequence: 2, sourceEventID: .init("00000000-0000-0000-0000-000000000412"), projectionKind: "message", payload: messagePayload(roomID: tiedFirst, roomSequence: 1, messageID: "00000000-0000-0000-0000-000000000422", text: "tie-a", createdAtMilliseconds: 1_750_000_002_000)),
            V2ClientSyncRecord(sequence: 3, sourceEventID: .init("00000000-0000-0000-0000-000000000413"), projectionKind: "message", payload: messagePayload(roomID: tiedSecond, roomSequence: 1, messageID: "00000000-0000-0000-0000-000000000423", text: "tie-b", createdAtMilliseconds: 1_750_000_002_000)),
            V2ClientSyncRecord(sequence: 4, sourceEventID: .init("00000000-0000-0000-0000-000000000414"), projectionKind: "message", payload: messagePayload(roomID: archived, roomSequence: 1, messageID: "00000000-0000-0000-0000-000000000424", text: "archived", createdAtMilliseconds: 1_750_000_003_000)),
            V2ClientSyncRecord(
                sequence: 5,
                sourceEventID: .init("00000000-0000-0000-0000-000000000415"),
                projectionKind: "room",
                payload: JSONSerialization.data(withJSONObject: [
                    "event_type": "room.created",
                    "room_id": emptyGroup,
                    "title": "Empty Group",
                    "owner_user_id": "00000000-0000-0000-0000-000000000406",
                    "membership_revision": 1,
                    "created_at_ms": 1_750_000_001_500,
                ])
            ),
            V2ClientSyncRecord(sequence: 6, sourceEventID: .init("00000000-0000-0000-0000-000000000416"), projectionKind: "conversation_state", payload: JSONSerialization.data(withJSONObject: [
                "room_id": pinned, "is_pinned": true, "is_archived": false,
                "mute_until_ms": 0, "updated_at_ms": 1_750_000_004_000,
            ])),
            V2ClientSyncRecord(sequence: 7, sourceEventID: .init("00000000-0000-0000-0000-000000000417"), projectionKind: "conversation_state", payload: JSONSerialization.data(withJSONObject: [
                "room_id": archived, "is_pinned": false, "is_archived": true,
                "mute_until_ms": 0, "updated_at_ms": 1_750_000_004_001,
            ])),
        ]
        _ = try await store.apply(.init(generation: 1, records: records, nextSyncToken: .init("conversation-list-1"), receipt: .init("conversation-list-receipt-1"), hasMore: false, capabilityProfile: "base"))

        let first = try await store.conversationListPage(isArchived: false, limit: 2)
        #expect(first.entries.map(\.roomID.rawValue) == [pinned, tiedFirst])
        let cursor = try #require(first.nextCursor)
        let second = try await store.conversationListPage(isArchived: false, before: cursor, limit: 2)
        #expect(second.entries.map(\.roomID.rawValue) == [tiedSecond, emptyGroup])
        #expect(second.entries.last?.lastMessage == nil)
        #expect(second.entries.last?.roomProfile?.title == "Empty Group")
        #expect(second.nextCursor == nil)

        let archivedPage = try await store.conversationListPage(isArchived: true, limit: 2)
        #expect(archivedPage.entries.map(\.roomID.rawValue) == [archived])

        let archiveTie = try V2ClientSyncRecord(sequence: 8, sourceEventID: .init("00000000-0000-0000-0000-000000000418"), projectionKind: "conversation_state", payload: JSONSerialization.data(withJSONObject: [
            "room_id": tiedFirst, "is_pinned": false, "is_archived": true,
            "mute_until_ms": 0, "updated_at_ms": 1_750_000_004_002,
        ]))
        _ = try await store.apply(.init(generation: 1, records: [archiveTie], nextSyncToken: .init("conversation-list-2"), receipt: .init("conversation-list-receipt-2"), hasMore: false, capabilityProfile: "base"))
        #expect(try await store.conversationListPage(isArchived: true, limit: 2).entries.map(\.roomID.rawValue) == [archived, tiedFirst])
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

    @Test("relationship list uses stable bounded pages for each request scope")
    func relationshipListPagination() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let currentUserID = try UserID("00000000-0000-0000-0000-000000000450")
        let acceptedFirst = "00000000-0000-0000-0000-000000000451"
        let acceptedSecond = "00000000-0000-0000-0000-000000000452"
        let incoming = "00000000-0000-0000-0000-000000000453"
        let outgoing = "00000000-0000-0000-0000-000000000454"
        let records = try [
            V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000461"), projectionKind: "relationship", payload: socialPayload(["target_user_id": acceptedFirst, "state": "accepted", "updated_at_ms": 1_750_000_003_000])),
            V2ClientSyncRecord(sequence: 2, sourceEventID: .init("00000000-0000-0000-0000-000000000462"), projectionKind: "relationship", payload: socialPayload(["target_user_id": acceptedSecond, "state": "accepted", "updated_at_ms": 1_750_000_003_000])),
            V2ClientSyncRecord(sequence: 3, sourceEventID: .init("00000000-0000-0000-0000-000000000463"), projectionKind: "relationship", payload: socialPayload(["target_user_id": incoming, "state": "pending", "requested_by_user_id": incoming, "updated_at_ms": 1_750_000_002_000])),
            V2ClientSyncRecord(sequence: 4, sourceEventID: .init("00000000-0000-0000-0000-000000000464"), projectionKind: "relationship", payload: socialPayload(["target_user_id": outgoing, "state": "pending", "requested_by_user_id": currentUserID.rawValue, "updated_at_ms": 1_750_000_001_000])),
        ]
        _ = try await store.apply(.init(generation: 1, records: records, nextSyncToken: .init("relationship-page"), receipt: .init("relationship-page-receipt"), hasMore: false, capabilityProfile: "base"))
        let firstIdentity = try V2PublicIdentity(
            userID: .init(acceptedFirst),
            handle: .init("alice_one"),
            displayName: "Alice 张三"
        )
        let secondIdentity = try V2PublicIdentity(
            userID: .init(acceptedSecond),
            handle: .init("malice_two"),
            displayName: "Malice"
        )
        let revisionOne = try #require(V2ProfileRevision(rawValue: 1))
        try await store.saveProfileView(.init(
            userID: firstIdentity.userID,
            publicIdentity: firstIdentity,
            avatar: nil,
            state: .active,
            revision: revisionOne,
            visibilityRevision: revisionOne
        ))
        try await store.saveProfileView(.init(
            userID: secondIdentity.userID,
            publicIdentity: secondIdentity,
            avatar: nil,
            state: .active,
            revision: revisionOne,
            visibilityRevision: revisionOne
        ))

        let first = try await store.relationshipPage(scope: .accepted, limit: 1, includeTotalCount: true)
        #expect(first.relationships.map(\.targetUserID.rawValue) == [acceptedFirst])
        #expect(first.totalCount == 2)
        let cursor = try #require(first.nextCursor)
        let second = try await store.relationshipPage(scope: .accepted, before: cursor, limit: 1)
        #expect(second.relationships.map(\.targetUserID.rawValue) == [acceptedSecond])
        #expect(second.nextCursor == nil)
        #expect(second.totalCount == nil)

        let incomingPage = try await store.relationshipPage(scope: .incomingRequests(currentUserID: currentUserID), limit: 10, includeTotalCount: true)
        #expect(incomingPage.relationships.map(\.targetUserID.rawValue) == [incoming])
        #expect(incomingPage.totalCount == 1)

        let outgoingPage = try await store.relationshipPage(scope: .outgoingRequests(currentUserID: currentUserID), limit: 10, includeTotalCount: true)
        #expect(outgoingPage.relationships.map(\.targetUserID.rawValue) == [outgoing])
        #expect(outgoingPage.totalCount == 1)

        let firstSearchPage = try await store.relationshipPage(scope: .accepted, matching: "LIC", limit: 1)
        #expect(firstSearchPage.relationships.map(\.targetUserID.rawValue) == [acceptedFirst])
        let searchCursor = try #require(firstSearchPage.nextCursor)
        let secondSearchPage = try await store.relationshipPage(scope: .accepted, matching: "lic", before: searchCursor, limit: 1)
        #expect(secondSearchPage.relationships.map(\.targetUserID.rawValue) == [acceptedSecond])
        #expect(secondSearchPage.nextCursor == nil)
        #expect(try await store.relationshipPage(scope: .accepted, matching: "张三", limit: 10).relationships.map(\.targetUserID.rawValue) == [acceptedFirst])

        let revisionTwo = try #require(V2ProfileRevision(rawValue: 2))
        let renamedIdentity = try V2PublicIdentity(
            userID: firstIdentity.userID,
            handle: .init("carol_one"),
            displayName: "Carol"
        )
        try await store.saveProfileView(.init(
            userID: renamedIdentity.userID,
            publicIdentity: renamedIdentity,
            avatar: nil,
            state: .active,
            revision: revisionTwo,
            visibilityRevision: revisionTwo
        ))
        #expect(try await store.relationshipPage(scope: .accepted, matching: "lic", limit: 10).relationships.map(\.targetUserID.rawValue) == [acceptedSecond])
        try await store.markProfileUnavailable(userID: secondIdentity.userID)
        #expect(try await store.relationshipPage(scope: .accepted, matching: "lic", limit: 10).relationships.isEmpty)
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

    @Test("withdrawal clears independently projected reactions")
    func withdrawalClearsIndependentReactions() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let accepted = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-0000000002c1"), projectionKind: "message", payload: messagePayload(text: "react then withdraw"))
        let added = try V2ClientSyncRecord(sequence: 2, sourceEventID: .init("00000000-0000-0000-0000-0000000002c2"), projectionKind: "message_reaction", payload: reactionPayload(action: "add"))
        let withdrawn = try V2ClientSyncRecord(sequence: 3, sourceEventID: .init("00000000-0000-0000-0000-0000000002c3"), projectionKind: "message", payload: withdrawalPayload())

        _ = try await store.apply(.init(
            generation: 1,
            records: [accepted, added, withdrawn],
            nextSyncToken: .init("withdraw-reaction-token"),
            receipt: .init("withdraw-reaction-receipt"),
            hasMore: false,
            capabilityProfile: "base"
        ))

        #expect(try await store.reactions(for: .init("00000000-0000-0000-0000-000000000001")).isEmpty)
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
        let added = try V2ClientSyncRecord(sequence: 2, sourceEventID: .init("00000000-0000-0000-0000-000000000228"), projectionKind: "message_reaction", payload: reactionPayload(action: "add"))
        let removed = try V2ClientSyncRecord(sequence: 3, sourceEventID: .init("00000000-0000-0000-0000-000000000229"), projectionKind: "message_reaction", payload: reactionPayload(action: "remove"))
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

    @Test("an ACK response loss retries by pulling the persisted token before applying again")
    func lostIncrementalAcknowledgementResponseRecovers() async throws {
        let store = try GRDBV2LocalSyncStore(
            databaseURL: temporaryDatabaseURL(),
            installationBinding: testInstallationBinding
        )
        let record = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-000000000263"),
            projectionKind: "message",
            payload: messagePayload(text: "ack-retry")
        )
        let firstBatch = try V2ClientSyncBatch(
            generation: 1,
            records: [record],
            nextSyncToken: .init("ack-retry-token"),
            receipt: .init("ack-retry-receipt"),
            hasMore: false,
            capabilityProfile: "base"
        )
        let retryBatch = try V2ClientSyncBatch(
            generation: 1,
            records: [],
            nextSyncToken: .init("ack-retry-token-2"),
            receipt: .init("ack-retry-receipt-2"),
            hasMore: false,
            capabilityProfile: "base"
        )
        let transport = LostIncrementalACKTransport(
            first: firstBatch,
            retry: retryBatch
        )
        let engine = V2SyncEngine(
            transport: transport,
            store: store,
            capabilityProfile: "base"
        )

        await #expect(throws: LostIncrementalACKTransport.Failure.responseLost) {
            _ = try await engine.synchronizeOnce()
        }
        #expect(try await store.cursor()?.pendingAcknowledgementReceipt == firstBatch.receipt)

        #expect(try await engine.synchronizeOnce() == .synchronized(
            appliedThrough: 1,
            hasMore: false
        ))
        #expect(await transport.requestedTokens() == [nil, firstBatch.nextSyncToken])
        #expect(await transport.acknowledgementReceipts() == [
            firstBatch.receipt,
            retryBatch.receipt,
        ])
        #expect(try await store.cursor()?.pendingAcknowledgementReceipt == nil)
        #expect(try await store.events() == [record])
    }

    @Test("an expired sync token retries once from the server cursor without duplicating local state")
    func expiredSyncTokenRecoversFromServerCursor() async throws {
        let store = try GRDBV2LocalSyncStore(
            databaseURL: temporaryDatabaseURL(),
            installationBinding: testInstallationBinding
        )
        let record = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-000000000264"),
            projectionKind: "message",
            payload: messagePayload(text: "expired-token")
        )
        let oldReceipt = try V2SyncReceipt("expired-token-old-receipt")
        _ = try await store.apply(.init(
            generation: 1,
            records: [record],
            nextSyncToken: .init("expired-token-old"),
            receipt: oldReceipt,
            hasMore: false,
            capabilityProfile: "base"
        ))
        try await store.markServerAcknowledged(generation: 1, sequence: 1, receipt: oldReceipt)

        let transport = ExpiredSyncTokenTransport(
            batch: try .init(
                generation: 1,
                records: [],
                nextSyncToken: .init("expired-token-recovered"),
                receipt: .init("expired-token-recovered-receipt"),
                hasMore: false,
                capabilityProfile: "base"
            )
        )
        let engine = V2SyncEngine(
            transport: transport,
            store: store,
            capabilityProfile: "base"
        )

        #expect(try await engine.synchronizeOnce() == .synchronized(
            appliedThrough: 1,
            hasMore: false
        ))
        #expect(await transport.requestedTokens() == [
            try V2SyncToken("expired-token-old"),
            nil,
        ])
        #expect(try await store.cursor()?.syncToken == .init("expired-token-recovered"))
        #expect(try await store.events() == [record])
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

    @Test("V3 snapshot atomically replaces typed projections and preserves withdrawn-message privacy")
    func snapshotV3AtomicallyReplacesProjection() async throws {
        let store = try GRDBV2LocalSyncStore(
            databaseURL: temporaryDatabaseURL(),
            installationBinding: testInstallationBinding
        )
        let old = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-000000000229"),
            projectionKind: "message",
            payload: messagePayload(text: "old")
        )
        _ = try await store.apply(.init(
            generation: 1,
            records: [old],
            nextSyncToken: .init("before-v3-reset"),
            receipt: .init("before-v3-reset-receipt"),
            hasMore: false,
            capabilityProfile: "base"
        ))

        let reset = try V2ClientResetRequired(
            snapshotID: .init("00000000-0000-0000-0000-000000000230"),
            generation: 2,
            baseSequence: 6,
            expiresAt: .distantFuture
        )
        let messageID = try MessageID("00000000-0000-0000-0000-000000000232")
        let roomID = try RoomID("00000000-0000-0000-0000-000000000233")
        let relationshipTarget = try UserID("00000000-0000-0000-0000-000000000247")
        let items = [
            try V2SnapshotProjectionItem(
                key: .init(projectionKind: "message", entityKey: messageID.rawValue),
                sourceEventID: .init("00000000-0000-0000-0000-000000000231"),
                sequence: 2,
                payload: snapshotMessagePayload(
                    messageID: messageID.rawValue,
                    roomID: roomID.rawValue,
                    text: "[removed]",
                    revision: 2,
                    isWithdrawn: true
                )
            ),
            try V2SnapshotProjectionItem(
                key: .init(projectionKind: "relationship", entityKey: relationshipTarget.rawValue),
                sourceEventID: .init("00000000-0000-0000-0000-000000000248"),
                sequence: 3,
                payload: socialPayload([
                    "target_user_id": relationshipTarget.rawValue,
                    "state": "accepted",
                    "updated_at_ms": 1_750_000_010_000,
                ])
            ),
        ]
        let transport = try ProjectionSnapshotTransport(
            reset: reset,
            pages: [.init(items: items)]
        )
        let engine = V2SyncEngine(
            transport: transport,
            store: store,
            capabilityProfile: "base"
        )

        #expect(try await engine.synchronizeOnce() == .resetPending(reset))
        try await engine.completePendingReset()

        #expect(try await store.messages(in: .init("00000000-0000-0000-0000-000000000220")).isEmpty)
        let restored = try #require(await store.messages(in: roomID).first)
        #expect(restored.messageID == messageID)
        #expect(restored.text == "[removed]")
        #expect(restored.messageRevision == 2)
        #expect(restored.isWithdrawn)
        #expect(try await store.reactions(for: messageID).isEmpty)
        #expect(try await store.relationships() == [
            .init(
                targetUserID: relationshipTarget,
                state: .accepted,
                requestedByUserID: nil,
                updatedAt: Date(timeIntervalSince1970: 1_750_000_010)
            )
        ])
        #expect(try await store.events().isEmpty)
        #expect(try await store.cursor()?.appliedSequence == 6)
    }

    @Test("V3 snapshot restores reactions as independent bounded projection items")
    func snapshotV3RestoresIndependentReaction() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let messageID = try MessageID("00000000-0000-0000-0000-000000000001")
        let roomID = try RoomID("00000000-0000-0000-0000-000000000220")
        let actorID = try UserID("00000000-0000-0000-0000-000000000222")
        let reset = try V2ClientResetRequired(
            snapshotID: .init("00000000-0000-0000-0000-0000000002d0"),
            generation: 2,
            baseSequence: 2,
            expiresAt: .distantFuture
        )
        let reaction = "👍"
        let items = [
            try V2SnapshotProjectionItem(
                key: .init(projectionKind: "message", entityKey: messageID.rawValue),
                sourceEventID: .init("00000000-0000-0000-0000-0000000002d1"),
                sequence: 1,
                payload: snapshotMessagePayload(
                    messageID: messageID.rawValue,
                    roomID: roomID.rawValue,
                    text: "snapshot reaction",
                    revision: 1,
                    isWithdrawn: false
                )
            ),
            try V2SnapshotProjectionItem(
                key: .init(
                    projectionKind: "message_reaction",
                    entityKey: "\(messageID.rawValue):\(actorID.rawValue):\(reaction)"
                ),
                sourceEventID: .init("00000000-0000-0000-0000-0000000002d2"),
                sequence: 2,
                payload: reactionPayload(action: "add")
            ),
        ]
        let transport = try ProjectionSnapshotTransport(reset: reset, pages: [.init(items: items)])
        let engine = V2SyncEngine(transport: transport, store: store, capabilityProfile: "base")

        #expect(try await engine.synchronizeOnce() == .resetPending(reset))
        try await engine.completePendingReset()

        #expect(try await store.reactions(for: messageID) == [
            .init(roomID: roomID, messageID: messageID, actorUserID: actorID, reaction: reaction)
        ])
    }

    @Test("an interrupted snapshot keeps the ready projection and resumes only missing pages")
    func snapshotStagingResumesAfterInterruption() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let existing = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000209"), projectionKind: "message", payload: messagePayload(text: "ready"))
        _ = try await store.apply(.init(generation: 1, records: [existing], nextSyncToken: .init("before-reset"), receipt: .init("before-receipt"), hasMore: false, capabilityProfile: "base"))
        let reset = try V2ClientResetRequired(snapshotID: .init("00000000-0000-0000-0000-000000000210"), generation: 2, baseSequence: 4, expiresAt: .distantFuture)
        let transport = try ResumableSnapshotTransport(reset: reset)
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

    @Test("a crash after server snapshot ACK resumes from the durable shadow before pulling")
    func snapshotAckCrashWindowResumesSafely() async throws {
        let store = try GRDBV2LocalSyncStore(
            databaseURL: temporaryDatabaseURL(),
            installationBinding: testInstallationBinding
        )
        let existing = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-000000000259"),
            projectionKind: "message",
            payload: messagePayload(text: "live-until-activation")
        )
        let oldReceipt = try V2SyncReceipt("before-ack-crash-receipt")
        _ = try await store.apply(.init(
            generation: 1,
            records: [existing],
            nextSyncToken: .init("before-ack-crash-token"),
            receipt: oldReceipt,
            hasMore: false,
            capabilityProfile: "base"
        ))
        try await store.markServerAcknowledged(generation: 1, sequence: 1, receipt: oldReceipt)

        let reset = try V2ClientResetRequired(
            snapshotID: .init("00000000-0000-0000-0000-000000000260"),
            generation: 2,
            baseSequence: 1,
            expiresAt: .distantFuture
        )
        let transport = try SnapshotCrashWindowTransport(reset: reset)
        try await store.beginReset(reset)
        let manifest = await transport.fetchSnapshotManifest(for: reset)
        try await store.beginSnapshotImport(
            manifest,
            initialDigest: V2SnapshotV3Digest.initial(
                baseSequence: reset.baseSequence,
                capabilityProfile: manifest.capabilityProfile
            )
        )
        // This represents the durable server commit followed by process death
        // before the client can activate its local shadow projection.
        try await transport.acknowledgeSnapshot(manifest)
        #expect(try await store.events() == [existing])

        let restarted = V2SyncEngine(
            transport: transport,
            store: store,
            capabilityProfile: "base"
        )
        #expect(try await restarted.synchronizeOnce() == .resetPending(reset))
        #expect(await transport.pullCount() == 0)
        try await restarted.completePendingReset()

        let cursor = try #require(await store.cursor())
        #expect(cursor.state == .ready)
        #expect(cursor.generation == 2)
        #expect(try await store.events().isEmpty)
        #expect(await transport.manifestRequestCount() == 1)
        #expect(await transport.snapshotAcknowledgementCount() == 2)
    }

    @Test("a server-rejected expired snapshot restores the exact pre-reset cursor")
    func rejectedSnapshotRestoresPreviousCursor() async throws {
        let store = try GRDBV2LocalSyncStore(
            databaseURL: temporaryDatabaseURL(),
            installationBinding: testInstallationBinding
        )
        let existing = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-000000000261"),
            projectionKind: "message",
            payload: messagePayload(text: "preserved-after-expiry")
        )
        let oldToken = try V2SyncToken("before-expired-reset-token")
        let oldReceipt = try V2SyncReceipt("before-expired-reset-receipt")
        _ = try await store.apply(.init(
            generation: 1,
            records: [existing],
            nextSyncToken: oldToken,
            receipt: oldReceipt,
            hasMore: false,
            capabilityProfile: "base"
        ))
        try await store.markServerAcknowledged(generation: 1, sequence: 1, receipt: oldReceipt)

        let reset = try V2ClientResetRequired(
            snapshotID: .init("00000000-0000-0000-0000-000000000262"),
            generation: 2,
            baseSequence: 1,
            expiresAt: .distantPast
        )
        let transport = try SnapshotCrashWindowTransport(
            reset: reset,
            acknowledgementError: .server(
                code: "RESET_REQUIRED",
                retryable: false,
                retryAfterSeconds: 0,
                currentRevision: nil
            )
        )
        try await store.beginReset(reset)
        let engine = V2SyncEngine(
            transport: transport,
            store: store,
            capabilityProfile: "base"
        )

        await #expect(throws: V2RealtimeTransportError.server(
            code: "RESET_REQUIRED",
            retryable: false,
            retryAfterSeconds: 0,
            currentRevision: nil
        )) {
            try await engine.completePendingReset()
        }

        let cursor = try #require(await store.cursor())
        #expect(cursor.state == .ready)
        #expect(cursor.generation == 1)
        #expect(cursor.appliedSequence == 1)
        #expect(cursor.serverAcknowledgedSequence == 1)
        #expect(cursor.syncToken == nil)
        #expect(cursor.pendingReset == nil)
        #expect(try await store.events() == [existing])

        let replayTransport = FakeTransport(pullResult: .ready(.init(
            generation: 1,
            records: [],
            nextSyncToken: try .init("after-expired-reset-token"),
            receipt: try .init("after-expired-reset-receipt"),
            hasMore: false,
            capabilityProfile: "base"
        )))
        let recoveryEngine = V2SyncEngine(
            transport: replayTransport,
            store: store,
            capabilityProfile: "base"
        )
        #expect(try await recoveryEngine.synchronizeOnce() == .synchronized(
            appliedThrough: 1,
            hasMore: false
        ))
        #expect(await replayTransport.acknowledgements().isEmpty)
        #expect(try await store.cursor()?.serverAcknowledgedSequence == 1)
        #expect(try await store.cursor()?.syncToken == .init("after-expired-reset-token"))
        #expect(try await store.events() == [existing])
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

    @Test("availability runner completes a reset before post-sync effects")
    func availabilityRunnerCompletesReset() async throws {
        let store = try GRDBV2LocalSyncStore(
            databaseURL: temporaryDatabaseURL(),
            installationBinding: testInstallationBinding
        )
        let reset = try V2ClientResetRequired(
            snapshotID: .init("00000000-0000-0000-0000-000000000210"),
            generation: 2,
            baseSequence: 7,
            expiresAt: .distantFuture
        )
        let transport = FakeTransport(pullResult: .resetRequired(reset))
        let engine = V2SyncEngine(transport: transport, store: store, capabilityProfile: "base")
        let recorder = AvailabilityFlushRecorder()
        let runner = V2AvailabilityDrivenSyncRunner(
            source: OneHintThenStopSource(),
            syncEngine: engine,
            afterSynchronization: { await recorder.record() }
        )

        await #expect(throws: AvailabilityStop.finished) {
            try await runner.run()
        }

        #expect(try await store.cursor()?.state == .ready)
        #expect(await transport.snapshotAcknowledgementCount() == 1)
        #expect(await recorder.count() == 1)
    }

    @Test("a second snapshot swaps the already-renamed projection bank")
    func repeatedSnapshotActivation() async throws {
        let store = try GRDBV2LocalSyncStore(
            databaseURL: temporaryDatabaseURL(),
            installationBinding: testInstallationBinding
        )
        for generation in UInt64(2) ... 3 {
            let reset = try V2ClientResetRequired(
                snapshotID: .init("00000000-0000-0000-0000-0000000002e\(generation)"),
                generation: generation,
                baseSequence: generation,
                expiresAt: .distantFuture
            )
            let transport = try ProjectionSnapshotTransport(reset: reset, pages: [])
            let engine = V2SyncEngine(transport: transport, store: store, capabilityProfile: "base")
            #expect(try await engine.synchronizeOnce() == .resetPending(reset))
            try await engine.completePendingReset()
            #expect(try await store.cursor()?.generation == generation)
        }
    }

    @Test("prepared snapshot fences local projection writers until cancellation")
    func preparedSnapshotFencesProjectionWrites() async throws {
        let store = try GRDBV2LocalSyncStore(
            databaseURL: temporaryDatabaseURL(),
            installationBinding: testInstallationBinding
        )
        let reset = try V2ClientResetRequired(
            snapshotID: .init("00000000-0000-0000-0000-0000000002e4"),
            generation: 2,
            baseSequence: 0,
            expiresAt: .distantFuture
        )
        let fixture = try makeSnapshotFixture(reset: reset, pages: [])
        try await store.beginReset(reset)
        try await store.beginSnapshotImport(
            fixture.manifest,
            initialDigest: V2SnapshotV3Digest.initial(baseSequence: 0, capabilityProfile: "base")
        )
        try await store.prepareSnapshotActivation(fixture.manifest)

        await #expect(throws: V2ClientSyncError.resetPending) {
            try await store.cacheDirectRoomIdentity(
                roomID: .init("00000000-0000-0000-0000-0000000002e5"),
                publicIdentity: .init(
                    userID: .init("00000000-0000-0000-0000-0000000002e6"),
                    handle: .init("prepared_fence"),
                    displayName: "准备阶段 fence"
                )
            )
        }
        try await store.cancelReset(reset)
        try await store.cacheDirectRoomIdentity(
            roomID: .init("00000000-0000-0000-0000-0000000002e5"),
            publicIdentity: .init(
                userID: .init("00000000-0000-0000-0000-0000000002e6"),
                handle: .init("prepared_fence"),
                displayName: "准备阶段 fence"
            )
        )
    }
}

private actor FakeTransport: V2ClientSyncTransport {
    private let pullResult: V2ClientPullResult
    private var acknowledgementsLog: [Acknowledgement] = []
    private var snapshotAcknowledgements = 0

    init(pullResult: V2ClientPullResult) { self.pullResult = pullResult }
    func pull(syncToken _: V2SyncToken?, maxRecords _: Int) -> V2ClientPullResult { pullResult }
    func acknowledge(generation: UInt64, highestContiguousSequence: UInt64, receipt: V2SyncReceipt) { acknowledgementsLog.append(.init(generation: generation, sequence: highestContiguousSequence, receipt: receipt)) }
    func fetchSnapshotManifest(for reset: V2ClientResetRequired) throws -> V2ClientSnapshotManifest {
        try makeSnapshotFixture(reset: reset, pages: []).manifest
    }
    func fetchSnapshotPage(for _: V2ClientSnapshotManifest, index _: Int) throws -> V2ClientSnapshotPage {
        throw V2ClientSyncError.snapshotMismatch
    }
    func acknowledgeSnapshot(_: V2ClientSnapshotManifest) { snapshotAcknowledgements += 1 }
    func acknowledgements() -> [Acknowledgement] { acknowledgementsLog }
    func snapshotAcknowledgementCount() -> Int { snapshotAcknowledgements }
}

private actor GroupEventTransportFake: V2ClientGroupEventTransport {
    private let page: V2ClientGroupEventPage
    private var cursors: [UInt64] = []

    init(page: V2ClientGroupEventPage) { self.page = page }

    func pullGroupEvents(roomID: RoomID, afterRoomSequence: UInt64, pageSize _: Int) throws -> V2ClientGroupEventPage {
        guard roomID == page.roomID else { throw V2RealtimeTransportError.unexpectedResponse }
        cursors.append(afterRoomSequence)
        return page
    }

    func requestedCursors() -> [UInt64] { cursors }
}

private struct ForbiddenGroupEventTransport: V2ClientGroupEventTransport {
    func pullGroupEvents(roomID _: RoomID, afterRoomSequence _: UInt64, pageSize _: Int) throws -> V2ClientGroupEventPage {
        throw V2RealtimeTransportError.server(code: "FORBIDDEN", retryable: false, retryAfterSeconds: 0, currentRevision: nil)
    }
}

private actor BackgroundGroupEventStoreFake: V2LocalGroupEventStore {
    private var roomIDs: [RoomID]
    private var cursors: [RoomID: UInt64] = [:]

    init(roomIDs: [RoomID]) {
        self.roomIDs = roomIDs
    }

    func knownHybridGroupRoomIDs() -> [RoomID] { roomIDs }
    func isKnownHybridGroupRoom(roomID: RoomID) -> Bool { roomIDs.contains(roomID) }
    func deactivateHybridGroupRoom(roomID: RoomID) { roomIDs.removeAll { $0 == roomID } }
    func groupEventCursor(roomID: RoomID) -> UInt64 { cursors[roomID, default: 0] }
    func applyGroupEventPage(_ page: V2ClientGroupEventPage) -> UInt64 {
        cursors[page.roomID] = page.nextRoomSequence
        return page.nextRoomSequence
    }
}

private actor BackgroundGroupEventTransportFake: V2ClientGroupEventTransport {
    private var requestedRooms: [RoomID] = []

    func pullGroupEvents(roomID: RoomID, afterRoomSequence: UInt64, pageSize _: Int) -> V2ClientGroupEventPage {
        requestedRooms.append(roomID)
        return .init(roomID: roomID, events: [], nextRoomSequence: afterRoomSequence, hasMore: true)
    }

    func requestedRoomIDs() -> [RoomID] { requestedRooms }
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

private actor LostIncrementalACKTransport: V2ClientSyncTransport {
    enum Failure: Error { case responseLost }

    private let first: V2ClientSyncBatch
    private let retry: V2ClientSyncBatch
    private var pulls = 0
    private var tokens: [V2SyncToken?] = []
    private var receipts: [V2SyncReceipt] = []

    init(first: V2ClientSyncBatch, retry: V2ClientSyncBatch) {
        self.first = first
        self.retry = retry
    }

    func pull(syncToken: V2SyncToken?, maxRecords _: Int) -> V2ClientPullResult {
        tokens.append(syncToken)
        pulls += 1
        return .ready(pulls == 1 ? first : retry)
    }

    func acknowledge(
        generation _: UInt64,
        highestContiguousSequence _: UInt64,
        receipt: V2SyncReceipt
    ) throws {
        receipts.append(receipt)
        if receipts.count == 1 { throw Failure.responseLost }
    }

    func fetchSnapshotManifest(
        for _: V2ClientResetRequired
    ) throws -> V2ClientSnapshotManifest { throw V2ClientSyncError.snapshotMismatch }

    func fetchSnapshotPage(
        for _: V2ClientSnapshotManifest,
        index _: Int
    ) throws -> V2ClientSnapshotPage { throw V2ClientSyncError.snapshotMismatch }

    func acknowledgeSnapshot(_: V2ClientSnapshotManifest) {}
    func requestedTokens() -> [V2SyncToken?] { tokens }
    func acknowledgementReceipts() -> [V2SyncReceipt] { receipts }
}

private actor ExpiredSyncTokenTransport: V2ClientSyncTransport {
    private let batch: V2ClientSyncBatch
    private var tokens: [V2SyncToken?] = []

    init(batch: V2ClientSyncBatch) { self.batch = batch }

    func pull(syncToken: V2SyncToken?, maxRecords _: Int) throws -> V2ClientPullResult {
        tokens.append(syncToken)
        if syncToken != nil {
            throw V2RealtimeTransportError.server(
                code: "SYNC_TOKEN_INVALID",
                retryable: false,
                retryAfterSeconds: 0,
                currentRevision: nil
            )
        }
        return .ready(batch)
    }

    func acknowledge(
        generation _: UInt64,
        highestContiguousSequence _: UInt64,
        receipt _: V2SyncReceipt
    ) {}

    func fetchSnapshotManifest(
        for _: V2ClientResetRequired
    ) throws -> V2ClientSnapshotManifest { throw V2ClientSyncError.snapshotMismatch }

    func fetchSnapshotPage(
        for _: V2ClientSnapshotManifest,
        index _: Int
    ) throws -> V2ClientSnapshotPage { throw V2ClientSyncError.snapshotMismatch }

    func acknowledgeSnapshot(_: V2ClientSnapshotManifest) {}
    func requestedTokens() -> [V2SyncToken?] { tokens }
}

private enum SnapshotInterruption: Error { case once }

private actor ResumableSnapshotTransport: V2ClientSyncTransport {
    private let reset: V2ClientResetRequired
    private let fixture: SnapshotFixture
    private var didInterrupt = false
    private var requestedPages: [Int] = []
    private var acknowledgements = 0

    init(reset: V2ClientResetRequired) throws {
        self.reset = reset
        let target1 = "00000000-0000-0000-0000-000000000211"
        let target2 = "00000000-0000-0000-0000-000000000212"
        fixture = try makeSnapshotFixture(reset: reset, pages: [
            .init(items: [
                .init(
                    key: .init(projectionKind: "relationship", entityKey: target1),
                    sourceEventID: .init("00000000-0000-0000-0000-000000000213"),
                    sequence: 2,
                    payload: socialPayload([
                        "target_user_id": target1,
                        "state": "accepted",
                        "updated_at_ms": 1_750_000_000_000,
                    ])
                )
            ]),
            .init(items: [
                .init(
                    key: .init(projectionKind: "user_block", entityKey: target2),
                    sourceEventID: .init("00000000-0000-0000-0000-000000000214"),
                    sequence: 3,
                    payload: socialPayload([
                        "target_user_id": target2,
                        "is_blocked": true,
                        "updated_at_ms": 1_750_000_001_000,
                    ])
                )
            ]),
        ])
    }

    func pull(syncToken _: V2SyncToken?, maxRecords _: Int) -> V2ClientPullResult { .resetRequired(reset) }
    func acknowledge(generation _: UInt64, highestContiguousSequence _: UInt64, receipt _: V2SyncReceipt) {}
    func fetchSnapshotManifest(for _: V2ClientResetRequired) -> V2ClientSnapshotManifest { fixture.manifest }
    func fetchSnapshotPage(for _: V2ClientSnapshotManifest, index: Int) throws -> V2ClientSnapshotPage {
        requestedPages.append(index)
        if index == 1, !didInterrupt {
            didInterrupt = true
            throw SnapshotInterruption.once
        }
        return fixture.pages[index]
    }
    func acknowledgeSnapshot(_: V2ClientSnapshotManifest) { acknowledgements += 1 }
    func pageRequests() -> [Int] { requestedPages }
    func snapshotAcknowledgements() -> Int { acknowledgements }
}

private actor SnapshotCrashWindowTransport: V2ClientSyncTransport {
    private let reset: V2ClientResetRequired
    private let fixture: SnapshotFixture
    private let acknowledgementError: V2RealtimeTransportError?
    private var pulls = 0
    private var manifestRequests = 0
    private var snapshotAcknowledgements = 0

    init(
        reset: V2ClientResetRequired,
        acknowledgementError: V2RealtimeTransportError? = nil
    ) throws {
        self.reset = reset
        self.acknowledgementError = acknowledgementError
        fixture = try makeSnapshotFixture(reset: reset, pages: [])
    }

    func pull(syncToken _: V2SyncToken?, maxRecords _: Int) -> V2ClientPullResult {
        pulls += 1
        return .resetRequired(reset)
    }

    func acknowledge(
        generation _: UInt64,
        highestContiguousSequence _: UInt64,
        receipt _: V2SyncReceipt
    ) {}

    func fetchSnapshotManifest(for _: V2ClientResetRequired) -> V2ClientSnapshotManifest {
        manifestRequests += 1
        return fixture.manifest
    }

    func fetchSnapshotPage(
        for _: V2ClientSnapshotManifest,
        index _: Int
    ) throws -> V2ClientSnapshotPage {
        throw V2ClientSyncError.snapshotMismatch
    }

    func acknowledgeSnapshot(_: V2ClientSnapshotManifest) throws {
        snapshotAcknowledgements += 1
        if let acknowledgementError { throw acknowledgementError }
    }

    func pullCount() -> Int { pulls }
    func manifestRequestCount() -> Int { manifestRequests }
    func snapshotAcknowledgementCount() -> Int { snapshotAcknowledgements }
}

private struct ProjectionSnapshotTransport: V2ClientSyncTransport {
    let reset: V2ClientResetRequired
    let fixture: SnapshotFixture

    init(reset: V2ClientResetRequired, pages: [V2SnapshotProjectionV3Page]) throws {
        self.reset = reset
        fixture = try makeSnapshotFixture(reset: reset, pages: pages)
    }

    func pull(syncToken _: V2SyncToken?, maxRecords _: Int) -> V2ClientPullResult { .resetRequired(reset) }
    func acknowledge(generation _: UInt64, highestContiguousSequence _: UInt64, receipt _: V2SyncReceipt) {}
    func fetchSnapshotManifest(for _: V2ClientResetRequired) -> V2ClientSnapshotManifest { fixture.manifest }
    func fetchSnapshotPage(for _: V2ClientSnapshotManifest, index: Int) -> V2ClientSnapshotPage { fixture.pages[index] }
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

private struct SnapshotFixture {
    let manifest: V2ClientSnapshotManifest
    let pages: [V2ClientSnapshotPage]
}

private func makeSnapshotFixture(
    reset: V2ClientResetRequired,
    pages: [V2SnapshotProjectionV3Page],
    capabilityProfile: String = "base"
) throws -> SnapshotFixture {
    var rolling = V2SnapshotV3Digest.initial(
        baseSequence: reset.baseSequence,
        capabilityProfile: capabilityProfile
    )
    var totalBytes: UInt64 = 0
    var totalItems: UInt64 = 0
    var encoded: [(payload: Data, digest: String, page: V2SnapshotProjectionV3Page)] = []
    for (index, page) in pages.enumerated() {
        let payload = try V2SnapshotProjectionV3Codec.encode(page)
        let digest = V2SnapshotV3Digest.page(payload)
        rolling = V2SnapshotV3Digest.next(
            previous: rolling,
            pageIndex: UInt32(index),
            pageDigest: digest,
            firstKey: page.firstKey,
            lastKey: page.lastKey,
            itemCount: UInt32(page.items.count)
        )
        totalBytes += UInt64(payload.count)
        totalItems += UInt64(page.items.count)
        encoded.append((payload, digest, page))
    }
    let manifest = try V2ClientSnapshotManifest(
        reset: reset,
        rootDigest: rolling,
        pageCount: pages.count,
        totalItems: totalItems,
        totalBytes: totalBytes,
        nextSyncToken: .init("snapshot-v3-token"),
        receipt: .init("snapshot-v3-receipt"),
        capabilityProfile: capabilityProfile
    )
    return .init(
        manifest: manifest,
        pages: encoded.enumerated().map { index, value in
            .init(
                index: index,
                digest: value.digest,
                firstKey: value.page.firstKey,
                lastKey: value.page.lastKey,
                itemCount: value.page.items.count,
                payload: value.payload
            )
        }
    )
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

private func snapshotMessagePayload(
    messageID: String,
    roomID: String,
    text: String,
    revision: UInt64,
    isWithdrawn: Bool
) -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "event_type": "message.accepted",
        "message_id": messageID,
        "room_id": roomID,
        "room_sequence": 7,
        "timeline_sequence": 7,
        "message_revision": revision,
        "sender_user_id": "00000000-0000-0000-0000-000000000234",
        "text": text,
        "media_ids": [],
        "media_presentations": [],
        "mention_user_ids": [],
        "mentions_everyone": false,
        "entities": [],
        "server_created_at_ms": 1_750_000_000_000,
        "is_withdrawn": isWithdrawn,
    ], options: [.sortedKeys])
}

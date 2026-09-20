import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("V2 direct room identity cache")
struct V2DirectRoomIdentityCacheTests {
    @Test func emptyDirectProfileKeepsCreationActivityAcrossUpdates() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: FileManager.default.temporaryDirectory
            .appending(path: "direct-creation-\(UUID()).sqlite"), installationBinding: .init(value: UUID()))
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
        func record(_ sequence: UInt64, created: Int64 = 1_750_000_000_000) throws -> V2ClientSyncRecord {
            try .init(sequence: sequence, sourceEventID: .init(uuid: UUID()), projectionKind: "direct_room_profile",
                payload: JSONSerialization.data(withJSONObject: [
                    "room_id": room.rawValue, "target_user_id": user.rawValue,
                    "public_handle": "creation_user", "display_name": "name-\(sequence)", "account_kind": "regular",
                    "revision": sequence, "room_created_at_ms": created,
                    "updated_at_ms": 1_750_000_000_000 + Int64(sequence) * 100_000,
                ]))
        }
        for sequence: UInt64 in [1, 2] {
            _ = try await store.apply(.init(generation: 1, records: [record(sequence)], nextSyncToken: .init("token-\(sequence)"),
                receipt: .init("receipt-\(sequence)"), hasMore: false, capabilityProfile: "base"))
            let page = try await store.conversationListPage(isArchived: false, before: nil, limit: 10)
            #expect(page.entries.first?.lastActivity == Date(timeIntervalSince1970: 1_750_000_000))
        }
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
            _ = try await store.apply(.init(generation: 1, records: [record(3, created: 1_750_000_000_001)],
                nextSyncToken: .init("bad"), receipt: .init("bad"), hasMore: false, capabilityProfile: "base"))
        }
    }

    @Test("late direct profiles converge without replacing a newer hydrated profile")
    func directProfileVersionsConverge() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-profile-order-\(UUID().uuidString).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        func record(_ sequence: UInt64, _ revision: UInt64, _ name: String) throws -> V2ClientSyncRecord {
            try .init(sequence: sequence, sourceEventID: .init(uuid: UUID()), projectionKind: "direct_room_profile",
                payload: JSONSerialization.data(withJSONObject: [
                    "room_id": room.rawValue, "target_user_id": user.rawValue,
                    "public_handle": "profile_user", "display_name": name, "account_kind": "regular",
                    "revision": revision, "room_created_at_ms":1750000000000,"updated_at_ms": 1750000000000,
                ]))
        }
        let hydrated = try V2ProfileView(userID: user,
            publicIdentity: .init(userID: user, handle: .init("profile_user"), displayName: "hydrated", accountKind: .regular),
            avatar: .init(mediaID: .init(uuid: UUID())), state: .active, revision: #require(V2ProfileRevision(rawValue: 10)),
            visibilityRevision: #require(V2ProfileRevision(rawValue: 10)))
        try await store.saveProfileView(hydrated)
        _ = try await store.apply(.init(generation: 1,
            records: [record(1, 4, "current"), record(2, 3, "old"), record(3, 4, "current")],
            nextSyncToken: .init("profile-order"), receipt: .init("profile-order"), hasMore: false, capabilityProfile: "base"))
        #expect(try await store.profileView(userID: user) == hydrated)
        #expect(try await store.knownRoomLogRoomIDs(after: nil, limit: 10) == [room])
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
            _ = try await reopened.apply(.init(generation: 1, records: [record(4, 4, "conflict")],
                nextSyncToken: .init("profile-conflict"), receipt: .init("profile-conflict"), hasMore: false, capabilityProfile: "base"))
        }
        #expect(try await reopened.profileView(userID: user) == hydrated)
        _ = try await reopened.apply(.init(generation: 1, records: [record(4, 10, "hydrated")],
            nextSyncToken: .init("same-profile-version"), receipt: .init("same-profile-version"), hasMore: false, capabilityProfile: "base"))
        #expect(try await reopened.profileView(userID: user) == hydrated)

    }

    @Test("an explicitly resolved direct identity survives a local-store restart and refreshes in place")
    func persistsResolvedIdentity() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-direct-identity-\(UUID().uuidString).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000d01")!)
        let roomID: RoomID = try .init("00000000-0000-0000-0000-000000000d02")
        let identity = try V2PublicIdentity(
            userID: .init("00000000-0000-0000-0000-000000000d03"),
            handle: .init("direct_user"),
            displayName: "初始名称",
            accountKind: .regular
        )
        let first = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        try await first.cacheDirectRoomIdentity(roomID: roomID, publicIdentity: identity, roomCreatedAt: Date(timeIntervalSince1970: 1_750_000_000), updatedAt: Date(timeIntervalSince1970: 1_750_000_000))

        let restarted = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        #expect(try await restarted.directRoomIdentities() == [.init(roomID: roomID, publicIdentity: identity, updatedAt: Date(timeIntervalSince1970: 1_750_000_000), roomCreatedAt: Date(timeIntervalSince1970: 1_750_000_000))])

        let refreshed = try V2PublicIdentity(userID: identity.userID, handle: identity.handle, displayName: "更新名称", accountKind: identity.accountKind)
        try await restarted.cacheDirectRoomIdentity(roomID: roomID, publicIdentity: refreshed, roomCreatedAt: Date(timeIntervalSince1970: 1_750_000_000), updatedAt: Date(timeIntervalSince1970: 1_750_000_100))
        #expect(try await restarted.directRoomIdentities().first?.publicIdentity.displayName == "更新名称")
        let created = Date(timeIntervalSince1970: 1_750_000_000)
        #expect(try await restarted.conversationListPage(isArchived: false, before: nil, limit: 10).entries.first?.lastActivity == created)
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
            try await restarted.cacheDirectRoomIdentity(roomID: roomID, publicIdentity: refreshed,
                roomCreatedAt: created.addingTimeInterval(1))
        }
        #expect(try await restarted.directRoomIdentities().first?.roomCreatedAt == created)
        #expect(try await restarted.conversationListPage(isArchived: false, before: nil, limit: 10).entries.first?.lastActivity == created)

    }

    @Test("a direct room identity owns a durable room-event cursor and remembers a forbidden pull")
    func directIdentityEnrollsDurableRoomLog() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-direct-room-log-\(UUID().uuidString).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000d71")!)
        let roomID: RoomID = try .init("00000000-0000-0000-0000-000000000d72")
        let identity = try V2PublicIdentity(
            userID: .init("00000000-0000-0000-0000-000000000d73"),
            handle: .init("room_log_peer"), displayName: "私聊对方", accountKind: .regular
        )
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        try await store.cacheDirectRoomIdentity(roomID: roomID, publicIdentity: identity, roomCreatedAt: Date(timeIntervalSince1970: 1_750_000_000))

        #expect(try await store.knownRoomLogRoomIDs(after: nil, limit: 10) == [roomID])
        #expect(try await store.groupEventAccess(roomID: roomID) == .init(
            isAuthorized: true
        ))
        let payload = try JSONSerialization.data(withJSONObject: [
            "event_type": "message.accepted",
            "message_id": "00000000-0000-0000-0000-000000000d74",
            "room_id": roomID.rawValue,
            "room_sequence": 1,
            "message_revision": 1,
            "sender_user_id": identity.userID.rawValue,
            "text": "离线恢复的私聊",
            "mention_user_ids": [],
            "mentions_everyone": false,
            "server_created_at_ms": 1_750_000_000_000,
        ])
        let event = try V2ClientGroupEvent(
            sourceEventID: .init("00000000-0000-0000-0000-000000000d75"),
            roomSequence: 1, projectionKind: "message", payload: payload
        )
        let page = try V2ClientGroupEventPage(roomID: roomID, events: [event], nextRoomSequence: 1, hasMore: false)
        #expect(try await store.applyGroupEventPage(page) == 1)
        #expect(try await store.messages(in: roomID).map(\.text) == ["离线恢复的私聊"])
        #expect(try await store.groupEventCursor(roomID: roomID) == 1)

        try await store.markRoomEventUnauthorized(roomID: roomID)
        #expect(try await store.knownRoomLogRoomIDs(after: nil, limit: 10).isEmpty)
        #expect(try await store.groupEventAccess(roomID: roomID) == .init(
            isAuthorized: false
        ))
        let restarted = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        #expect(try await restarted.groupEventAccess(roomID: roomID) == .init(
            isAuthorized: false
        ))
        #expect(try await restarted.groupEventCursor(roomID: roomID) == 1)
    }

    @Test("authoritative direct profile sync replaces the local lookup cache and survives a reset")
    func appliesAuthoritativeProjectionAndSnapshot() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-direct-profile-\(UUID().uuidString).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000d11")!)
        let roomID: RoomID = try .init("00000000-0000-0000-0000-000000000d12")
        let userID: UserID = try .init("00000000-0000-0000-0000-000000000d13")
        let cached = try V2PublicIdentity(userID: userID, handle: .init("direct_user"), displayName: "旧名称", accountKind: .regular)
        let synced = try V2PublicIdentity(
            userID: userID,
            handle: .init("direct_user"),
            displayName: "同步名称",
            accountKind: .customerSupport
        )
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        try await store.cacheDirectRoomIdentity(roomID: roomID, publicIdentity: cached, roomCreatedAt: Date(timeIntervalSince1970: 1_750_000_000), updatedAt: Date(timeIntervalSince1970: 1_750_000_000))
        let sourceEventID: EventID = try .init("00000000-0000-0000-0000-000000000d14")
        let payload = Data("""
            {"room_id":"\(roomID.rawValue)","target_user_id":"\(userID.rawValue)","public_handle":"\(synced.handle.rawValue)","display_name":"\(synced.displayName)","account_kind":"customer_support","revision":2,"room_created_at_ms":1750000000000,"updated_at_ms":1750000001000}
            """.utf8)
        _ = try await store.apply(.init(
            generation: 1,
            records: [.init(sequence: 1, sourceEventID: sourceEventID, projectionKind: "direct_room_profile", payload: payload)],
            nextSyncToken: try .init("direct-profile-token"),
            receipt: .init("direct-profile-receipt"),
            hasMore: false,
            capabilityProfile: "base"
        ))
        #expect(try await store.directRoomIdentities() == [.init(roomID: roomID, publicIdentity: synced, updatedAt: Date(timeIntervalSince1970: 1_750_000_001), roomCreatedAt: Date(timeIntervalSince1970: 1_750_000_000))])
        #expect(try await store.profileView(userID: userID)?.publicIdentity == synced)

        let snapshotPayload = Data("""
            {"room_id":"\(roomID.rawValue)","target_user_id":"\(userID.rawValue)","public_handle":"\(synced.handle.rawValue)","display_name":"\(synced.displayName)","account_kind":"customer_support","revision":2,"room_created_at_ms":1750000000000,"updated_at_ms":1750000001000}
            """.utf8)
        let reset = try V2ClientResetRequired(
            snapshotID: .init("direct-profile-snapshot"),
            generation: 2,
            baseSequence: 1,
            expiresAt: .distantFuture
        )
        let page = try V2SnapshotProjectionV3Page(items: [
            .init(
                key: .init(projectionKind: "direct_room_profile", entityKey: roomID.rawValue),
                sourceEventID: sourceEventID,
                sequence: 1,
                payload: snapshotPayload
            )
        ])
        let payloadPage = try V2SnapshotProjectionV3Codec.encode(page)
        let pageDigest = V2SnapshotV3Digest.page(payloadPage)
        let initialDigest = V2SnapshotV3Digest.initial(baseSequence: 1, capabilityProfile: "base")
        let rootDigest = V2SnapshotV3Digest.next(
            previous: initialDigest,
            pageIndex: 0,
            pageDigest: pageDigest,
            firstKey: page.firstKey,
            lastKey: page.lastKey,
            itemCount: 1
        )
        let manifest = try V2ClientSnapshotManifest(
            reset: reset,
            rootDigest: rootDigest,
            pageCount: 1,
            totalItems: 1,
            totalBytes: UInt64(payloadPage.count),
            nextSyncToken: .init("direct-profile-next"),
            receipt: .init("direct-profile-snapshot-receipt"),
            capabilityProfile: "base"
        )
        try await store.beginReset(reset)
        try await store.beginSnapshotImport(manifest, initialDigest: initialDigest)
        try await store.applySnapshotPage(.init(
            index: 0,
            digest: pageDigest,
            firstKey: page.firstKey,
            lastKey: page.lastKey,
            itemCount: 1,
            payload: payloadPage
        ), for: manifest)
        try await store.prepareSnapshotActivation(manifest)
        try await store.activateAcknowledgedSnapshot(manifest)
        #expect(try await store.directRoomIdentities() == [
            .init(
                roomID: roomID,
                publicIdentity: synced,
                updatedAt: Date(timeIntervalSince1970: 1_750_000_001)
            , roomCreatedAt: Date(timeIntervalSince1970: 1_750_000_000))
        ])
        #expect(try await store.profileView(userID: userID)?.publicIdentity == synced)
    }

    @Test("an explicit lookup cache is device-owned and survives an unrelated snapshot reset")
    func explicitLookupCacheSurvivesSnapshotReset() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-direct-cache-reset-\(UUID().uuidString).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000d51")!)
        let roomID = try RoomID("00000000-0000-0000-0000-000000000d52")
        let identity = try V2PublicIdentity(
            userID: .init("00000000-0000-0000-0000-000000000d53"),
            handle: .init("cached_user"),
            displayName: "本地授权缓存",
            accountKind: .regular
        )
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        try await store.cacheDirectRoomIdentity(
            roomID: roomID,
            publicIdentity: identity,
            roomCreatedAt: Date(timeIntervalSince1970: 1_750_000_000), updatedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let roomEventPayload = try JSONSerialization.data(withJSONObject: [
            "event_type": "message.accepted",
            "message_id": "00000000-0000-0000-0000-000000000d54",
            "room_id": roomID.rawValue,
            "room_sequence": 1,
            "message_revision": 1,
            "sender_user_id": identity.userID.rawValue,
            "text": "重置时保留的私聊",
            "mention_user_ids": [],
            "mentions_everyone": false,
            "server_created_at_ms": 1_750_000_000_000,
        ])
        _ = try await store.applyGroupEventPage(.init(
            roomID: roomID,
            events: [try .init(
                sourceEventID: .init("00000000-0000-0000-0000-000000000d55"),
                roomSequence: 1, projectionKind: "message", payload: roomEventPayload
            )],
            nextRoomSequence: 1, hasMore: false
        ))

        let reset = try V2ClientResetRequired(
            snapshotID: .init("direct-cache-empty-snapshot"),
            generation: 2,
            baseSequence: 0,
            expiresAt: .distantFuture
        )
        let initialDigest = V2SnapshotV3Digest.initial(baseSequence: 0, capabilityProfile: "base")
        let manifest = try V2ClientSnapshotManifest(
            reset: reset,
            rootDigest: initialDigest,
            pageCount: 0,
            totalItems: 0,
            totalBytes: 0,
            nextSyncToken: .init("direct-cache-next"),
            receipt: .init("direct-cache-receipt"),
            capabilityProfile: "base"
        )
        try await store.beginReset(reset)
        try await store.beginSnapshotImport(manifest, initialDigest: initialDigest)
        try await store.prepareSnapshotActivation(manifest)
        try await store.activateAcknowledgedSnapshot(manifest)

        #expect(try await store.directRoomIdentities() == [
            .init(
                roomID: roomID,
                publicIdentity: identity,
                updatedAt: Date(timeIntervalSince1970: 1_750_000_000)
            , roomCreatedAt: Date(timeIntervalSince1970: 1_750_000_000))
        ])
        #expect(try await store.groupEventCursor(roomID: roomID) == 1)
        #expect(try await store.messages(in: roomID).map(\.text) == ["重置时保留的私聊"])
    }

    @Test("snapshot invalidation does not mutate the live identity cache before activation")
    func snapshotInvalidationWaitsForActivation() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-direct-cache-invalidation-\(UUID().uuidString).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000d61")!)
        let roomID = try RoomID("00000000-0000-0000-0000-000000000d62")
        let userID = try UserID("00000000-0000-0000-0000-000000000d63")
        let identity = try V2PublicIdentity(userID: userID, handle: .init("snapshot_disabled"), displayName: "停用前", accountKind: .regular)
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        try await store.cacheDirectRoomIdentity(roomID: roomID, publicIdentity: identity, roomCreatedAt: Date(timeIntervalSince1970: 1_750_000_000), updatedAt: Date(timeIntervalSince1970: 1_750_000_000))

        let reset = try V2ClientResetRequired(
            snapshotID: .init("direct-cache-invalidation-snapshot"),
            generation: 2,
            baseSequence: 1,
            expiresAt: .distantFuture
        )
        let sourceEventID = try EventID("00000000-0000-0000-0000-000000000d64")
        let payload = Data("{\"user_id\":\"\(userID.rawValue)\",\"minimum_profile_revision\":2,\"profile_state\":\"suspended\"}".utf8)
        let page = try V2SnapshotProjectionV3Page(items: [
            .init(
                key: .init(projectionKind: "profile_invalidation", entityKey: userID.rawValue),
                sourceEventID: sourceEventID,
                sequence: 1,
                payload: payload
            )
        ])
        let encodedPage = try V2SnapshotProjectionV3Codec.encode(page)
        let pageDigest = V2SnapshotV3Digest.page(encodedPage)
        let initialDigest = V2SnapshotV3Digest.initial(baseSequence: 1, capabilityProfile: "base")
        let rootDigest = V2SnapshotV3Digest.next(
            previous: initialDigest,
            pageIndex: 0,
            pageDigest: pageDigest,
            firstKey: page.firstKey,
            lastKey: page.lastKey,
            itemCount: 1
        )
        let manifest = try V2ClientSnapshotManifest(
            reset: reset,
            rootDigest: rootDigest,
            pageCount: 1,
            totalItems: 1,
            totalBytes: UInt64(encodedPage.count),
            nextSyncToken: .init("direct-cache-invalidation-next"),
            receipt: .init("direct-cache-invalidation-receipt"),
            capabilityProfile: "base"
        )

        try await store.beginReset(reset)
        try await store.beginSnapshotImport(manifest, initialDigest: initialDigest)
        try await store.applySnapshotPage(.init(
            index: 0,
            digest: pageDigest,
            firstKey: page.firstKey,
            lastKey: page.lastKey,
            itemCount: 1,
            payload: encodedPage
        ), for: manifest)
        #expect(try await store.directRoomIdentities().map(\.publicIdentity) == [identity])

        try await store.prepareSnapshotActivation(manifest)
        try await store.activateAcknowledgedSnapshot(manifest)
        #expect(try await store.directRoomIdentities().isEmpty)
    }

    @Test("profile invalidation is durable until an authorized hydration replaces it")
    func retainsInvalidationUntilHydrated() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-profile-invalidation-\(UUID().uuidString).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000d31")!)
        let userID: UserID = try .init("00000000-0000-0000-0000-000000000d32")
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let invalidation = Data("{\"user_id\":\"\(userID.rawValue)\",\"minimum_profile_revision\":3}".utf8)
        _ = try await store.apply(.init(
            generation: 1,
            records: [.init(sequence: 1, sourceEventID: try .init("00000000-0000-0000-0000-000000000d33"), projectionKind: "profile_invalidation", payload: invalidation)],
            nextSyncToken: try .init("profile-invalidation-token"),
            receipt: .init("profile-invalidation-receipt"),
            hasMore: false,
            capabilityProfile: "base"
        ))
        #expect(try await store.pendingProfileInvalidations(limit: 10) == [
            .init(userID: userID, minimumRevision: try #require(V2ProfileRevision(rawValue: 3)))
        ])

        let identity = try V2PublicIdentity(userID: userID, handle: .init("hydrated_user"), displayName: "重新读取", accountKind: .regular)
        try await store.saveProfileView(.init(
            userID: userID,
            publicIdentity: identity,
            avatar: nil,
            state: .active,
            revision: try #require(V2ProfileRevision(rawValue: 3)),
            visibilityRevision: try #require(V2ProfileRevision(rawValue: 1))
        ))
        #expect(try await store.pendingProfileInvalidations(limit: 10).isEmpty)
    }

    @Test("mixed-case UUID room IDs from direct profiles and messages share one local conversation")
    func joinsMixedCaseDirectRoomProjection() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-direct-mixed-case-\(UUID().uuidString).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000d21")!)
        let lowerRoomID = "f90a83a4-dec2-4bf5-80aa-4068a71afc9f"
        let upperRoomID = lowerRoomID.uppercased()
        let userID = "00000000-0000-0000-0000-000000000d22"
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let directProfile = Data("""
            {"room_id":"\(lowerRoomID)","target_user_id":"\(userID)","public_handle":"direct_user","display_name":"对方","account_kind":"regular","revision":1,"room_created_at_ms":1750000000000,"updated_at_ms":1750000000000}
            """.utf8)
        let acceptedMessage = Data("""
            {"event_type":"message.accepted","message_id":"00000000-0000-0000-0000-000000000d23","room_id":"\(upperRoomID)","room_sequence":1,"message_revision":1,"sender_user_id":"\(userID)","text":"离线重放","media_ids":[],"mention_user_ids":[],"mentions_everyone":false,"server_created_at_ms":1750000000000}
            """.utf8)
        _ = try await store.apply(.init(
            generation: 1,
            records: [
                .init(sequence: 1, sourceEventID: try .init("00000000-0000-0000-0000-000000000d24"), projectionKind: "direct_room_profile", payload: directProfile),
                .init(sequence: 2, sourceEventID: try .init("00000000-0000-0000-0000-000000000d25"), projectionKind: "message", payload: acceptedMessage),
            ],
            nextSyncToken: try .init("direct-mixed-case-token"),
            receipt: .init("direct-mixed-case-receipt"),
            hasMore: false,
            capabilityProfile: "base"
        ))

        let roomID = try RoomID(lowerRoomID)
        #expect(try await store.directRoomIdentities().map(\.roomID) == [roomID])
        #expect(try await store.messages(in: roomID).map(\.text) == ["离线重放"])
    }

    @Test("a suspended profile invalidation removes the compact direct identity atomically")
    func suspendedInvalidationRemovesCompactIdentity() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-profile-suspended-\(UUID().uuidString).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000d41")!)
        let roomID = try RoomID("00000000-0000-0000-0000-000000000d42")
        let userID = try UserID("00000000-0000-0000-0000-000000000d43")
        let identity = try V2PublicIdentity(userID: userID, handle: .init("disabled_user"), displayName: "停用前", accountKind: .regular)
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        try await store.cacheDirectRoomIdentity(roomID: roomID, publicIdentity: identity, roomCreatedAt: Date(timeIntervalSince1970: 1_750_000_000), updatedAt: Date(timeIntervalSince1970: 1_750_000_000))
        let invalidation = Data("{\"user_id\":\"\(userID.rawValue)\",\"minimum_profile_revision\":2,\"profile_state\":\"suspended\"}".utf8)

        _ = try await store.apply(.init(
            generation: 1,
            records: [.init(
                sequence: 1,
                sourceEventID: try .init("00000000-0000-0000-0000-000000000d44"),
                projectionKind: "profile_invalidation",
                payload: invalidation
            )],
            nextSyncToken: try .init("profile-suspended-token"),
            receipt: .init("profile-suspended-receipt"),
            hasMore: false,
            capabilityProfile: "base"
        ))

        #expect(try await store.directRoomIdentities().isEmpty)
        #expect(try await store.pendingProfileInvalidations(limit: 10) == [
            .init(userID: userID, minimumRevision: try #require(V2ProfileRevision(rawValue: 2)))
        ])
    }
}

import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("V2 direct room identity cache")
struct V2DirectRoomIdentityCacheTests {
    @Test("an explicitly resolved direct identity survives a local-store restart and refreshes in place")
    func persistsResolvedIdentity() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-direct-identity-\(UUID().uuidString).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000d01")!)
        let roomID: RoomID = try .init("00000000-0000-0000-0000-000000000d02")
        let identity = try V2PublicIdentity(
            userID: .init("00000000-0000-0000-0000-000000000d03"),
            handle: .init("direct_user"),
            displayName: "初始名称"
        )
        let first = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        try await first.cacheDirectRoomIdentity(roomID: roomID, publicIdentity: identity, updatedAt: Date(timeIntervalSince1970: 1_750_000_000))

        let restarted = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        #expect(try await restarted.directRoomIdentities() == [.init(roomID: roomID, publicIdentity: identity, updatedAt: Date(timeIntervalSince1970: 1_750_000_000))])

        let refreshed = try V2PublicIdentity(userID: identity.userID, handle: identity.handle, displayName: "更新名称")
        try await restarted.cacheDirectRoomIdentity(roomID: roomID, publicIdentity: refreshed, updatedAt: Date(timeIntervalSince1970: 1_750_000_100))
        #expect(try await restarted.directRoomIdentities().first?.publicIdentity.displayName == "更新名称")
    }

    @Test("authoritative direct profile sync replaces the local lookup cache and survives a reset")
    func appliesAuthoritativeProjectionAndSnapshot() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-direct-profile-\(UUID().uuidString).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000d11")!)
        let roomID: RoomID = try .init("00000000-0000-0000-0000-000000000d12")
        let userID: UserID = try .init("00000000-0000-0000-0000-000000000d13")
        let cached = try V2PublicIdentity(userID: userID, handle: .init("direct_user"), displayName: "旧名称")
        let synced = try V2PublicIdentity(
            userID: userID,
            handle: .init("direct_user"),
            displayName: "同步名称",
            accountKind: .customerSupport
        )
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        try await store.cacheDirectRoomIdentity(roomID: roomID, publicIdentity: cached, updatedAt: Date(timeIntervalSince1970: 1_750_000_000))
        let sourceEventID: EventID = try .init("00000000-0000-0000-0000-000000000d14")
        let payload = Data("""
            {"room_id":"\(roomID.rawValue)","target_user_id":"\(userID.rawValue)","public_handle":"\(synced.handle.rawValue)","display_name":"\(synced.displayName)","account_kind":"customer_support","revision":2,"updated_at_ms":1750000001000}
            """.utf8)
        _ = try await store.apply(.init(
            generation: 1,
            records: [.init(sequence: 1, sourceEventID: sourceEventID, projectionKind: "direct_room_profile", payload: payload)],
            nextSyncToken: try .init("direct-profile-token"),
            receipt: .init("direct-profile-receipt"),
            hasMore: false,
            capabilityProfile: "base"
        ))
        #expect(try await store.directRoomIdentities() == [.init(roomID: roomID, publicIdentity: synced, updatedAt: Date(timeIntervalSince1970: 1_750_000_001))])
        #expect(try await store.profileView(userID: userID)?.publicIdentity == synced)

        let snapshotProfile = try V2SnapshotDirectRoomProfileProjection(
            sourceEventID: try .init(roomID.rawValue), roomID: roomID,
            publicIdentity: synced, revision: 2, updatedAt: Date(timeIntervalSince1970: 1_750_000_001)
        )
        let payloadPage = try V2SnapshotProjectionCodec.encode(.init(messages: [], relationships: [], userBlocks: [], strangerMessagePreference: nil, moderationActions: [], roomControls: [], directRoomProfiles: [snapshotProfile]))
        let reset = try V2ClientResetRequired(snapshotID: .init("direct-profile-snapshot"), generation: 2, baseSequence: 1, manifestDigest: "direct-profile-manifest", expiresAt: .distantFuture)
        let pageDigest = "direct-profile-page"
        let manifest = try V2ClientSnapshotManifest(reset: reset, pageDigests: [pageDigest], nextSyncToken: .init("direct-profile-next"), receipt: .init("direct-profile-snapshot-receipt"), capabilityProfile: "base")
        try await store.beginReset(reset)
        try await store.beginSnapshotStaging(manifest)
        try await store.stageSnapshotPage(.init(index: 0, digest: pageDigest, payload: payloadPage), for: manifest)
        try await store.commitStagedSnapshot(manifest)
        #expect(try await store.directRoomIdentities() == [.init(roomID: roomID, publicIdentity: synced, updatedAt: Date(timeIntervalSince1970: 1_750_000_001))])
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

        let identity = try V2PublicIdentity(userID: userID, handle: .init("hydrated_user"), displayName: "重新读取")
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
            {"room_id":"\(lowerRoomID)","target_user_id":"\(userID)","public_handle":"direct_user","display_name":"对方","revision":1,"updated_at_ms":1750000000000}
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
}

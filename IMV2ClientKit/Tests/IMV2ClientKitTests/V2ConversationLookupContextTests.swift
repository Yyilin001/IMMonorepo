import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Conversation lookup routing facts")
struct V2ConversationLookupContextTests {
    @Test("bounded batched context reads survive restart without returning cached private labels")
    func batchedLookupContexts() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "lookup-context-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "store.sqlite"), binding = V2LocalInstallationBinding(value: UUID())
        let cachedRoom = RoomID(uuid: UUID()), syncedRoom = RoomID(uuid: UUID()), group = RoomID(uuid: UUID()), missing = RoomID(uuid: UUID())
        let peer = UserID(uuid: UUID())
        var store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        do {
            try await store.cacheDirectRoomIdentity(roomID: cachedRoom,
                publicIdentity: .init(userID: peer, handle: .init("cached_peer"), displayName: "Private cached text", accountKind: .regular),
                roomCreatedAt: .init(timeIntervalSince1970: 1_750_000_000))
            let directRecord = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init(uuid: UUID()), projectionKind: "direct_room_profile",
                payload: JSONSerialization.data(withJSONObject: ["room_id": syncedRoom.rawValue, "target_user_id": peer.rawValue,
                    "public_handle": "synced_peer", "display_name": "Private synced text", "account_kind": "regular", "revision": 1,
                    "room_created_at_ms": 1_750_000_000_000, "updated_at_ms": 1_750_000_000_000]))
            let groupRecord = try V2ClientSyncRecord(sequence: 2, sourceEventID: .init(uuid: UUID()), projectionKind: "room",
                payload: JSONSerialization.data(withJSONObject: ["event_type": "room.created", "room_id": group.rawValue,
                    "title": "Group title", "owner_user_id": peer.rawValue, "membership_revision": 1,
                    "capacity_class": "standard", "created_at_ms": 1_750_000_000_000]))
            _ = try await store.apply(.init(generation: 1, records: [directRecord, groupRecord], nextSyncToken: .init("lookup"),
                receipt: .init("lookup"), hasMore: false, capabilityProfile: "base"))
            let expected: [RoomID: V2ClientConversationLookupContext] = [
                cachedRoom: .direct(peerUserID: peer), syncedRoom: .direct(peerUserID: peer), group: .group(title: "Group title")]
            #expect(try await store.conversationLookupContexts(for: [group, cachedRoom, syncedRoom, missing, cachedRoom]) == expected)
            #expect(try await store.conversationLookupContexts(for: []).isEmpty)
            await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
                _ = try await store.conversationLookupContexts(for: Array(repeating: missing, count: 101))
            }
            try await store.close()
            store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
            #expect(try await store.conversationLookupContexts(for: [cachedRoom, syncedRoom, group]) == expected)
            try await store.close()
        } catch { try? await store.close(); throw error }
    }
}

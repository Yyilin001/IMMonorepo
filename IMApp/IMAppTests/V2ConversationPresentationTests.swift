import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
@Suite("Conversation selector presentation boundaries")
struct V2ConversationPresentationTests {
    @Test("favorites, search routing and forward targets use identity keys rather than cached private titles")
    func productionProjectionLabels() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "selector-labels-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let actor = UserID(uuid: UUID()), peer = UserID(uuid: UUID()), direct = RoomID(uuid: UUID()), group = RoomID(uuid: UUID())
        let local = try GRDBV2LocalSyncStore(databaseURL: root.appending(path: "store.sqlite"), installationBinding: .init(value: UUID()))
        do {
            let message = MessageID(uuid: UUID())
            let payloads: [(String, [String: Any])] = [
                ("direct_room_profile", ["room_id": direct.rawValue, "target_user_id": peer.rawValue,
                    "public_handle": "private_peer", "display_name": "Cached name must not display", "account_kind": "regular",
                    "revision": 1, "room_created_at_ms": 1_750_000_000_000, "updated_at_ms": 1_750_000_000_000]),
                ("room", ["event_type": "room.created", "room_id": group.rawValue, "title": "Group",
                    "owner_user_id": actor.rawValue, "membership_revision": 1, "capacity_class": "standard", "created_at_ms": 1_750_000_000_000]),
                ("message", ["event_type": "message.accepted", "room_id": direct.rawValue, "message_id": message.rawValue,
                    "sender_user_id": peer.rawValue, "room_sequence": 1, "timeline_sequence": 1, "message_revision": 1,
                    "text": "Favorite message", "server_created_at_ms": 1_750_000_000_000]),
                ("message_favorite", ["room_id": direct.rawValue, "message_id": message.rawValue,
                    "is_favorited": true, "updated_at_ms": 1_750_000_000_000])
            ]
            let records = try payloads.enumerated().map { index, entry in
                try V2ClientSyncRecord(sequence: UInt64(index + 1), sourceEventID: .init(uuid: UUID()),
                    projectionKind: entry.0, payload: JSONSerialization.data(withJSONObject: entry.1))
            }
            _ = try await local.apply(.init(generation: 1, records: records, nextSyncToken: .init("selectors"),
                receipt: .init("selectors"), hasMore: false, capabilityProfile: "base"))
            let source = V2GRDBConversationDataSource(localStore: local, requestLatestVisible: { _ in })
            let key = V2ProfileViewLookupKey(userID: peer, context: .directConversation)
            let favorites = try await source.favoriteMessages(for: actor.rawValue, before: nil, limit: 50)
            #expect(favorites.items.count == 1 && favorites.items.first?.label == .profile(key))
            #expect(try await source.searchConversationContext(roomID: direct) == .direct(peerUserID: peer))
            let store = V2ConversationListStore(environment: .init(userID: actor.rawValue, projections: .init(dataSource: source)))
            await store.refresh()
            #expect(store.detailStore(for: group.rawValue).forwardTargets == [.init(roomID: direct.rawValue, label: .profile(key))])
            #expect(store.detailStore(for: direct.rawValue).forwardTargets == [.init(roomID: group.rawValue, label: .group("Group"))])
            let unknown = V2ConversationListItem(id: "unknown", title: "Must not escape", preview: "", lastActivity: .now,
                isOutgoing: false, kind: .unknown, presentationKey: key)
            #expect(V2ConversationLabel(item: unknown) == .unavailable)
            let wrong = V2ConversationListItem(id: direct.rawValue, title: "Must not escape", preview: "", lastActivity: .now,
                isOutgoing: false, kind: .direct(accountKind: .regular), presentationKey: .init(userID: peer, context: .room(group)))
            #expect(V2ConversationLabel(item: wrong) == .unavailable)
            try await local.close()
        } catch { try? await local.close(); throw error }
    }
}

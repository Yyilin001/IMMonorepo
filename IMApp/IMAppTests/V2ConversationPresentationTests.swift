import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing
import SwiftUI
@testable import IMApp

@MainActor
@Suite("Conversation selector presentation boundaries")
struct V2ConversationPresentationTests {
    @Test("terminal opening receipts are history; unresolved work is one row per peer")
    func privateChatRequestRows() throws {
        let peer = UserID(uuid: UUID())
        let history = try (1...4).map { try directRequest(peer: peer, sequence: Int64($0), finished: true) }
        let older = try directRequest(peer: peer, sequence: 5)
        let latest = try directRequest(peer: peer, sequence: 6)
        #expect(V2ConversationListStore.pendingDirectRequests(history, conversations: []).isEmpty)
        #expect(V2ConversationListStore.pendingDirectRequests(history + [older, latest], conversations: []).map(\.work.id) == [latest.work.id])
        let conversation = V2ConversationListItem(id: RoomID(uuid: UUID()).rawValue, title: "", preview: "", lastActivity: .now,
            isOutgoing: false, kind: .direct(accountKind: .regular), presentationKey: .init(userID: peer, context: .directConversation))
        #expect(V2ConversationListStore.pendingDirectRequests([latest], conversations: [conversation]).isEmpty)
    }

    @Test("repeated completed requests recover one authorized room instead of creating receipt rows")
    func completedRequestsDiscoverOneRoom() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "receipt-list-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try GRDBV2LocalSyncStore(databaseURL: root.appending(path: "store.sqlite"), installationBinding: .init(value: UUID()))
        let requests = DiscoveryRequests()
        let source = V2GRDBConversationDataSource(localStore: local, requestLatestVisible: { await requests.record($0) })
        let store = V2ConversationListStore(environment: .init(userID: UserID(uuid: UUID()).rawValue, projections: .init(dataSource: source)))
        let peer = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let history = try (1...4).map { try directRequest(peer: peer, sequence: Int64($0), finished: true, room: room) }
        await store.updateDirectConversationRequests(history)
        await store.updateDirectConversationRequests(history)
        #expect(await requests.rooms == [room])
        #expect(store.pendingDirectConversationRequests.isEmpty)
        // A historical receipt alone must not restore room access or a list row.
        #expect(store.items.isEmpty)
        try await local.close()
    }

    private func directRequest(peer: UserID, sequence: Int64, finished: Bool = false, room: RoomID = .init(uuid: UUID())) throws -> V2DirectRoomPending {
        let command = try V2DirectRoomOperationCommand(actorUserID: .init(uuid: UUID()), operationID: .init(uuid: UUID()),
            targetUserID: peer, firstSubmissionDeadlineMilliseconds: 1_900_000_000_000)
        let identity = try command.identity, fingerprint = try command.fingerprint
        let work = V2OperationWork(id: UUID(), intentID: UUID(), identity: identity, fingerprint: fingerprint,
            orderingKey: "test", localSequence: sequence, execution: finished ? .committed : .prepared,
            scheduling: finished ? .finished : .waitingForNetwork, submissionStarted: finished,
            attemptCount: 0, submissionRoundAttempts: 0, reconciliationRoundAttempts: 0,
            submissionRoundDeadline: nil, reconciliationRoundDeadline: nil, nextAction: .submit,
            nextActionAt: .now, admissionDeadline: nil, lastErrorCode: nil, revision: 1)
        let receipt = finished ? try V2DirectRoomOperationReceipt(identity: identity, fingerprint: fingerprint,
            outcome: .opened(roomID: room, createdAtMilliseconds: 1_750_000_000_000), resolvedAtMilliseconds: 1_750_000_000_001) : nil
        return .init(work: work, command: command, receipt: receipt)
    }

    @Test("opening chat replaces a pushed contact route without a mounted tab observer")
    func contactToChatNavigation() throws {
        let navigation = V2RootNavigationStore()
        navigation.selectedTab = .contacts
        navigation.path.append(V2ContactsRoute.requests)
        navigation.path.append(V2ContactsRoute.contact(UserID(uuid: UUID()).rawValue))
        let room = RoomID(uuid: UUID()).rawValue
        navigation.showConversation(roomID: room)
        var expected = NavigationPath()
        expected.append(V2ConversationRoute(roomID: room))
        #expect(navigation.selectedTab == .conversations)
        #expect(navigation.path == expected)
        navigation.path.removeLast()
        #expect(navigation.path.isEmpty)
    }

    @Test("opening another chat replaces the previous chat and preserves a message target")
    func replaceConversationDestination() {
        let navigation = V2RootNavigationStore()
        navigation.showConversation(roomID: RoomID(uuid: UUID()).rawValue)
        let room = RoomID(uuid: UUID()).rawValue
        navigation.showConversation(roomID: room, messageID: "target-message")
        var expected = NavigationPath()
        expected.append(V2ConversationRoute(roomID: room, messageID: "target-message"))
        #expect(navigation.path == expected)
    }

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
                    "is_favorited": true, "updated_at_ms": 1_750_000_000_000, "revision": 1])
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

private actor DiscoveryRequests {
    private(set) var rooms: [RoomID] = []
    func record(_ values: [RoomID]) { rooms.append(contentsOf: values) }
}

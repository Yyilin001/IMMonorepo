import Foundation
import IMV2Core
import Testing

@Suite("Authorized room nickname contracts")
struct ResourceGroupNicknameTests {
    @Test("nickname page cursors advance over denied entries without carrying naked nickname records")
    func pageContract() throws {
        let (_, lease, room) = try fixture()
        let users = (0..<3).map { _ in UserID(uuid: UUID()) }.sorted { $0.rawValue < $1.rawValue }
        let entries: [V2ProfilePresentationBatchEntry] = users.map { .unavailable(.init(userID: $0, context: .room(room))) }
        let page = try V2GroupNicknamePresentationPageResponse(roomID: room,
            batch: .init(serverNowUnixMilliseconds: lease.observedAtUnixMilliseconds, results: entries), nextCursor: users.last)
        #expect(try JSONDecoder().decode(V2GroupNicknamePresentationPageResponse.self, from: JSONEncoder().encode(page)) == page)
        for (wrongRoom, rows, cursor) in [
            (RoomID(uuid: UUID()), entries, users.last),
            (room, Array(entries.reversed()), users.last),
            (room, entries, users.first),
            (room, [], users.last)
        ] {
            #expect(throws: V2ResourceValidationError.invalidPresentationLease) {
                _ = try V2GroupNicknamePresentationPageResponse(roomID: wrongRoom,
                    batch: .init(serverNowUnixMilliseconds: 1, results: rows), nextCursor: cursor)
            }
        }
        let oldShape = Data("{\"nicknames\":[],\"next_cursor\":null}".utf8)
        #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(V2GroupNicknamePresentationPageResponse.self, from: oldShape) }
    }

    @Test("a nickname and its cleared revision round trip under the exact room lease", arguments: [false, true])
    func roundTrip(cleared: Bool) throws {
        let (view, lease, room) = try fixture()
        let member = try V2GroupMemberPresentation(roomID: room, userID: view.userID,
            groupNickname: cleared ? nil : "Room name", revision: #require(.init(rawValue: 7)))
        let value = try V2AuthorizedProfilePresentation(view: view, lease: lease, groupMember: member)
        #expect(try JSONDecoder().decode(V2AuthorizedProfilePresentation.self, from: JSONEncoder().encode(value)) == value)
        #expect(value.groupMember?.revision.rawValue == 7)
    }

    @Test("another room, another subject, direct context and hidden profile cannot carry a group nickname")
    func binding() throws {
        let (view, lease, room) = try fixture()
        let revision = try #require(V2ProfileRevision(rawValue: 1))
        for member in [
            try V2GroupMemberPresentation(roomID: .init(uuid: UUID()), userID: view.userID, groupNickname: "Name", revision: revision),
            try V2GroupMemberPresentation(roomID: room, userID: .init(uuid: UUID()), groupNickname: "Name", revision: revision)
        ] {
            #expect(throws: V2ResourceValidationError.invalidPresentationLease) {
                _ = try V2AuthorizedProfilePresentation(view: view, lease: lease, groupMember: member)
            }
        }
        let member = try V2GroupMemberPresentation(roomID: room, userID: view.userID, groupNickname: "Name", revision: revision)
        let direct = try V2PresentationAccessLease(actorUserID: lease.actorUserID, deviceID: lease.deviceID,
            key: .init(userID: view.userID, context: .directConversation), profileRevision: revision, visibilityRevision: revision,
            contextRevision: 1, observedAt: lease.observedAt, validUntil: lease.validUntil)
        #expect(throws: V2ResourceValidationError.invalidPresentationLease) {
            _ = try V2AuthorizedProfilePresentation(view: view, lease: direct, groupMember: member)
        }
        let hidden = try V2ProfileView(userID: view.userID, publicIdentity: nil, avatar: nil, state: .hidden,
            revision: revision, visibilityRevision: revision)
        #expect(throws: V2ResourceValidationError.invalidPresentationLease) {
            _ = try V2AuthorizedProfilePresentation(view: hidden, lease: lease, groupMember: member)
        }
    }

    @Test("decoding cannot bypass nickname normalization or its size budget", arguments: ["  Name  ", "", String(repeating: "x", count: 81)])
    func malformedNickname(text: String) throws {
        let (view, lease, room) = try fixture()
        let value = try V2AuthorizedProfilePresentation(view: view, lease: lease,
            groupMember: .init(roomID: room, userID: view.userID, groupNickname: "Name", revision: #require(.init(rawValue: 1))))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        var member = try #require(object["groupMember"] as? [String: Any])
        member["groupNickname"] = text; object["groupMember"] = member
        let encoded = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(V2AuthorizedProfilePresentation.self, from: encoded) }
    }

    private func fixture() throws -> (V2ProfileView, V2PresentationAccessLease, RoomID) {
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID()), now = Date()
        let revision = try #require(V2ProfileRevision(rawValue: 1))
        let view = try V2ProfileView(userID: user,
            publicIdentity: .init(userID: user, handle: .init("nickname"), displayName: "Public", accountKind: .regular),
            avatar: nil, state: .active, revision: revision, visibilityRevision: revision)
        let lease = try V2PresentationAccessLease(actorUserID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()),
            key: .init(userID: user, context: .room(room)), profileRevision: revision, visibilityRevision: revision,
            contextRevision: 1, observedAt: now, validUntil: now.addingTimeInterval(120))
        return (view, lease, room)
    }
}

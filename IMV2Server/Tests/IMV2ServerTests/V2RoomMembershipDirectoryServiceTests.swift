import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 room membership directory")
struct V2RoomMembershipDirectoryServiceTests {
    @Test("forwards a bounded request without allowing UI to construct an unbounded page")
    func forwardsBoundedRequest() async throws {
        let store = DirectoryStoreSpy()
        let service = V2RoomMembershipDirectoryService(store: store)
        let roomID = try RoomID("00000000-0000-0000-0000-000000000801")
        let actor = try UserID("00000000-0000-0000-0000-000000000802")
        let page = try await service.list(.init(roomID: roomID, actorUserID: actor, cursor: nil, pageSize: 2))

        #expect(page.roomID == roomID)
        #expect(page.membershipRevision == 4)
        #expect(page.actorRole == .owner)
        #expect(page.entries.map(\.role) == [.owner, .member])
        #expect(page.entries.map(\.publicIdentity.displayName) == ["群主", "成员"])
        #expect(page.nextCursor == "00000000-0000-0000-0000-000000000804")
        #expect(await store.request()?.pageSize == 2)
    }

    @Test("returned membership revisions fit persistence", arguments: [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func returnedRevisionBounds(revision: UInt64) async throws {
        let request = try V2RoomMembershipDirectoryRequest(roomID: .init("room"), actorUserID: .init("user"), cursor: nil, pageSize: 1)
        let service = V2RoomMembershipDirectoryService(store: DirectoryRevisionStore(revision: revision))
        if revision > UInt64(Int64.max) {
            await #expect(throws: V2RoomMembershipDirectoryError.corruptPersistenceState) { try await service.list(request) }
        } else {
            #expect(try await service.list(request).membershipRevision == revision)
        }
    }

    @Test("rejects zero, oversized, and blank pagination inputs")
    func rejectsInvalidRequest() throws {
        let roomID = try RoomID("00000000-0000-0000-0000-000000000801")
        let actor = try UserID("00000000-0000-0000-0000-000000000802")
        #expect(throws: V2RoomMembershipDirectoryError.invalidRequest) {
            _ = try V2RoomMembershipDirectoryRequest(roomID: roomID, actorUserID: actor, cursor: nil, pageSize: 0)
        }
        #expect(throws: V2RoomMembershipDirectoryError.invalidRequest) {
            _ = try V2RoomMembershipDirectoryRequest(roomID: roomID, actorUserID: actor, cursor: nil, pageSize: 101)
        }
        #expect(throws: V2RoomMembershipDirectoryError.invalidRequest) {
            _ = try V2RoomMembershipDirectoryRequest(roomID: roomID, actorUserID: actor, cursor: "  ", pageSize: 10)
        }
    }
}

private actor DirectoryStoreSpy: V2RoomMembershipDirectoryStore {
    private var captured: V2RoomMembershipDirectoryRequest?

    func list(_ request: V2RoomMembershipDirectoryRequest) throws -> V2RoomMembershipDirectoryPage {
        captured = request
        let ownerID = try! UserID("00000000-0000-0000-0000-000000000802")
        let memberID = try! UserID("00000000-0000-0000-0000-000000000804")
        return .init(
            roomID: request.roomID,
            membershipRevision: 4,
            actorRole: .owner,
            entries: [
                .init(
                    userID: ownerID,
                    role: .owner,
                    publicIdentity: try! .init(userID: ownerID, handle: .init("owner_1"), displayName: "群主", accountKind: .regular)
                ),
                .init(
                    userID: memberID,
                    role: .member,
                    publicIdentity: try! .init(userID: memberID, handle: .init("member_1"), displayName: "成员", accountKind: .regular)
                ),
            ],
            nextCursor: "00000000-0000-0000-0000-000000000804"
        )
    }

    func request() -> V2RoomMembershipDirectoryRequest? { captured }
}

private struct DirectoryRevisionStore: V2RoomMembershipDirectoryStore {
    let revision: UInt64
    func list(_ request: V2RoomMembershipDirectoryRequest) async throws -> V2RoomMembershipDirectoryPage {
        .init(roomID: request.roomID, membershipRevision: revision, actorRole: .owner, entries: [], nextCursor: nil)
    }
}

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
        #expect(page.nextCursor == "00000000-0000-0000-0000-000000000804")
        #expect(await store.request()?.pageSize == 2)
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
        return .init(
            roomID: request.roomID,
            membershipRevision: 4,
            actorRole: .owner,
            entries: [
                .init(userID: try! .init("00000000-0000-0000-0000-000000000802"), role: .owner),
                .init(userID: try! .init("00000000-0000-0000-0000-000000000804"), role: .member),
            ],
            nextCursor: "00000000-0000-0000-0000-000000000804"
        )
    }

    func request() -> V2RoomMembershipDirectoryRequest? { captured }
}

import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 profile view service")
struct V2ProfileViewServiceTests {
    @Test("rejects empty, oversized, and duplicate lookup keys before storage")
    func validatesReadRequest() throws {
        let actor = try UserID("00000000-0000-0000-0000-000000000701")
        let key = V2ProfileViewLookupKey(userID: try .init("00000000-0000-0000-0000-000000000702"), context: .directConversation)
        #expect(throws: V2ProfileViewReadError.invalidRequest) {
            _ = try V2ProfileViewReadRequest(actorUserID: actor, keys: [])
        }
        #expect(throws: V2ProfileViewReadError.invalidRequest) {
            _ = try V2ProfileViewReadRequest(actorUserID: actor, keys: [key, key])
        }
        #expect(throws: V2ProfileViewReadError.invalidRequest) {
            _ = try V2ProfileViewReadRequest(actorUserID: actor, keys: Array(repeating: key, count: 101))
        }
    }

    @Test("preserves request context and unavailable shape through the store boundary")
    func delegatesBoundedRequest() async throws {
        let actor = try UserID("00000000-0000-0000-0000-000000000711")
        let target = try UserID("00000000-0000-0000-0000-000000000712")
        let room = try RoomID("00000000-0000-0000-0000-000000000713")
        let direct = V2ProfileViewLookupKey(userID: target, context: .directConversation)
        let relationship = V2ProfileViewLookupKey(userID: target, context: .relationship)
        let group = V2ProfileViewLookupKey(userID: target, context: .room(room))
        let store = ProfileViewStoreSpy()
        let service = V2ProfileViewService(store: store)
        let request = try V2ProfileViewReadRequest(actorUserID: actor, keys: [direct, relationship, group])

        let results = try await service.read(request)

        #expect(await store.request() == request)
        #expect(results == [.unavailable(key: direct), .unavailable(key: relationship), .unavailable(key: group)])
    }
}

private actor ProfileViewStoreSpy: V2ProfileViewStore {
    private var captured: V2ProfileViewReadRequest?

    func read(_ request: V2ProfileViewReadRequest) async throws -> [V2ProfileViewLookupResult] {
        captured = request
        return request.keys.map(V2ProfileViewLookupResult.unavailable)
    }

    func request() -> V2ProfileViewReadRequest? { captured }
}

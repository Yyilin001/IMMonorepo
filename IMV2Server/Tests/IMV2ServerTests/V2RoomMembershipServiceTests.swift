import Foundation
import IMV2Core
import Testing

@Suite("V2 membership confirmation values")
struct V2RoomMembershipServiceTests {
    @Test("authenticated actor and immutable operation data survive encoding")
    func forwardsAuthenticatedChange() throws {
        let actor = UserID(uuid: UUID()), target = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let request = try V2MembershipIntent(roomID: room, actorUserID: actor, operationID: .init(uuid: UUID()),
            targetUserID: target, action: .add, expectedMembershipRevision: 4, confirmedUntilMilliseconds: 1_750_000_120_000)
        let restored = try JSONDecoder().decode(V2MembershipIntent.self, from: JSONEncoder().encode(request))
        #expect(restored == request)
        #expect(try restored.identity == request.identity)
        #expect(try restored.fingerprint == request.fingerprint)
    }

    @Test("invalid self-targeting is rejected before the persistence boundary")
    func rejectsInvalidCommandBeforeStore() throws {
        let user = UserID(uuid: UUID())
        #expect(throws: V2MembershipOperationValidationError.invalidIntent) {
            try V2MembershipIntent(roomID: .init(uuid: UUID()), actorUserID: user, operationID: .init(uuid: UUID()),
                targetUserID: user, action: .remove, expectedMembershipRevision: 1, confirmedUntilMilliseconds: 1_750_000_120_000)
        }
    }
}

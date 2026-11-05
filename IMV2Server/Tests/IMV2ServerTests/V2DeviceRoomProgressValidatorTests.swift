import Foundation
import IMV2Core
import IMV2ServerContracts
import IMV2ServerApplication
import Testing

struct V2DeviceRoomProgressValidatorTests {
    @Test("unopened authorized rooms report durable progress without a subscription")
    func unopenedRoom() async throws {
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
        let state = try V2RoomSynchronizationState(roomID: room, ownerEpoch: 1,
            viewerMembershipRevision: 3, head: 9, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0)
        let reader = ProgressStateReader(expectedUser: user, values: [room: .state(state)])
        let validator = V2DeviceRoomProgressValidator(states: reader)
        #expect(try await validator.validate(userID: user, reports: [(room, 9)]).first?.appliedThrough == 9)
        await #expect(throws: V2RoomRecoveryReadError.invalidRequest) {
            try await validator.validate(userID: user, reports: [(room, 10)])
        }
        await #expect(throws: V2RoomRecoveryReadError.invalidRequest) {
            try await validator.validate(userID: user, reports: [(room, 1), (room, 2)])
        }
        #expect(await reader.calls == 2)
    }

    @Test("denial, transient failure and incomplete state remain distinct", arguments: [0, 1, 2])
    func unavailable(kind: Int) async throws {
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
        let reader = ProgressStateReader(expectedUser: user, values: kind == 2 ? [:] : [room: kind == 0 ? .unavailable : .retry])
        let validator = V2DeviceRoomProgressValidator(states: reader)
        do {
            _ = try await validator.validate(userID: user, reports: [(room, 1)])
            Issue.record("Unauthorised or unresolved state must not be accepted")
        } catch V2RoomRecoveryReadError.invalidCursor { #expect(kind == 0) }
        catch V2DeviceRoomProgressValidationError.temporarilyUnavailable { #expect(kind == 1) }
        catch V2RoomRecoveryReadError.corruptPersistence { #expect(kind == 2) }
    }
}
private actor ProgressStateReader: V2RoomStateReading {
    let expectedUser: UserID
    let values: [RoomID: V2RoomStateReadResult]
    private(set) var calls = 0
    init(expectedUser: UserID, values: [RoomID: V2RoomStateReadResult]) {
        self.expectedUser = expectedUser; self.values = values
    }
    func states(roomIDs: [RoomID], actorUserID: UserID) throws -> [RoomID: V2RoomStateReadResult] {
        #expect(actorUserID == expectedUser)
        calls += 1
        return values
    }
}

import Foundation
import Testing
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
@testable import IMV2ServerGateway

@Suite("Journal partition connection indexes")
struct V2GatewayJournalInterestIndexTests {
    @Test("partition snapshots retain exact device lifecycles across removal and reuse")
    func lifecycleSnapshots() throws {
        let user = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), otherDevice = DeviceID(uuid: UUID())
        let identity = V2AuthenticatedConnection(userID: user, deviceID: device, capabilityProfile: "base")
        let secondIdentity = V2AuthenticatedConnection(userID: user, deviceID: otherDevice, capabilityProfile: "base")
        let a = UUID(), b = UUID(), p = V2RealtimeTopicKey(kind: .userSync, id: user.rawValue).partitionID()
        var index = V2GatewayJournalInterestIndex()
        index.insert(connection: a, identity: identity, lifecycle: 1)
        let first = index.snapshot(p)
        index.insert(connection: b, identity: secondIdentity, lifecycle: 2)
        let second = index.snapshot(p)
        #expect(first.interests.count == 1 && second.interests.count == 2)
        #expect(second.revision > first.revision)
        index.remove(a)
        #expect(index.contains(user: user.uuidValue!))
        #expect(!index.contains(device: .init(userID: user.uuidValue!, deviceID: device.uuidValue!)))
        index.insert(connection: a, identity: identity, lifecycle: 3)
        let successor = index.snapshot(p)
        #expect(successor.interests.contains { $0.connectionID == a && $0.lifecycle == 3 })
        #expect(!successor.interests.contains { $0.connectionID == a && $0.lifecycle == 1 })
        index.remove(a); index.remove(b)
        #expect(index.snapshot(p).interests.isEmpty)
        #expect(index.revision(p) > successor.revision)
        #expect(!index.contains(user: user.uuidValue!))
        #expect(index.allInterests().isEmpty)
    }

    @Test("unrelated partition mutations do not invalidate an installed local baseline")
    func isolatedRevisions() throws {
        let user = UserID(uuid: UUID())
        let p = V2RealtimeTopicKey(kind: .userSync, id: user.rawValue).partitionID()
        var other = UserID(uuid: UUID())
        while V2RealtimeTopicKey(kind: .userSync, id: other.rawValue).partitionID() == p { other = UserID(uuid: UUID()) }
        var index = V2GatewayJournalInterestIndex()
        let a = UUID(), b = UUID()
        index.insert(connection: a, identity: .init(userID: user, deviceID: DeviceID(uuid: UUID()), capabilityProfile: "base"), lifecycle: 1)
        let before = index.snapshot(p)
        index.insert(connection: b, identity: .init(userID: other, deviceID: DeviceID(uuid: UUID()), capabilityProfile: "base"), lifecycle: 2)
        index.remove(b)
        #expect(index.snapshot(p).revision == before.revision)
        #expect(index.snapshot(p).interests == before.interests)
    }
}

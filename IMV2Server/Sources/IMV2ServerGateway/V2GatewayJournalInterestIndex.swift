import Foundation
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts

public struct V2GatewayJournalInterestSnapshot: Sendable {
    public let revision: UInt64
    public let interests: Set<V2GatewayJournalUserControlInterest>
}

/// Actor-confined connection indexes. Partition and binary identities are
/// calculated on registration, never during a control baseline scan.
struct V2GatewayJournalInterestIndex: Sendable {
    struct Entry: Sendable {
        let interest: V2GatewayJournalUserControlInterest
        let partition: Int
        let user: UUID?
        let device: V2RealtimeJournalDeviceKey?
    }
    private var connections: [UUID: Entry] = [:]
    private var partitions: [Int: [UUID: V2GatewayJournalUserControlInterest]] = [:]
    private var revisions: [Int: UInt64] = [:] // At most 256 partition clocks.
    private var users: [UUID: Int] = [:]
    private var devices: [V2RealtimeJournalDeviceKey: Int] = [:]
    private var generation: UInt64 = 0

    mutating func insert(connection: UUID, identity: V2AuthenticatedConnection, lifecycle: UInt64) {
        precondition(connections[connection] == nil)
        let interest = V2GatewayJournalUserControlInterest(connectionID: connection,
            userID: identity.userID, deviceID: identity.deviceID, lifecycle: lifecycle)
        let partition = V2RealtimeTopicKey(kind: .userSync, id: identity.userID.rawValue).partitionID()
        let user = identity.userID.uuidValue
        let device = user.flatMap { user in identity.deviceID.uuidValue.map { V2RealtimeJournalDeviceKey(userID: user, deviceID: $0) } }
        connections[connection] = .init(interest: interest, partition: partition, user: user, device: device)
        partitions[partition, default: [:]][connection] = interest
        if let user { users[user, default: 0] += 1 }
        if let device { devices[device, default: 0] += 1 }
        advance(partition)
    }
    mutating func remove(_ connection: UUID) {
        guard let entry = connections.removeValue(forKey: connection) else { return }
        partitions[entry.partition]?.removeValue(forKey: connection)
        if partitions[entry.partition]?.isEmpty == true { partitions.removeValue(forKey: entry.partition) }
        if let user = entry.user {
            if users[user] == 1 { users.removeValue(forKey: user) } else { users[user]! -= 1 }
        }
        if let device = entry.device {
            if devices[device] == 1 { devices.removeValue(forKey: device) } else { devices[device]! -= 1 }
        }
        advance(entry.partition)
    }
    private mutating func advance(_ partition: Int) {
        generation &+= 1
        precondition(generation != 0, "journal interest generation exhausted")
        revisions[partition] = generation
    }
    func entry(_ connection: UUID) -> Entry? { connections[connection] }
    func contains(user: UUID) -> Bool { users[user] != nil }
    func contains(device: V2RealtimeJournalDeviceKey) -> Bool { devices[device] != nil }
    func revision(_ partition: Int) -> UInt64 { revisions[partition, default: 0] }
    func snapshot(_ partition: Int) -> V2GatewayJournalInterestSnapshot {
        .init(revision: revision(partition), interests: Set(partitions[partition]?.values.map { $0 } ?? []))
    }
    func allInterests() -> Set<V2GatewayJournalUserControlInterest> { Set(connections.values.map(\.interest)) }
}

import Foundation
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
import IMV2ServerGateway

/// Selective reads are safe only after every sequence up to a fixed trusted
/// cut was examined. The DB read may see newer state; it cannot advance this cut.
struct GatewayJournalControlCatchUp {
    private(set) var through: Int64
    let target: Int64
    private(set) var controls: V2GatewayJournalRecoveryControls
    let localUsers: Set<UserID>
    let installedVersions: [UserID: UInt64]

    var selectedUsers: Set<UserID> {
        Set(controls.versions.keys).union(controls.devices.map { UserID(uuid: $0.userID) })
            .union(controls.membershipRooms.keys).union(controls.membershipVersions.keys)
    }

    mutating func append(_ batch: V2RealtimeJournalBatch, partitionID: Int) -> Bool {
        guard batch.partitionID == partitionID, !batch.requiresSnapshot,
              batch.trimmedThrough <= through, batch.publishedThrough >= target else { return false }
        for entry in batch.entries {
            if through == target { break }
            guard through < Int64.max, entry.partitionID == partitionID,
                  entry.sequence == through + 1, entry.sequence <= batch.publishedThrough else { return false }
            through = entry.sequence
            if entry.topicKind == "userSync" {
                guard let uuid = UUID(uuidString: entry.topicID), let version = entry.userControlVersion,
                      version > 0 else { return false }
                let user = UserID(uuid: uuid)
                guard localUsers.contains(user), UInt64(version) > installedVersions[user, default: 0] else { continue }
                controls.versions[user] = max(controls.versions[user, default: 0], UInt64(version))
                if let device = entry.deviceID { controls.devices.insert(.init(userID: uuid, deviceID: device)) }
                if let room = entry.membershipRoomID {
                    controls.membershipRooms[user, default: []].insert(RoomID(uuid: room))
                    controls.membershipVersions[user] = max(controls.membershipVersions[user, default: 0], UInt64(version))
                }
            }
        }
        return through == target || !batch.entries.isEmpty
    }
}

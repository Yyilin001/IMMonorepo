import Foundation

/// Explicit deployment snapshot. Membership and spare room capacity cannot
/// change account/pair ownership; changing this mapping requires a new rollout.
public struct V2PolicyOwnerPlacementConfiguration: Codable, Equatable, Sendable {
    public struct Owner: Codable, Equatable, Sendable {
        public let hostID: UUID
        public let endpoint: String
        public let partitions: [Int]
        public init(hostID: UUID, endpoint: String, partitions: [Int]) throws {
            guard !endpoint.isEmpty, endpoint.utf8.count <= 128, !partitions.isEmpty,
                  partitions.count <= 4096, Set(partitions).count == partitions.count,
                  partitions.allSatisfy({ (0..<4096).contains($0) }) else {
                throw V2ActorContractError.invalidConfiguration("policy placement owner")
            }
            self.hostID = hostID; self.endpoint = endpoint; self.partitions = partitions.sorted()
        }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(hostID: c.decode(UUID.self, forKey: .hostID), endpoint: c.decode(String.self, forKey: .endpoint),
                partitions: c.decode([Int].self, forKey: .partitions))
        }
    }
    public let revision: Int64
    public let partitionCount: Int
    public let owners: [Owner]
    public init(revision: Int64, partitionCount: Int, owners: [Owner]) throws {
        let assigned = owners.flatMap(\.partitions)
        guard revision > 0, (1...4096).contains(partitionCount), partitionCount.nonzeroBitCount == 1,
              (1...64).contains(owners.count), Set(owners.map(\.hostID)).count == owners.count,
              assigned.count == partitionCount, Set(assigned) == Set(0..<partitionCount) else {
            throw V2ActorContractError.invalidConfiguration("policy placement")
        }
        self.revision = revision; self.partitionCount = partitionCount
        self.owners = owners.sorted { $0.hostID.uuidString < $1.hostID.uuidString }
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(revision: c.decode(Int64.self, forKey: .revision), partitionCount: c.decode(Int.self, forKey: .partitionCount),
            owners: c.decode([Owner].self, forKey: .owners))
    }
}

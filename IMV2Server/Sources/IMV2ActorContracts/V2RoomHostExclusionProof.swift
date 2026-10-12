import Foundation

/// Issued by a trusted deployment backend only after irreversible process
/// exclusion and database settlement. Neither a timeout nor wire decoding
/// constructs this capability. Its operation identity remains stable on retry.
public struct V2RoomHostExclusionProof: Sendable {
    public let host: V2ActorHostIdentity
    public let operationID: UUID
    public let settledShardIDs: Set<String>

    package init(host: V2ActorHostIdentity, operationID: UUID, settledShardIDs: Set<String>) {
        self.host = host
        self.operationID = operationID
        self.settledShardIDs = settledShardIDs
    }
}

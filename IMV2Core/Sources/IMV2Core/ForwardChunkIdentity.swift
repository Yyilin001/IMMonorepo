import Crypto
import Foundation

/// Deterministic UUID identity for a lazily created forward-plan chunk. Its
/// spelling is accepted by PostgreSQL UUID columns; it is not an ordering key.
public enum V2ForwardChunkIdentity {
    public static func operationID(planID: MessageForwardOperationID, chunkIndex: UInt64) throws -> MessageForwardOperationID {
        guard let plan = planID.uuidValue else { throw V2CoreError.invalidIdentifier }
        guard chunkIndex <= UInt64(Int64.max) else { throw V2CoreError.invalidNonNegativeValue }
        var input = Data("im-v2-forward-chunk-uuid-v1".utf8)
        var tuple = plan.uuid
        withUnsafeBytes(of: &tuple) { input.append(contentsOf: $0) }
        withUnsafeBytes(of: chunkIndex.bigEndian) { input.append(contentsOf: $0) }
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        // Application-defined UUID (version 8), standard UUID variant. All
        // remaining bits are a domain-separated digest of parent and index.
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return .init(uuid: UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )))
    }
}

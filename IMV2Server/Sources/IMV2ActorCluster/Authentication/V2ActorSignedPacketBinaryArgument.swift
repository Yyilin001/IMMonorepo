import DistributedCluster
import Foundation

/// Only the outer argument is binary. The signature and signed body are retained
/// unchanged and go through the existing Trust verification before body decoding.
extension V2ActorSignedPacket: ClusterBinaryInvocationArgument {
    private static var argumentMagic: [UInt8] { [73, 77, 86, 80] } // IMVP
    private static var maximumArgumentBodyBytes: Int { 16_777_216 }

    public func encodeClusterInvocationArgument() throws -> Data {
        var id = signerID.rawValue
        let idCount = id.utf8.count
        guard idCount <= V2ActorServiceID.maximumUTF8Bytes,
              body.count <= Self.maximumArgumentBodyBytes, signature.count <= 64 else {
            throw V2ActorAuthenticationError.oversized
        }
        var bytes = Data()
        bytes.reserveCapacity(17 + idCount + body.count + signature.count)
        bytes.append(contentsOf: Self.argumentMagic)
        bytes.append(1)
        let counts: InlineArray<3, Int> = [idCount, body.count, signature.count]
        for index in 0..<3 {
            var encoded = UInt32(counts[index]).littleEndian
            withUnsafeBytes(of: &encoded) { bytes.append(contentsOf: $0) }
        }
        id.withUTF8 { bytes.append(contentsOf: $0) }; bytes.append(body); bytes.append(signature)
        return bytes
    }

    public static func decodeClusterInvocationArgument(_ bytes: Data) throws -> Self? {
        guard bytes.starts(with: argumentMagic) else { return nil }
        guard bytes.count >= 17, bytes.count <= 17 + V2ActorServiceID.maximumUTF8Bytes + maximumArgumentBodyBytes + 64 else {
            throw V2ActorAuthenticationError.oversized
        }
        return try bytes.bytes.withUnsafeBytes { raw in
            guard raw[4] == 1 else { throw V2ActorAuthenticationError.unsupportedVersion }
            let idCount = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 5, as: UInt32.self)))
            let bodyCount = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 9, as: UInt32.self)))
            let signatureCount = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 13, as: UInt32.self)))
            guard (1...V2ActorServiceID.maximumUTF8Bytes).contains(idCount),
                  bodyCount <= maximumArgumentBodyBytes, signatureCount <= 64,
                  17 + idCount + bodyCount + signatureCount == raw.count,
                  let id = String(bytes: raw[17..<(17 + idCount)], encoding: .utf8),
                  let signer = try? V2ActorServiceID(id) else {
                throw V2ActorAuthenticationError.invalidRequest
            }
            let bodyStart = 17 + idCount, signatureStart = bodyStart + bodyCount
            // Retain bounded Data slices; do not eagerly copy the payload and MAC
            // out of the invocation buffer. Account for sliced input indices.
            let start = bytes.startIndex
            return .init(signerID: signer, body: bytes[(start + bodyStart)..<(start + signatureStart)],
                signature: bytes[(start + signatureStart)..<bytes.endIndex])
        }
    }
}

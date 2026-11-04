import Crypto
import Foundation
import IMV2ServerApplication
import IMV2ServerContracts

/// An explicit deployment policy: verify the exact stored bytes, without antivirus inspection.
public struct V2IntegrityOnlyResourceScanner: V2ResourceScanner {
    private let maximumBytes: Int64
    public init(maximumBytes: Int64) { self.maximumBytes = maximumBytes }

    public func scan(_ input: V2StoredObjectFacts, storage: any V2ObjectStorage) async throws -> V2ResourceScanReceipt {
        try Task.checkCancellation()
        guard input.byteCount > 0, input.byteCount <= maximumBytes,
              try await storage.inspect(input.reference) == input else { throw V2ResourceProviderError.integrityMismatch }
        let stream = try await storage.read(input.reference)
        var hash = SHA256()
        var remaining = input.byteCount
        let deadline = ContinuousClock.now + .seconds(120)
        while let chunk = try await stream.next() {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw V2ResourceProviderError.temporarilyUnavailable }
            guard chunk.count <= remaining else { throw V2ResourceProviderError.integrityMismatch }
            remaining -= Int64(chunk.count)
            hash.update(data: chunk)
        }
        guard remaining == 0, Data(hash.finalize()) == input.sha256 else { throw V2ResourceProviderError.integrityMismatch }
        return try .init(input: input, policyVersion: "integrity-only-v1", engineVersion: "antivirus-disabled", result: .passed)
    }
}

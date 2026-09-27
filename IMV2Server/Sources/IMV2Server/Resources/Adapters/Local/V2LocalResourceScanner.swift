import Foundation

/// Test fixture only. A real malware scanner must pass deployment acceptance separately.
public struct V2LocalResourceScanner: V2ResourceScanner {
    public init() {}
    public func scan(_ input: V2StoredObjectFacts, storage: any V2ObjectStorage) async throws -> V2ResourceScanReceipt {
        let facts = try await storage.inspect(input.reference)
        guard facts == input else { throw V2ResourceProviderError.integrityMismatch }
        let stream = try await storage.read(input.reference)
        let marker = Data("EICAR-STANDARD-ANTIVIRUS-TEST-FILE".utf8)
        var tail = Data()
        var result = V2MediaScanResult.passed
        while let chunk = try await stream.next() {
            tail.append(chunk)
            if tail.range(of: marker) != nil { result = .failed }
            tail = Data(tail.suffix(marker.count - 1))
        }
        return try .init(input: input, policyVersion: "local-fixture-v1", engineVersion: "eicar-fixture-v1", result: result)
    }
}

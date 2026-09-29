import IMV2ServerContracts
import Foundation

public struct V2ResourceScanReceipt: Sendable {
    public let input: V2StoredObjectFacts
    public let policyVersion: String
    public let engineVersion: String
    public let result: V2MediaScanResult
    public init(input: V2StoredObjectFacts, policyVersion: String, engineVersion: String, result: V2MediaScanResult) throws {
        guard [policyVersion, engineVersion].allSatisfy({
            !$0.isEmpty && $0.utf8.count <= 128 && $0.utf8.allSatisfy { (33...126).contains($0) }
        }) else { throw V2ResourceProviderError.configurationInvalid }
        self.input = input; self.policyVersion = policyVersion; self.engineVersion = engineVersion; self.result = result
    }
}
public protocol V2ResourceScanner: Sendable {
    func scan(_ input: V2StoredObjectFacts, storage: any V2ObjectStorage) async throws -> V2ResourceScanReceipt
}

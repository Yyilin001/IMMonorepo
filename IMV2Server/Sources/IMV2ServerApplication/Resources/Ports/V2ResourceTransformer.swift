import IMV2ServerContracts
import Foundation
import IMV2Core

public enum V2ResourceRecipe: String, Codable, Sendable { case avatar, preview }
/// The input cannot be decoded or exceeds the fixed image processing policy.
/// Infrastructure failures continue to use provider errors and remain retryable.
public enum V2ResourceTransformError: Error, Equatable, Sendable { case contentRejected }
/// Dimensions measured by the isolated decoder from the verified original bytes.
public struct V2ResourceImageDimensions: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              Int64(width) * Int64(height) <= 40_000_000 else { throw V2ResourceTransformError.contentRejected }
        self.width = width; self.height = height
    }
    /// Compare a declaration with the existing decoder result. Never promote
    /// client-provided values to verified facts or trigger a second decode.
    public func validate(clientDimensions: V2ResourcePixelDimensions?) throws {
        guard clientDimensions.map({ $0.width == width && $0.height == height }) ?? true
        else { throw V2ResourceTransformError.contentRejected }
    }
    private enum CodingKeys: CodingKey { case width, height }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(width: values.decode(Int.self, forKey: .width), height: values.decode(Int.self, forKey: .height))
    }
}
public struct V2ResourceTransformOutput: Sendable {
    public let size: Int
    public let facts: V2StoredObjectFacts
    public let sourceDimensions: V2ResourceImageDimensions
    public init(size: Int, facts: V2StoredObjectFacts, sourceDimensions: V2ResourceImageDimensions) throws {
        guard size > 0 else { throw V2ResourceProviderError.configurationInvalid }
        self.size = size; self.facts = facts; self.sourceDimensions = sourceDimensions
    }
}
public protocol V2ResourceTransformer: Sendable {
    /// Outputs are fixed, preallocated durable intents. Recipes are server policy, never arbitrary commands.
    func transform(input: V2StoredObjectFacts, recipe: V2ResourceRecipe,
                   outputs: [Int: V2StoredObjectReference], registry: V2ResourceStorageRegistry) async throws -> [V2ResourceTransformOutput]
}

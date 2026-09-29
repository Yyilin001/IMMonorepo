import IMV2ServerContracts
import Foundation

public enum V2ResourceRecipe: String, Codable, Sendable { case avatar, preview }
public struct V2ResourceTransformOutput: Sendable {
    public let size: Int
    public let facts: V2StoredObjectFacts
    public init(size: Int, facts: V2StoredObjectFacts) throws {
        guard size > 0 else { throw V2ResourceProviderError.configurationInvalid }
        self.size = size; self.facts = facts
    }
}
public protocol V2ResourceTransformer: Sendable {
    /// Outputs are fixed, preallocated durable intents. Recipes are server policy, never arbitrary commands.
    func transform(input: V2StoredObjectFacts, recipe: V2ResourceRecipe,
                   outputs: [Int: V2StoredObjectReference], registry: V2ResourceStorageRegistry) async throws -> [V2ResourceTransformOutput]
}

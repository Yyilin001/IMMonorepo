import IMV2ServerContracts
import Foundation
import IMV2Core

/// Trusted maintenance input, never an end-user upload or a change of logical home.
public struct V2ResourceMigrationRequest: Equatable, Codable, Sendable {
    public let operationID: UUID
    public let mediaID: UUID
    public let generation: Int64
    public let variantID: UUID?
    public let targetBinding: V2StorageBinding
    public init(operationID: UUID, mediaID: UUID, generation: Int64, variantID: UUID? = nil, targetBinding: V2StorageBinding) throws {
        guard generation > 0 else { throw V2ResourceProviderError.preconditionFailed }
        self.operationID=operationID; self.mediaID=mediaID; self.generation=generation
        self.variantID=variantID; self.targetBinding=targetBinding
    }
}

public struct V2ResourceMigrationStatus: Sendable {
    public enum State: String, Decodable, Sendable { case pending, copying, switched }
    public let request: V2ResourceMigrationRequest
    public let state: State
    public let source: V2StoredObjectFacts
    public let destination: V2StoredObjectFacts
    package init(request: V2ResourceMigrationRequest, state: State, source: V2StoredObjectFacts,
                 destination: V2StoredObjectFacts) {
        self.request = request; self.state = state; self.source = source; self.destination = destination
    }
}

public struct V2ResourceMigrationClaim: Sendable {
    public let status: V2ResourceMigrationStatus
    public let token: UUID
    package init(status: V2ResourceMigrationStatus, token: UUID) { self.status = status; self.token = token }
}

public protocol V2ResourceMigrationPort: Sendable {
    func prepare(_ request: V2ResourceMigrationRequest, maximumBytes: Int64,
                 allocate: @escaping @Sendable (V2StoredObjectFacts) throws -> V2StoredObjectReference) async throws -> V2ResourceMigrationStatus
    func status(_ operationID: UUID) async throws -> V2ResourceMigrationStatus
    func claim(_ operationID: UUID) async throws -> V2ResourceMigrationClaim?
    func publish(_ claim: V2ResourceMigrationClaim, observed: V2StoredObjectFacts) async throws
    func retry(_ claim: V2ResourceMigrationClaim) async throws
    func recoverable(limit: Int) async throws -> [UUID]
}

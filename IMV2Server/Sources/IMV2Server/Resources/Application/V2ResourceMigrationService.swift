import Foundation

/// Copy/verify/switch on one physical owner. The destination is durable before any
/// provider I/O. Old locations remain retained; there is no retirement shortcut.
public struct V2ResourceMigrationService: Sendable {
    let store: PostgresV2ResourceMigrationStore
    let registry: V2ResourceStorageRegistry
    let maximumBytes: Int64
    let allocate: @Sendable (V2StorageBinding) throws -> V2StoredObjectReference
    public init(store: PostgresV2ResourceMigrationStore, registry: V2ResourceStorageRegistry, maximumBytes: Int64,
                allocate: @escaping @Sendable (V2StorageBinding) throws -> V2StoredObjectReference) throws {
        guard maximumBytes > 0 else { throw V2ResourceProviderError.configurationInvalid }
        self.store=store; self.registry=registry; self.maximumBytes=maximumBytes; self.allocate=allocate
    }
    public func prepare(_ request: V2ResourceMigrationRequest) async throws -> V2ResourceMigrationStatus {
        _ = try registry.storage(for: request.targetBinding)
        return try await store.prepare(request, maximumBytes: maximumBytes, allocate: { source in
            _ = try registry.storage(for: source.reference.binding)
            return try allocate(request.targetBinding)
        })
    }
    public func resume(_ operationID: UUID) async throws -> V2ResourceMigrationStatus {
        guard let claim = try await store.claim(operationID) else { return try await store.status(operationID) }
        do {
            try Task.checkCancellation()
            let expected = claim.status.destination
            let destination = try registry.storage(for: expected.reference.binding)
            let facts: V2StoredObjectFacts
            do {
                facts = try await destination.inspect(expected.reference)
            } catch V2ResourceProviderError.notFound {
                let input = claim.status.source
                let source = try registry.storage(for: input.reference.binding)
                guard try await source.inspect(input.reference) == input else { throw V2ResourceProviderError.integrityMismatch }
                facts = try await destination.write(expected.reference, byteCount: expected.byteCount, sha256: expected.sha256,
                                                     bytes: source.read(input.reference))
            }
            guard facts == expected else { throw V2ResourceProviderError.integrityMismatch }
            try Task.checkCancellation()
            try await store.publish(claim, observed: facts)
        } catch {
            // Unknown writes keep their identity and both holds. A failed bookkeeping
            // attempt is recovered after the existing claim expires.
            try? await store.retry(claim)
            throw error
        }
        return try await store.status(operationID)
    }
    /// One bounded maintenance pass. Per-operation failures remain retryable and
    /// are returned to the owner for metrics/logging; they do not erase the job.
    public func recover(limit: Int = 16) async throws -> (switched: [UUID], retrying: [UUID]) {
        let operations = try await store.recoverable(limit: limit)
        var switched: [UUID] = [], retrying: [UUID] = []
        for operation in operations {
            try Task.checkCancellation()
            do { _ = try await resume(operation); switched.append(operation) }
            catch is CancellationError { throw CancellationError() }
            catch { retrying.append(operation) }
        }
        return (switched, retrying)
    }
}

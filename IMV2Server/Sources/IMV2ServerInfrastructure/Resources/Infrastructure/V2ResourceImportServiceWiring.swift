import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import IMV2Core

extension V2ResourceImportService {
    /// Keeps existing in-module callers source compatible during the port migration.
    public init(resources: V2ResourceService, resolve: @escaping V2ResourceStoreResolving,
                sources: V2ResourceImportSourceResolver, registry: V2ResourceStorageRegistry,
                transports: [any V2UploadTransport]) {
        let concrete: @Sendable (V2ResourceHome, V2ResourceUsage?, UserID, DeviceID) async throws -> PostgresV2ResourceLifecycleStore = { home, usage, actor, device in
            guard let store = try await resolve(home, usage, actor, device) as? PostgresV2ResourceLifecycleStore
            else { throw V2ResourceProviderError.configurationInvalid }
            return store
        }
        let persistence = PostgresV2ResourceImportStore(resolve: concrete, sources: sources,
            ownerDatabases: ["legacy": sources.control])
        self.init(resources: resources, resolve: resolve, persistence: persistence,
            registry: registry, transports: transports)
    }
}

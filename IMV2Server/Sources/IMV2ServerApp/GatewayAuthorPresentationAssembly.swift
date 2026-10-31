import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import FluentKit
import IMV2ActorApplication
import IMV2Server
import IMV2ServerInfrastructure

/// Provider selection stays in the application root. Authorization and runtime
/// ownership below accept only the resource delivery port.
enum GatewayAuthorPresentationAssembly {
    static func build(controlDatabase: any Database, actors: V2RoomActorApplication,
                      delivery: any V2ResourceDelivery) async throws -> V2AuthorPresentationRuntime {
        let profiles = V2ResourceProfilePresentationService(controlDatabase: controlDatabase,
            authorization: .init(directory: actors.directory), avatars: .init(delivery: delivery))
        let runtime = V2AuthorPresentationRuntime(configuration: try .init(), ingressConfiguration: try .init(), readBatch: { requests in
            try await profiles.readMany(requests)
        }, readDiagnostics: { profiles.readDiagnostics.snapshot() }, closeReader: { await profiles.close() })
        do {
            try await runtime.startProfileChanges(PostgresV2AuthorProfileChangeReader(database: controlDatabase))
            return runtime
        } catch {
            await runtime.close()
            throw error
        }
    }

    /// Signs for the account resource-byte endpoint with the same configured backend registry.
    static func delivery(configuration: V2ResourceRuntimeConfiguration,
                         storage: V2ResourceStorageAssembly,
                         controlDatabase: any Database) async throws -> any V2ResourceDelivery {
        try await V2ResourceStorageReadiness.verify(database: controlDatabase, registry: storage.registry)
        return try V2SignedResourceDelivery(registry: storage.registry, baseURL: configuration.publicBaseURL,
            keyID: "local-v1", keys: ["local-v1": configuration.signingKey])
    }
}

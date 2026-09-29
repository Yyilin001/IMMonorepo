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
                      delivery: any V2ResourceDelivery) throws -> V2AuthorPresentationRuntime {
        let profiles = V2ResourceProfilePresentationService(controlDatabase: controlDatabase,
            authorization: .init(directory: actors.directory), avatars: .init(delivery: delivery))
        return .init(configuration: try .init(), ingressConfiguration: try .init(), read: { request, identity in
            try await profiles.read(request, actorUserID: identity.userID, deviceID: identity.deviceID)
        }, closeReader: { await profiles.close() })
    }

    /// Current deployment adapter, matching the account resource-byte endpoint.
    /// A production adapter replaces this factory, not the runtime or chat code.
    static func localDelivery(configuration: V2LocalFilesystemMediaRuntimeConfiguration,
                              controlDatabase: any Database) async throws -> any V2ResourceDelivery {
        let backends = try V2ResourceBackendConfiguration(environment: ProcessRuntimeEnvironment(),
            defaultDirectory: configuration.rootDirectory)
        let storages = try backends.entries.map { entry in
            try V2LocalResourceStorage(root: URL(fileURLWithPath: entry.directory, isDirectory: true)
                .appendingPathComponent("sealed-resources"), binding: entry.binding)
        }
        let registry = try V2ResourceStorageRegistry(storages: storages, defaultBinding: backends.defaultBinding)
        try await V2ResourceStorageReadiness.verify(database: controlDatabase, registry: registry)
        return try V2LocalResourceDelivery(registry: registry, baseURL: configuration.publicBaseURL,
            keyID: "local-v1", keys: ["local-v1": configuration.signingKey])
    }
}

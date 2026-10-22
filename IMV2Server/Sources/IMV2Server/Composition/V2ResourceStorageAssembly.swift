import Foundation
import IMV2ServerApplication
import IMV2ServerContracts
import IMV2ServerInfrastructure

/// Shared account/gateway composition. Business services receive only ports and allocation.
public struct V2ResourceStorageAssembly: Sendable {
    public let registry: V2ResourceStorageRegistry
    public let ossClients: [V2StorageBinding: V2OSSClient]
    private let allocators: [V2StorageBinding: @Sendable () throws -> V2StoredObjectReference]

    public static func build(configuration: V2ResourceBackendConfiguration,
                             environment: any V2RuntimeEnvironment) async throws -> Self {
        var clients: [V2StorageBinding: V2OSSClient] = [:]
        var storages: [any V2ObjectStorage] = []
        var allocators: [V2StorageBinding: @Sendable () throws -> V2StoredObjectReference] = [:]
        do {
            for entry in configuration.entries {
                let binding = try entry.binding
                switch entry.providerKind {
                case .local:
                    guard let directory = entry.directory else { throw V2ResourceProviderError.configurationInvalid }
                    let storage = try V2LocalResourceStorage(root: URL(fileURLWithPath: directory, isDirectory: true)
                        .appendingPathComponent("sealed-resources"), binding: binding)
                    storages.append(storage)
                    allocators[binding] = { try storage.allocate() }
                case .oss:
                    guard let oss = entry.oss else { throw V2ResourceProviderError.configurationInvalid }
                    let client = V2OSSClient(configuration: try .init(bucket: oss.bucket, region: oss.region,
                        endpoint: oss.endpoint, prefix: oss.prefix, binding: binding),
                        credentials: .init(environment: environment, prefix: oss.credentialEnvironmentPrefix ?? "IM_V2_OSS_"))
                    clients[binding] = client
                    try await client.verifyReadiness()
                    let storage = V2OSSObjectStorage(client: client)
                    storages.append(storage)
                    allocators[binding] = { try storage.allocate() }
                }
            }
            return try .init(registry: .init(storages: storages, defaultBinding: configuration.defaultBinding),
                             ossClients: clients, allocators: allocators)
        } catch {
            for client in clients.values { try? await client.shutdown() }
            throw error
        }
    }
    public func allocate(binding: V2StorageBinding) throws -> V2StoredObjectReference {
        guard let allocate = allocators[binding] else { throw V2ResourceProviderError.configurationInvalid }
        return try allocate()
    }
    public func shutdown() async {
        for client in ossClients.values { try? await client.shutdown() }
    }
}

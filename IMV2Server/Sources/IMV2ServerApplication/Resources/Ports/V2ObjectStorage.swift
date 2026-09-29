import IMV2ServerContracts
import Foundation

/// Physical identities stay server-side. Changing a default binding never changes this value.
public struct V2StorageBinding: Hashable, Codable, Sendable {
    public let id: String
    public let configurationRevision: Int
    public init(id: String, configurationRevision: Int) throws {
        guard !id.isEmpty, id.utf8.count <= 128, configurationRevision > 0 else { throw V2ResourceProviderError.configurationInvalid }
        self.id = id; self.configurationRevision = configurationRevision
    }
    private enum CodingKeys: String, CodingKey { case id, configurationRevision }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(String.self, forKey: .id),
                      configurationRevision: values.decode(Int.self, forKey: .configurationRevision))
    }
}

public struct V2StoredObjectReference: Hashable, Codable, Sendable {
    public let placementID: UUID
    public let binding: V2StorageBinding
    public let formatVersion: Int
    public let handle: Data
    public init(placementID: UUID, binding: V2StorageBinding, formatVersion: Int = 1, handle: Data) throws {
        guard formatVersion > 0, !handle.isEmpty, handle.count <= 4096 else { throw V2ResourceProviderError.configurationInvalid }
        self.placementID = placementID; self.binding = binding; self.formatVersion = formatVersion; self.handle = handle
    }
    private enum CodingKeys: String, CodingKey { case placementID, binding, formatVersion, handle }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(placementID: values.decode(UUID.self, forKey: .placementID),
                      binding: values.decode(V2StorageBinding.self, forKey: .binding),
                      formatVersion: values.decode(Int.self, forKey: .formatVersion),
                      handle: values.decode(Data.self, forKey: .handle))
    }
}

public struct V2StoredObjectFacts: Equatable, Sendable {
    public let reference: V2StoredObjectReference
    public let byteCount: Int64
    public let sha256: Data
    public init(reference: V2StoredObjectReference, byteCount: Int64, sha256: Data) throws {
        guard byteCount > 0, sha256.count == 32 else { throw V2ResourceProviderError.integrityMismatch }
        self.reference = reference; self.byteCount = byteCount; self.sha256 = sha256
    }
}

public enum V2ResourceProviderError: Error, Equatable, Sendable {
    case notFound, preconditionFailed, integrityMismatch, unsupportedCapability
    case throttled(retryAfter: TimeInterval), temporarilyUnavailable, configurationInvalid, operationOutcomeUnknown
}

/// A pull stream: each read awaits the consumer, bounds memory and propagates cancellation.
public struct V2ResourceByteStream: Sendable {
    private let nextChunk: @Sendable () async throws -> Data?
    public init(next: @escaping @Sendable () async throws -> Data?) { nextChunk = next }
    public func next() async throws -> Data? {
        try Task.checkCancellation()
        let chunk = try await nextChunk()
        guard chunk == nil || chunk!.count <= 65_536 else { throw V2ResourceProviderError.integrityMismatch }
        return chunk
    }
}

public protocol V2ObjectStorage: Sendable {
    var binding: V2StorageBinding { get }
    func inspect(_ reference: V2StoredObjectReference) async throws -> V2StoredObjectFacts
    func read(_ reference: V2StoredObjectReference) async throws -> V2ResourceByteStream
    /// Destination identity is allocated and persisted before invoking this operation.
    func write(_ reference: V2StoredObjectReference, byteCount: Int64, sha256: Data, bytes: V2ResourceByteStream) async throws -> V2StoredObjectFacts
    /// Idempotent and restricted to the exact immutable identity.
    func delete(_ reference: V2StoredObjectReference) async throws
}

public struct V2ResourceStorageRegistry: Sendable {
    private let storages: [V2StorageBinding: any V2ObjectStorage]
    public let defaultBinding: V2StorageBinding
    public init(storages: [any V2ObjectStorage], defaultBinding: V2StorageBinding) throws {
        var values: [V2StorageBinding: any V2ObjectStorage] = [:]
        for storage in storages {
            guard values.updateValue(storage, forKey: storage.binding) == nil else { throw V2ResourceProviderError.configurationInvalid }
        }
        guard values[defaultBinding] != nil else { throw V2ResourceProviderError.configurationInvalid }
        self.storages = values; self.defaultBinding = defaultBinding
    }
    public func storage(for binding: V2StorageBinding) throws -> any V2ObjectStorage {
        guard let storage = storages[binding] else { throw V2ResourceProviderError.configurationInvalid }
        return storage
    }
    public func verifyReferencedBindings(_ bindings: Set<V2StorageBinding>) throws {
        for binding in bindings { _ = try storage(for: binding) }
    }
}

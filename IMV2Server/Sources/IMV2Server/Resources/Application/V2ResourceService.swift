import Foundation
import IMV2Core

public typealias V2ResourceStoreResolving = @Sendable (V2ResourceHome, V2ResourceUsage?, UserID, DeviceID) async throws -> PostgresV2ResourceLifecycleStore

/// Persistent lifecycle orchestration. Storage work never occurs inside a database transaction.
public struct V2ResourceService: Sendable {
    private let resolve: V2ResourceStoreResolving
    private let registry: V2ResourceStorageRegistry
    private let transports: [V2StorageBinding: any V2UploadTransport]
    private let allocate: @Sendable (V2StorageBinding) throws -> V2StoredObjectReference
    private let maximumBytes: Int64
    private let supportsAvatars: Bool
    public init(resolve: @escaping V2ResourceStoreResolving, registry: V2ResourceStorageRegistry,
                transports: [any V2UploadTransport], maximumBytes: Int64, supportsAvatars: Bool = false,
                allocate: @escaping @Sendable (V2StorageBinding) throws -> V2StoredObjectReference) throws {
        guard maximumBytes > 0 else { throw V2ResourceProviderError.configurationInvalid }
        var values: [V2StorageBinding: any V2UploadTransport] = [:]
        for transport in transports {
            _ = try registry.storage(for: transport.binding)
            guard transport.capabilities.maximumBytes > 0,
                  !Self.sessionModes(transport).isEmpty,
                  Set(transport.capabilities.modes).count == transport.capabilities.modes.count,
                  transport.capabilities.modes.allSatisfy(\.isUpload)
            else { throw V2ResourceProviderError.configurationInvalid }
            guard values.updateValue(transport, forKey: transport.binding) == nil else { throw V2ResourceProviderError.configurationInvalid }
        }
        guard values[registry.defaultBinding] != nil else { throw V2ResourceProviderError.configurationInvalid }
        self.resolve = resolve; self.registry = registry; self.transports = values
        self.maximumBytes = maximumBytes; self.allocate = allocate; self.supportsAvatars = supportsAvatars
    }
    public func capabilities() throws -> V2ResourceCapabilities {
        let transport = transports[registry.defaultBinding]!
        let supported = transport.capabilities
        return try .init(version: 1, uploadModes: Self.sessionModes(transport), maximumBytes: min(maximumBytes,supported.maximumBytes),
            allowedUsages: supportsAvatars ? [.messageAttachment,.userAvatar] : [.messageAttachment],
            maximumParts: 0, backgroundTransfer: false)
    }
    public func create(_ request: V2ResourceUploadRequest, actor: UserID, device: DeviceID) async throws -> V2ResourceUploadSession {
        let home = request.usage.home(actorUserID: actor)
        let store = try await resolve(home, request.usage, actor, device)
        let homeParts = try homeCoordinates(home)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let now = Date()
        let usageKind:String = switch request.usage {
        case .messageAttachment: "message_attachment"
        case .userAvatar: "user_avatar"
        case .groupAvatar: "group_avatar"
        }
        let row = try await store.create(homeKind: homeParts.0, homeID: homeParts.1, usageKind:usageKind, actor: uuid(actor), device: uuid(device),
            operation: uuid(request.operationID), mediaID: uuid(request.mediaID), contentType: request.contentType,
            byteCount: request.byteCount, requestJSON: String(decoding: encoder.encode(request), as: UTF8.self),
            allocate: {
                if !supportsAvatars {
                    guard case .messageAttachment = request.usage else { throw V2ResourceProviderError.unsupportedCapability }
                }
                if case .groupAvatar = request.usage { throw V2ResourceProviderError.unsupportedCapability }
                guard let transport = transports[registry.defaultBinding],
                      Self.sessionModes(transport).contains(where: request.clientModes.contains),
                      request.byteCount <= min(maximumBytes, transport.capabilities.maximumBytes)
                else { throw V2ResourceProviderError.unsupportedCapability }
                let placement = try allocate(registry.defaultBinding)
                guard placement.binding == registry.defaultBinding else { throw V2ResourceProviderError.configurationInvalid }
                return placement
            }, expiresAt: now.addingTimeInterval(3600), now: now)
        return try session(row, home: home)
    }
    public func status(_ locator: V2ResourceUploadLocator, actor: UserID, device: DeviceID) async throws -> V2ResourceUploadSession {
        let (_, row, _) = try await context(locator, actor: actor, device: device)
        return try session(row, home: locator.home)
    }
    public func targets(_ input: V2ResourceUploadTargetsRequest, actor: UserID, device: DeviceID) async throws -> [V2ResourceTransferPlan] {
        try Task.checkCancellation()
        let locator = input.locator
        guard input.partNumbers.isEmpty else { throw V2ResourceProviderError.unsupportedCapability }
        let (store, row, request) = try await context(locator, actor: actor, device: device)
        try Task.checkCancellation()
        guard row.generation == input.generation else { throw V2ResourceProviderError.preconditionFailed }
        guard ["created","uploading"].contains(row.state), row.expiresAt > Date(),
              let transport = transports[row.placement.binding] else { throw V2ResourceProviderError.preconditionFailed }
        guard let mode = Self.sessionModes(transport).first(where: request.clientModes.contains) else { throw V2ResourceProviderError.unsupportedCapability }
        let deadline = min(row.expiresAt, store.authorizationExpiresAt ?? row.expiresAt, Date().addingTimeInterval(120))
        let plan = try await transport.plan(mode: mode, mediaID: request.mediaID, contentType: request.contentType, byteCount: request.byteCount,
            checksum: request.checksum, expiresAt: deadline)
        try Task.checkCancellation()
        guard plan.mode == mode, plan.expectedByteCount == request.byteCount,
              plan.checksum == request.checksum, plan.expiresAt <= deadline,
              plan.byteRange == nil, plan.partNumber == nil
        else { throw V2ResourceProviderError.integrityMismatch }
        // Recheck after signing, including device/owner changes that occurred during adapter I/O.
        let current = try await store.status(session: row.sessionID, actor: uuid(actor), device: uuid(device))
        try Task.checkCancellation()
        guard current.generation == row.generation, ["created","uploading"].contains(current.state),
              current.expiresAt > Date(), plan.expiresAt <= current.expiresAt, plan.expiresAt > Date()
        else { throw V2ResourceProviderError.preconditionFailed }
        return [plan]
    }
    public func finalize(_ input: V2ResourceUploadFinalizeRequest, actor: UserID, device: DeviceID) async throws -> V2ResourceUploadSession {
        let locator = input.locator
        guard input.parts.isEmpty else { throw V2ResourceProviderError.unsupportedCapability }
        let (store, _, request) = try await context(locator, actor: actor, device: device)
        let claim = try await store.claimFinalize(session: uuid(locator.sessionID), generation: input.generation, actor: uuid(actor), device: uuid(device), now: Date())
        if claim.state == "completed" { return try session(claim, home: locator.home) }
        guard let transport = transports[claim.placement.binding] else { throw V2ResourceProviderError.configurationInvalid }
        let storage = try registry.storage(for: claim.placement.binding)
        let digest = Data(stride(from: 0, to: request.checksum.value.count, by: 2).map {
            let start = request.checksum.value.index(request.checksum.value.startIndex, offsetBy: $0)
            return UInt8(request.checksum.value[start..<request.checksum.value.index(start, offsetBy: 2)], radix: 16)!
        })
        // The destination is persisted before I/O. A lost response is reconciled against it.
        let facts: V2StoredObjectFacts
        do {
            facts = try await storage.inspect(claim.placement)
        } catch V2ResourceProviderError.notFound {
            let stream = try await transport.completedBytes(mediaID: request.mediaID, byteCount: request.byteCount)
            facts = try await storage.write(claim.placement, byteCount: request.byteCount, sha256: digest, bytes: stream)
        }
        // Both reconciliation and a fresh write must honor the same provider-independent contract.
        // A successful adapter call alone cannot publish a different object or different bytes.
        guard facts.reference == claim.placement, facts.byteCount == request.byteCount, facts.sha256 == digest
        else { throw V2ResourceProviderError.integrityMismatch }
        let publisher = try await resolve(locator.home, request.usage, actor, device)
        try await publisher.publish(claim, facts: facts, actor: uuid(actor), device: uuid(device), now: Date())
        return try await status(locator, actor: actor, device: device)
    }
    public func cancel(_ input: V2ResourceUploadCancelRequest, actor: UserID, device: DeviceID) async throws -> V2ResourceUploadSession {
        let locator = input.locator
        let (store, _, _) = try await context(locator, actor: actor, device: device)
        let row = try await store.cancel(session: uuid(locator.sessionID), generation: input.generation, actor: uuid(actor), device: uuid(device), now: Date())
        // Exact destination delete leaves a persistent fence against a late finalize copy.
        try await registry.storage(for: row.placement.binding).delete(row.placement)
        return try session(row, home: locator.home)
    }
    private static func sessionModes(_ transport: any V2UploadTransport) -> [V2ResourceTransferMode] {
        // Multipart needs durable part state and finalize receipts before it can be advertised.
        transport.capabilities.modes.filter { $0 == .httpPut || $0 == .httpFormPost }
    }
    private func context(_ locator: V2ResourceUploadLocator, actor: UserID, device: DeviceID) async throws -> (PostgresV2ResourceLifecycleStore,V2PersistedResourceUpload,V2ResourceUploadRequest) {
        let lookup = try await resolve(locator.home, nil, actor, device)
        let row = try await lookup.status(session: uuid(locator.sessionID), actor: uuid(actor), device: uuid(device))
        let request = try JSONDecoder().decode(V2ResourceUploadRequest.self, from: Data(row.requestJSON.utf8))
        guard request.usage.home(actorUserID: actor) == locator.home else { throw V2MediaStoreError.uploadNotAuthorized }
        let store = try await resolve(locator.home, request.usage, actor, device)
        let current = try await store.status(session: row.sessionID, actor: uuid(actor), device: uuid(device))
        return (store,current,request)
    }
    private func session(_ row: V2PersistedResourceUpload, home: V2ResourceHome) throws -> V2ResourceUploadSession {
        let state = V2ResourceUploadSessionState(rawValue: row.state) ?? .failed
        let resourceState: V2ResourceState
        switch row.mediaState {
        case "available": resourceState = .ready
        case "scanning": resourceState = .scanning
        case "expired": resourceState = .deletionPending
        case "failed": resourceState = .rejected
        default: resourceState = row.state == "finalizing" ? .verifying : .pending
        }
        return try .init(locator: .init(home: home, sessionID: .init(uuid: row.sessionID)), mediaID: .init(uuid: row.mediaID),
                         generation: row.generation, state: state, resourceState: resourceState,
                         expiresAt: row.expiresAt, bindableUntil: resourceState == .ready ? row.expiresAt : nil)
    }
    private func homeCoordinates(_ home: V2ResourceHome) throws -> (String,UUID) {
        switch home {
        case .account(let id): return ("account",try uuid(id))
        case .room(let id): return ("room",try uuid(id))
        }
    }
    private func uuid<T>(_ identifier: V2Identifier<T>) throws -> UUID where T: V2IdentifierTag {
        guard let value = UUID(uuidString: identifier.rawValue) else { throw V2ResourceProviderError.configurationInvalid }
        return value
    }
}

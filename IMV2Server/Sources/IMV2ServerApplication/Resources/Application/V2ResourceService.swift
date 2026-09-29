import IMV2ServerContracts
import Foundation
import IMV2Core

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
            maximumParts: (transport as? any V2MultipartUploadTransport)?.maximumParts ?? 0, backgroundTransfer: transport is any V2BackgroundUploadTransport)
    }
    public func create(_ request: V2ResourceUploadRequest, actor: UserID, device: DeviceID) async throws -> V2ResourceUploadSession {
        let home = request.usage.home(actorUserID: actor)
        let store = try await resolve(home, request.usage, actor, device)
        let now = Date()
        let row = try await store.create(request: request, home: home, actor: actor, device: device,
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
        let (_, row, request) = try await context(locator, actor: actor, device: device)
        let parts: [V2ResourceUploadPart]
        if [.created,.uploading,.finalizing].contains(row.phase), let transport = transports[row.placement.binding] as? any V2MultipartUploadTransport,
           Self.sessionModes(transport).first(where: request.clientModes.contains) == .httpPartPut {
            parts = try await transport.confirmedParts(mediaID: request.mediaID, byteCount: request.byteCount, checksum: request.checksum)
        } else { parts = [] }
        return try session(row, home: locator.home, parts: parts)
    }
    public func targets(_ input: V2ResourceUploadTargetsRequest, actor: UserID, device: DeviceID) async throws -> [V2ResourceTransferPlan] {
        try Task.checkCancellation()
        let locator = input.locator
        let (store, row, request) = try await context(locator, actor: actor, device: device)
        try Task.checkCancellation()
        guard row.generation == input.generation else { throw V2ResourceProviderError.preconditionFailed }
        guard [.created,.uploading].contains(row.phase), row.expiresAt > Date(),
              let transport = transports[row.placement.binding] else { throw V2ResourceProviderError.preconditionFailed }
        guard let mode = Self.sessionModes(transport).first(where: request.clientModes.contains) else { throw V2ResourceProviderError.unsupportedCapability }
        let instant = Date()
        let deadline: Date
        if input.background {
            guard case .messageAttachment = request.usage, mode == .httpPartPut,
                  transport is any V2BackgroundUploadTransport,
                  let deviceExpiry = store.backgroundDelegationExpiresAt, deviceExpiry>instant
            else { throw V2ResourceProviderError.unsupportedCapability }
            // New exact-object delegation, not an extension of activation/presentation authority.
            deadline = min(row.expiresAt,deviceExpiry,instant.addingTimeInterval(900))
        } else { deadline = min(row.expiresAt,store.authorizationExpiresAt ?? row.expiresAt,instant.addingTimeInterval(120)) }
        let plans: [V2ResourceTransferPlan]
        if input.background, let background = transport as? any V2BackgroundUploadTransport {
            plans = try await background.backgroundPartPlans(mediaID:request.mediaID,contentType:request.contentType,
                byteCount:request.byteCount,checksum:request.checksum,requestedParts:input.partNumbers,
                sessionID:locator.sessionID,generation:row.generation,issuedAt:instant,expiresAt:deadline)
            guard plans.allSatisfy({ plan in
                guard let grant=plan.backgroundAuthorization else { return false }
                return plan.mode == .httpPartPut && grant.sessionID == locator.sessionID && grant.generation == row.generation && grant.mediaID == request.mediaID && grant.expiresAt<=deadline
            }) else { throw V2ResourceProviderError.integrityMismatch }
        } else if mode == .httpPartPut, let multipart = transport as? any V2MultipartUploadTransport {
            plans = try await multipart.partPlans(mediaID: request.mediaID, contentType: request.contentType, byteCount: request.byteCount, checksum: request.checksum, requestedParts: input.partNumbers, expiresAt: deadline)
            guard plans.allSatisfy({ $0.mode == .httpPartPut && $0.byteRange != nil && $0.partNumber != nil && $0.expiresAt <= deadline }) else { throw V2ResourceProviderError.integrityMismatch }
        } else {
            guard input.partNumbers.isEmpty else { throw V2ResourceProviderError.unsupportedCapability }
            let plan = try await transport.plan(mode: mode, mediaID: request.mediaID, contentType: request.contentType, byteCount: request.byteCount, checksum: request.checksum, expiresAt: deadline)
            guard plan.mode == mode, plan.expectedByteCount == request.byteCount, plan.checksum == request.checksum,
                  plan.expiresAt <= deadline, plan.byteRange == nil, plan.partNumber == nil else { throw V2ResourceProviderError.integrityMismatch }
            plans = [plan]
        }
        // Recheck after signing, including device/owner changes that occurred during adapter I/O.
        let current = try await store.upload(session: row.sessionID, actor: uuid(actor), device: uuid(device))
        try Task.checkCancellation()
        guard current.generation == row.generation, [.created,.uploading].contains(current.phase),
              current.expiresAt > Date(), plans.allSatisfy({ $0.expiresAt <= current.expiresAt && $0.expiresAt > Date() })
        else { throw V2ResourceProviderError.preconditionFailed }
        return plans
    }
    public func finalize(_ input: V2ResourceUploadFinalizeRequest, actor: UserID, device: DeviceID) async throws -> V2ResourceUploadSession {
        let locator = input.locator
        let (store, before, request) = try await context(locator, actor: actor, device: device)
        guard let selectedTransport = transports[before.placement.binding] else { throw V2ResourceProviderError.configurationInvalid }
        let multipart = Self.sessionModes(selectedTransport).first(where: request.clientModes.contains) == .httpPartPut ? selectedTransport as? any V2MultipartUploadTransport : nil
        if before.phase != .completed {
            if let multipart {
                let confirmed = try await multipart.confirmedParts(mediaID: request.mediaID, byteCount: request.byteCount, checksum: request.checksum)
                guard confirmed == input.parts, confirmed.reduce(Int64(0), { $0 + $1.byteCount }) == request.byteCount else { throw V2ResourceProviderError.preconditionFailed }
            } else { guard input.parts.isEmpty else { throw V2ResourceProviderError.unsupportedCapability } }
        }
        let claim = try await store.claimUploadFinalize(session: uuid(locator.sessionID), generation: input.generation, actor: uuid(actor), device: uuid(device), now: Date())
        if claim.phase == .completed {
            if let multipart { try await multipart.abortParts(mediaID: request.mediaID, byteCount: request.byteCount, checksum: request.checksum) }
            return try session(claim, home: locator.home)
        }
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
            let stream: V2ResourceByteStream
            if let multipart { stream = try await multipart.completedParts(mediaID: request.mediaID, byteCount: request.byteCount, checksum: request.checksum, parts: input.parts) }
            else { stream = try await transport.completedBytes(mediaID: request.mediaID, byteCount: request.byteCount) }
            facts = try await storage.write(claim.placement, byteCount: request.byteCount, sha256: digest, bytes: stream)
        }
        // Both reconciliation and a fresh write must honor the same provider-independent contract.
        // A successful adapter call alone cannot publish a different object or different bytes.
        guard facts.reference == claim.placement, facts.byteCount == request.byteCount, facts.sha256 == digest
        else { throw V2ResourceProviderError.integrityMismatch }
        let publisher = try await resolve(locator.home, request.usage, actor, device)
        try await publisher.publishUpload(claim, facts: facts, actor: uuid(actor), device: uuid(device), now: Date())
        if let multipart { try await multipart.abortParts(mediaID: request.mediaID, byteCount: request.byteCount, checksum: request.checksum) }
        return try await status(locator, actor: actor, device: device)
    }
    public func cancel(_ input: V2ResourceUploadCancelRequest, actor: UserID, device: DeviceID) async throws -> V2ResourceUploadSession {
        let locator = input.locator
        let (store, _, request) = try await context(locator, actor: actor, device: device)
        let row = try await store.cancelUpload(session: uuid(locator.sessionID), generation: input.generation, actor: uuid(actor), device: uuid(device), now: Date())
        // Exact destination delete leaves a persistent fence against a late finalize copy.
        try await registry.storage(for: row.placement.binding).delete(row.placement)
        if let multipart = transports[row.placement.binding] as? any V2MultipartUploadTransport,
           Self.sessionModes(multipart).first(where: request.clientModes.contains) == .httpPartPut {
            try await multipart.abortParts(mediaID: request.mediaID,byteCount: request.byteCount,checksum: request.checksum)
        }
        return try session(row, home: locator.home)
    }
    private static func sessionModes(_ transport: any V2UploadTransport) -> [V2ResourceTransferMode] {
        // Multipart needs durable part state and finalize receipts before it can be advertised.
        transport.capabilities.modes.filter { $0 == .httpPut || $0 == .httpFormPost || ($0 == .httpPartPut && transport is any V2MultipartUploadTransport) }
    }
    private func context(_ locator: V2ResourceUploadLocator, actor: UserID, device: DeviceID) async throws -> (any V2ResourceLifecyclePort,V2ResourceUploadSnapshot,V2ResourceUploadRequest) {
        let lookup = try await resolve(locator.home, nil, actor, device)
        let row = try await lookup.upload(session: uuid(locator.sessionID), actor: uuid(actor), device: uuid(device))
        let request = row.request
        guard request.usage.home(actorUserID: actor) == locator.home else { throw V2MediaStoreError.uploadNotAuthorized }
        let store = try await resolve(locator.home, request.usage, actor, device)
        let current = try await store.upload(session: row.sessionID, actor: uuid(actor), device: uuid(device))
        return (store,current,request)
    }
    private func session(_ row: V2ResourceUploadSnapshot, home: V2ResourceHome, parts: [V2ResourceUploadPart] = []) throws -> V2ResourceUploadSession {
        let state: V2ResourceUploadSessionState
        switch row.phase {
        case .created: state = .created
        case .uploading: state = .uploading
        case .finalizing: state = .finalizing
        case .completed: state = .completed
        case .cancelled: state = .cancelled
        case .expired: state = .expired
        case .failed: state = .failed
        }
        let resourceState: V2ResourceState
        switch row.mediaPhase {
        case .available: resourceState = .ready
        case .scanning: resourceState = .scanning
        case .expired: resourceState = .deletionPending
        case .failed: resourceState = .rejected
        case .pendingUpload: resourceState = row.phase == .finalizing ? .verifying : .pending
        }
        return try .init(locator: .init(home: home, sessionID: .init(uuid: row.sessionID)), mediaID: .init(uuid: row.mediaID),
                         generation: row.generation, state: state, resourceState: resourceState,
                         expiresAt: row.expiresAt, bindableUntil: resourceState == .ready ? row.expiresAt : nil, confirmedParts: parts)
    }
    private func uuid<T>(_ identifier: V2Identifier<T>) throws -> UUID where T: V2IdentifierTag {
        guard let value = UUID(uuidString: identifier.rawValue) else { throw V2ResourceProviderError.configurationInvalid }
        return value
    }
}

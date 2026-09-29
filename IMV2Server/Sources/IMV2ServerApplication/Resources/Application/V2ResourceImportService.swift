import IMV2ServerContracts
import Foundation
import IMV2Core

public struct V2ResourceImportSnapshot: Sendable {
    public let request: V2ResourceImportRequest
    public let session: V2ResourceUploadSession?
    public let state: V2ResourceImportState
    public init(request: V2ResourceImportRequest, session: V2ResourceUploadSession?, state: V2ResourceImportState) {
        self.request = request; self.session = session; self.state = state
    }
}

public struct V2ResourceImportSourceGrant: Sendable {
    public let contentType: String
    public let facts: V2StoredObjectFacts
    public let recheck: @Sendable () async throws -> Void
    public init(contentType: String, facts: V2StoredObjectFacts, recheck: @escaping @Sendable () async throws -> Void) {
        self.contentType = contentType; self.facts = facts; self.recheck = recheck
    }
}

public struct V2ResourceImportRecoveryItem: Sendable {
    public let ownerID: String
    public let request: V2ResourceImportRequest
    public let locator: V2ResourceImportLocator
    public let actor: UserID
    public let device: DeviceID
    public init(ownerID: String, request: V2ResourceImportRequest, locator: V2ResourceImportLocator, actor: UserID, device: DeviceID) {
        self.ownerID = ownerID; self.request = request; self.locator = locator; self.actor = actor; self.device = device
    }
}

public protocol V2ResourceImportPort: Sendable {
    func create(_ request: V2ResourceImportRequest, actor: UserID, device: DeviceID) async throws
    func snapshot(_ locator: V2ResourceImportLocator, actor: UserID, device: DeviceID) async throws -> V2ResourceImportSnapshot
    func cancellationSnapshot(_ locator: V2ResourceImportLocator, actor: UserID, device: DeviceID) async throws -> V2ResourceImportSnapshot
    func acquireSource(_ request: V2ResourceImportRequest, actor: UserID, device: DeviceID) async throws -> V2ResourceImportSourceGrant
    func attach(_ session: V2ResourceUploadSession, locator: V2ResourceImportLocator, actor: UserID, device: DeviceID) async throws
    func mark(_ locator: V2ResourceImportLocator, actor: UserID, device: DeviceID, state: V2ResourceImportState) async throws
    func releaseSource(_ request: V2ResourceImportRequest, actor: UserID) async throws
    func recoveryCandidates(ownerID: String, limit: Int) async throws -> [V2ResourceImportRecoveryItem]
    func recordRecoveryFailure(_ item: V2ResourceImportRecoveryItem) async throws -> Bool
}

/// Copies exact held source bytes. The source hold is released only after target closure.
public struct V2ResourceImportService: Sendable {
    let resources: V2ResourceService
    let resolve: V2ResourceStoreResolving
    let persistence: any V2ResourceImportPort
    let registry: V2ResourceStorageRegistry
    let transports: [V2StorageBinding: any V2UploadTransport]

    public init(resources: V2ResourceService, resolve: @escaping V2ResourceStoreResolving,
                persistence: any V2ResourceImportPort, registry: V2ResourceStorageRegistry,
                transports: [any V2UploadTransport]) {
        self.resources = resources; self.resolve = resolve; self.persistence = persistence; self.registry = registry
        self.transports = Dictionary(uniqueKeysWithValues: transports.map { ($0.binding, $0) })
    }

    public func create(_ request: V2ResourceImportRequest, actor: UserID, device: DeviceID) async throws -> V2ResourceImportStatus {
        try await persistence.create(request, actor: actor, device: device)
        let locator = V2ResourceImportLocator(home: request.targetUsage.home(actorUserID: actor), operationID: request.operationID)
        return try await resume(locator, actor: actor, device: device)
    }

    public func resume(_ locator: V2ResourceImportLocator, actor: UserID, device: DeviceID) async throws -> V2ResourceImportStatus {
        let snapshot = try await persistence.snapshot(locator, actor: actor, device: device)
        let request = snapshot.request
        if snapshot.state == .cancelled || snapshot.state == .failed { return try outcome(snapshot, locator: locator) }
        if let session = snapshot.session {
            let current = try await resources.status(session.locator, actor: actor, device: device)
            if current.state == .completed {
                let state: V2ResourceImportState = current.resourceState == .ready ? .ready
                    : (current.resourceState == .rejected || current.resourceState == .deletionPending ? .failed : .processing)
                try await persistence.mark(locator, actor: actor, device: device, state: state)
                try await persistence.releaseSource(request, actor: actor)
                return try .init(locator: locator, mediaID: request.targetMediaID, state: state,
                    bindableUntil: state == .ready ? current.bindableUntil : nil)
            }
            if [.cancelled, .expired, .failed].contains(current.state) {
                try await persistence.mark(locator, actor: actor, device: device, state: .failed)
                try await persistence.releaseSource(request, actor: actor)
                return try .init(locator: locator, mediaID: request.targetMediaID, state: .failed, bindableUntil: nil)
            }
        }
        let source = try await persistence.acquireSource(request, actor: actor, device: device)
        try await source.recheck()
        let upload = try V2ResourceUploadRequest(operationID: .init(request.operationID.rawValue),
            mediaID: request.targetMediaID, usage: request.targetUsage, contentType: source.contentType,
            byteCount: source.facts.byteCount,
            checksum: .init(value: source.facts.sha256.map { String(format: "%02x", $0) }.joined()), clientModes: [.httpPut])
        let session = try await resources.create(upload, actor: actor, device: device)
        try await persistence.attach(session, locator: locator, actor: actor, device: device)
        let store = try await resolve(locator.home, request.targetUsage, actor, device)
        let target = try await store.upload(session: session.locator.sessionID.uuidValue!, actor: actor.uuidValue!, device: device.uuidValue!)
        guard let transport = transports[target.placement.binding] else { throw V2ResourceProviderError.configurationInvalid }
        let bytes = try await registry.storage(for: source.facts.reference.binding).read(source.facts.reference)
        try await transport.importBytes(mediaID: request.targetMediaID, contentType: source.contentType,
            byteCount: source.facts.byteCount, bytes: bytes)
        try await source.recheck()
        let completed = try await resources.finalize(.init(locator: session.locator, generation: session.generation), actor: actor, device: device)
        try await persistence.mark(locator, actor: actor, device: device, state: .processing)
        try await persistence.releaseSource(request, actor: actor)
        return try .init(locator: locator, mediaID: request.targetMediaID,
            state: completed.resourceState == .ready ? .ready : .processing,
            bindableUntil: completed.resourceState == .ready ? completed.bindableUntil : nil)
    }

    public func status(_ locator: V2ResourceImportLocator, actor: UserID, device: DeviceID) async throws -> V2ResourceImportStatus {
        let snapshot = try await persistence.snapshot(locator, actor: actor, device: device)
        guard let session = snapshot.session, snapshot.state != .cancelled, snapshot.state != .failed else {
            return try outcome(snapshot, locator: locator)
        }
        let current = try await resources.status(session.locator, actor: actor, device: device)
        return try .init(locator: locator, mediaID: snapshot.request.targetMediaID,
            state: current.resourceState == .ready ? .ready : ([.cancelled, .expired, .failed].contains(current.state) ? .failed : .processing),
            bindableUntil: current.resourceState == .ready ? current.bindableUntil : nil)
    }

    public func cancel(_ locator: V2ResourceImportLocator, actor: UserID, device: DeviceID) async throws -> V2ResourceImportStatus {
        let snapshot = try await persistence.cancellationSnapshot(locator, actor: actor, device: device)
        if let session = snapshot.session {
            _ = try await resources.cancel(.init(locator: session.locator, generation: session.generation), actor: actor, device: device)
        }
        try await persistence.mark(locator, actor: actor, device: device, state: .cancelled)
        try await persistence.releaseSource(snapshot.request, actor: actor)
        return try .init(locator: locator, mediaID: snapshot.request.targetMediaID, state: .cancelled, bindableUntil: nil)
    }

    public func runOnce(ownerID: String, limit: Int = 16) async throws {
        for item in try await persistence.recoveryCandidates(ownerID: ownerID, limit: limit) {
            try Task.checkCancellation()
            do { _ = try await resume(item.locator, actor: item.actor, device: item.device) }
            catch {
                if try await persistence.recordRecoveryFailure(item) {
                    try await persistence.releaseSource(item.request, actor: item.actor)
                }
            }
        }
    }

    private func outcome(_ snapshot: V2ResourceImportSnapshot, locator: V2ResourceImportLocator) throws -> V2ResourceImportStatus {
        try .init(locator: locator, mediaID: snapshot.request.targetMediaID, state: snapshot.state, bindableUntil: nil)
    }
}

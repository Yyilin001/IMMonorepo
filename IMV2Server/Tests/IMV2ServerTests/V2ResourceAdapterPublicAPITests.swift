import IMV2ServerApplication
import IMV2ServerContracts
import Crypto
import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2Core
import IMV2Server
import IMV2ServerInfrastructure
import SQLKit
import Testing

// Deliberately uses the public import: deployment adapters must work outside IMV2Server.
struct V2ResourceAdapterPublicAPITests {
    @Test("upload publication validates independent adapter receipts for writes and recovery",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil),
          arguments: [false, true], AdapterReceiptMutation.allCases)
    func uploadReceiptBoundary(reconcile: Bool, mutation: AdapterReceiptMutation) async throws {
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"])),
                                    as: .psql, isDefault: true)
            let database = resources.database(.psql)
            let sql = try #require(database as? any SQLDatabase)
            let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
            let binding = try V2StorageBinding(id: "external-receipt-adapter", configurationRevision: 7)
            let reference = try V2StoredObjectReference(placementID: UUID(), binding: binding,
                formatVersion: 3, handle: Data("adapter-private-exact-object".utf8))
            let payload = Data("provider-neutral-content".utf8)
            let facts = try V2StoredObjectFacts(reference: reference, byteCount: Int64(payload.count),
                                              sha256: Data(SHA256.hash(data: payload)))
            let storage = ReceiptBoundaryStorage(expected: facts, returned: try mutation.apply(to: facts), reconcile: reconcile)
            let registry = try V2ResourceStorageRegistry(storages: [storage], defaultBinding: binding)
            let transport = ExternalUploadTransport(binding: binding, payload: payload)
            let service = try V2ResourceService(resolve: { _, _, _, _ in PostgresV2ResourceLifecycleStore(database: database, authorize: { _ in }) },
                registry: registry, transports: [transport], maximumBytes: 1_024, allocate: { _ in reference })
            let request = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()),
                usage: .messageAttachment(.init(uuid: UUID())), contentType: "application/octet-stream",
                byteCount: facts.byteCount, checksum: .init(value: facts.sha256.map { String(format: "%02x", $0) }.joined()),
                clientModes: [.httpPut])
            let session = try await service.create(request, actor: actor, device: device)
            let plan = try #require(try await service.targets(.init(locator: session.locator, generation: session.generation),
                                                           actor: actor, device: device).first)
            #expect(plan.url.host == "external-upload.example")
            #expect(plan.headers.first?.name == "X-Independent-Object-Capability")
            #expect(plan.checksum == request.checksum)
            let finalize = try V2ResourceUploadFinalizeRequest(locator: session.locator, generation: session.generation)
            if mutation == .none {
                #expect(try await service.finalize(finalize, actor: actor, device: device).resourceState == .scanning)
                #expect(try await service.finalize(finalize, actor: actor, device: device).state == .completed)
            } else {
                await #expect(throws: V2ResourceProviderError.integrityMismatch) {
                    _ = try await service.finalize(finalize, actor: actor, device: device)
                }
                let status = try await service.status(session.locator, actor: actor, device: device)
                #expect(status.state == .finalizing && status.resourceState == .verifying)
            }
            let mediaID = try #require(UUID(uuidString: request.mediaID.rawValue))
            let publication = try #require(try await sql.raw("""
                SELECT (SELECT COUNT(*) FROM im_v2.resource_blob_placements WHERE media_id=\(bind: mediaID)) AS placements,
                       (SELECT COUNT(*) FROM im_v2.media_scan_outbox WHERE media_id=\(bind: mediaID)) AS scans
                """).first(decoding: AdapterPublicationCounts.self))
            #expect(publication.placements == (mutation == .none ? 1 : 0))
            #expect(publication.scans == (mutation == .none ? 1 : 0))
            let persisted = try await PostgresV2ResourceLifecycleStore(database: database, authorize: { _ in })
                .status(session: #require(UUID(uuidString: session.locator.sessionID.rawValue)),
                        actor: #require(UUID(uuidString: actor.rawValue)), device: #require(UUID(uuidString: device.rawValue)))
            #expect(persisted.placement == reference)
            #expect(await storage.calls() == (inspects: 1, writes: reconcile ? 0 : 1))
            try await resources.shutdown()
        } catch {
            try? await resources.shutdown()
            throw error
        }
    }

    @Test func signingRechecksUploadGenerationWithoutDatabase() async throws {
        let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
        let binding = try V2StorageBinding(id: "fake-authority", configurationRevision: 1)
        let reference = try V2StoredObjectReference(placementID: UUID(), binding: binding,
            formatVersion: 1, handle: Data("exact-object".utf8))
        let payload = Data("bytes".utf8)
        let request = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()),
            usage: .messageAttachment(.init(uuid: UUID())), contentType: "application/octet-stream",
            byteCount: Int64(payload.count), checksum: .init(value: Data(SHA256.hash(data: payload)).map { String(format: "%02x", $0) }.joined()),
            clientModes: [.httpPut])
        let home = request.usage.home(actorUserID: actor)
        let snapshot = V2ResourceUploadSnapshot(sessionID: UUID(), mediaID: UUID(uuidString: request.mediaID.rawValue)!,
            generation: 1, phase: .created, mediaPhase: .pendingUpload, request: request,
            placement: reference, expiresAt: Date().addingTimeInterval(300), claimToken: nil)
        let port = RevokingUploadPort(snapshot: snapshot)
        let facts = try V2StoredObjectFacts(reference: reference, byteCount: Int64(payload.count), sha256: Data(SHA256.hash(data: payload)))
        let registry = try V2ResourceStorageRegistry(storages: [PublicAPIStorage(facts: facts)], defaultBinding: binding)
        let service = try V2ResourceService(resolve: { _, _, _, _ in port }, registry: registry,
            transports: [ExternalUploadTransport(binding: binding, payload: payload)], maximumBytes: 1_024,
            allocate: { _ in reference })
        let locator = V2ResourceUploadLocator(home: home, sessionID: .init(uuid: snapshot.sessionID))
        await #expect(throws: V2ResourceProviderError.preconditionFailed) {
            _ = try await service.targets(.init(locator: locator, generation: 1), actor: actor, device: device)
        }
        #expect(await port.readCount == 3)
    }

    @Test func externalProcessorsCanConstructTheirReceipts() async throws {
        let binding = try V2StorageBinding(id: "independent-adapter", configurationRevision: 7)
        let reference = try V2StoredObjectReference(placementID: UUID(), binding: binding,
            formatVersion: 2, handle: Data("opaque-immutable-version".utf8))
        let facts = try V2StoredObjectFacts(reference: reference, byteCount: 10, sha256: Data(repeating: 1, count: 32))
        let storage = PublicAPIStorage(facts: facts)
        let scan: any V2ResourceScanner = ExternalScanner()
        let receipt = try await scan.scan(facts, storage: storage)
        #expect(receipt.input == facts)
        #expect(receipt.result == .passed)
        #expect(receipt.engineVersion == "external-engine-v3")
        let registry = try V2ResourceStorageRegistry(storages: [storage], defaultBinding: binding)
        let transform: any V2ResourceTransformer = ExternalTransformer(facts: facts)
        let outputs = try await transform.transform(input: facts, recipe: .avatar,
            outputs: [128: reference], registry: registry)
        #expect(outputs.first?.size == 128)
        #expect(outputs.first?.facts == facts)
        #expect(throws: V2ResourceProviderError.configurationInvalid) {
            _ = try V2ResourceScanReceipt(input: facts, policyVersion: "", engineVersion: "v1", result: .passed)
        }
        #expect(throws: V2ResourceProviderError.configurationInvalid) {
            _ = try V2ResourceTransformOutput(size: 0, facts: facts, sourceDimensions: .init(width: 1, height: 1))
        }
    }
}

enum AdapterReceiptMutation: CaseIterable, Sendable {
    case none, binding, configurationRevision, placement, format, handle, byteCount, checksum

    func apply(to facts: V2StoredObjectFacts) throws -> V2StoredObjectFacts {
        let original = facts.reference
        let binding = try V2StorageBinding(id: self == .binding ? "another-backend" : original.binding.id,
            configurationRevision: original.binding.configurationRevision + (self == .configurationRevision ? 1 : 0))
        let reference = try V2StoredObjectReference(placementID: self == .placement ? UUID() : original.placementID,
            binding: binding, formatVersion: original.formatVersion + (self == .format ? 1 : 0),
            handle: self == .handle ? Data("another-object".utf8) : original.handle)
        return try .init(reference: reference, byteCount: facts.byteCount + (self == .byteCount ? 1 : 0),
                         sha256: self == .checksum ? Data(repeating: 0, count: 32) : facts.sha256)
    }
}

private struct AdapterPublicationCounts: Decodable {
    let placements: Int64
    let scans: Int64
}

/// No local filesystem adapter participates: the application must validate any implementation.
private actor ReceiptBoundaryStorage: V2ObjectStorage {
    nonisolated let binding: V2StorageBinding
    let expected: V2StoredObjectFacts
    let returned: V2StoredObjectFacts
    let reconcile: Bool
    private var inspects = 0
    private var writes = 0

    init(expected: V2StoredObjectFacts, returned: V2StoredObjectFacts, reconcile: Bool) {
        binding = expected.reference.binding
        self.expected = expected; self.returned = returned; self.reconcile = reconcile
    }
    func inspect(_ reference: V2StoredObjectReference) throws -> V2StoredObjectFacts {
        inspects += 1
        #expect(reference == expected.reference)
        guard reconcile else { throw V2ResourceProviderError.notFound }
        return returned
    }
    func write(_ reference: V2StoredObjectReference, byteCount: Int64, sha256: Data,
               bytes: V2ResourceByteStream) async throws -> V2StoredObjectFacts {
        writes += 1
        #expect(reference == expected.reference && byteCount == expected.byteCount && sha256 == expected.sha256)
        var received = Data()
        while let chunk = try await bytes.next() { received.append(chunk) }
        #expect(Int64(received.count) == expected.byteCount)
        #expect(Data(SHA256.hash(data: received)) == expected.sha256)
        return returned
    }
    func read(_ reference: V2StoredObjectReference) throws -> V2ResourceByteStream { throw V2ResourceProviderError.unsupportedCapability }
    func delete(_ reference: V2StoredObjectReference) throws { throw V2ResourceProviderError.unsupportedCapability }
    func calls() -> (inspects: Int, writes: Int) { (inspects, writes) }
}

private struct ExternalUploadTransport: V2UploadTransport {
    let binding: V2StorageBinding
    let payload: Data
    var capabilities: V2ResourceTransportCapabilities { .init(modes: [.httpPut], maximumBytes: 1_024) }
    func plan(mode: V2ResourceTransferMode, mediaID: MediaID, contentType: String, byteCount: Int64,
              checksum: V2ResourceChecksum, expiresAt: Date) throws -> V2ResourceTransferPlan {
        try .init(mode: mode, url: URL(string: "https://external-upload.example/objects/\(mediaID.rawValue)")!,
            headers: [.init(name: "X-Independent-Object-Capability", value: "test-object-token", kind: .objectCapability)],
            expiresAt: expiresAt, expectedByteCount: byteCount, checksum: checksum)
    }
    func completedBytes(mediaID: MediaID, byteCount: Int64) -> V2ResourceByteStream {
        let chunks = ExternalUploadChunks(payload)
        return .init { await chunks.next() }
    }
    func importBytes(mediaID: MediaID, contentType: String, byteCount: Int64, bytes: V2ResourceByteStream) throws {
        throw V2ResourceProviderError.unsupportedCapability
    }
    func abort(mediaID: MediaID) throws { throw V2ResourceProviderError.unsupportedCapability }
}

private actor ExternalUploadChunks {
    var pending: Data?
    init(_ bytes: Data) { pending = bytes }
    func next() -> Data? { defer { pending = nil }; return pending }
}
private struct ExternalScanner: V2ResourceScanner {
    func scan(_ input: V2StoredObjectFacts, storage: any V2ObjectStorage) async throws -> V2ResourceScanReceipt {
        guard try await storage.inspect(input.reference) == input else { throw V2ResourceProviderError.integrityMismatch }
        return try .init(input: input, policyVersion: "policy-v1", engineVersion: "external-engine-v3", result: .passed)
    }
}
private struct ExternalTransformer: V2ResourceTransformer {
    let facts: V2StoredObjectFacts
    func transform(input: V2StoredObjectFacts, recipe: V2ResourceRecipe,
                   outputs: [Int: V2StoredObjectReference], registry: V2ResourceStorageRegistry) async throws -> [V2ResourceTransformOutput] {
        try outputs.map { size, reference in
            guard reference == facts.reference else { throw V2ResourceProviderError.integrityMismatch }
            return try .init(size: size, facts: facts, sourceDimensions: .init(width: 300, height: 160))
        }
    }
}
private struct PublicAPIStorage: V2ObjectStorage {
    let facts: V2StoredObjectFacts
    var binding: V2StorageBinding { facts.reference.binding }
    func inspect(_ reference: V2StoredObjectReference) async throws -> V2StoredObjectFacts { facts }
    func read(_ reference: V2StoredObjectReference) async throws -> V2ResourceByteStream { throw V2ResourceProviderError.unsupportedCapability }
    func write(_ reference: V2StoredObjectReference, byteCount: Int64, sha256: Data, bytes: V2ResourceByteStream) async throws -> V2StoredObjectFacts { throw V2ResourceProviderError.unsupportedCapability }
    func delete(_ reference: V2StoredObjectReference) async throws { throw V2ResourceProviderError.unsupportedCapability }
}

private actor RevokingUploadPort: V2ResourceLifecyclePort {
    let authorizationExpiresAt: Date? = nil
    let backgroundDelegationExpiresAt: Date? = nil
    let snapshot: V2ResourceUploadSnapshot
    var readCount = 0
    init(snapshot: V2ResourceUploadSnapshot) { self.snapshot = snapshot }
    func create(request: V2ResourceUploadRequest, home: V2ResourceHome, actor: UserID, device: DeviceID,
                allocate: @escaping @Sendable () throws -> V2StoredObjectReference,
                expiresAt: Date, now: Date) async throws -> V2ResourceUploadSnapshot {
        throw V2ResourceProviderError.unsupportedCapability
    }
    func upload(session: UUID, actor: UUID, device: UUID) async throws -> V2ResourceUploadSnapshot {
        readCount += 1
        if readCount == 3 {
            return .init(sessionID: snapshot.sessionID, mediaID: snapshot.mediaID, generation: 2,
                phase: snapshot.phase, mediaPhase: snapshot.mediaPhase, request: snapshot.request,
                placement: snapshot.placement, expiresAt: snapshot.expiresAt, claimToken: nil)
        }
        return snapshot
    }
    func claimUploadFinalize(session: UUID, generation: Int64, actor: UUID, device: UUID, now: Date) async throws -> V2ResourceUploadSnapshot {
        throw V2ResourceProviderError.unsupportedCapability
    }
    func publishUpload(_ claim: V2ResourceUploadSnapshot, facts: V2StoredObjectFacts, actor: UUID, device: UUID, now: Date) async throws {
        throw V2ResourceProviderError.unsupportedCapability
    }
    func cancelUpload(session: UUID, generation: Int64, actor: UUID, device: UUID, now: Date) async throws -> V2ResourceUploadSnapshot {
        throw V2ResourceProviderError.unsupportedCapability
    }
}

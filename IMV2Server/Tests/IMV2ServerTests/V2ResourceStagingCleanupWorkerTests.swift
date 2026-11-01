import Foundation
import IMV2Core
import IMV2ServerApplication
import Testing
@testable import IMV2ServerInfrastructure

struct V2ResourceStagingCleanupWorkerTests {
    @Test func cancellationDrainsTheNativeCleanupWithoutAcknowledgingItsLease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("im-cleanup-cancel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = try V2StorageBinding(id: "paused-upload", configurationRevision: 1)
        let storage = try V2LocalResourceStorage(root: root, binding: binding)
        let gate = PausedCleanup()
        let request = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()),
            usage: .messageAttachment(.init(uuid: UUID())), contentType: "text/plain", byteCount: 1,
            checksum: ossMultipartChecksum(Data([1])), clientModes: [.httpPut], displayName: .init("fixture.txt"))
        let persistence = CleanupLease(.init(sessionID: UUID(), token: UUID(), source: .success((request, binding))))
        let service = try V2ResourceService(resolve: { _, _, _, _ in throw V2ResourceProviderError.unsupportedCapability },
            registry: .init(storages: [storage], defaultBinding: binding), transports: [PausedUploadTransport(binding: binding, gate: gate)],
            maximumBytes: 1, allocate: { _ in try storage.allocate() })
        let worker = V2ResourceStagingCleanupWorker(persistence: persistence, service: service)
        let work = Task { try await worker.runOnce(limit: 1) }
        await gate.waitForStart()
        work.cancel()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(await gate.finished)
        #expect(await persistence.completions == 0)
        #expect(await persistence.retries == 0)
    }
}

private actor CleanupLease: V2ResourceStagingCleanupPersistence {
    let value: V2ResourceStagingCleanupClaim
    var claimed = false
    private(set) var completions = 0
    private(set) var retries = 0
    init(_ value: V2ResourceStagingCleanupClaim) { self.value = value }
    func claim(limit: Int) -> [V2ResourceStagingCleanupClaim] { guard !claimed else { return [] }; claimed = true; return [value] }
    func complete(_ claim: V2ResourceStagingCleanupClaim) { completions += 1 }
    func retry(_ claim: V2ResourceStagingCleanupClaim) { retries += 1 }
}

private actor PausedCleanup {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var finished = false
    func run() async throws {
        started = true; waiter?.resume(); waiter = nil
        defer { finished = true }
        try await Task.sleep(for: .seconds(60))
    }
    func waitForStart() async {
        if !started { await withCheckedContinuation { waiter = $0 } }
    }
}

private struct PausedUploadTransport: V2UploadTransport {
    let binding: V2StorageBinding
    let gate: PausedCleanup
    let capabilities = V2ResourceTransportCapabilities(modes: [.httpPut], maximumBytes: 1)
    func abort(mediaID: MediaID) async throws { try await gate.run() }
    func plan(mode: V2ResourceTransferMode, mediaID: MediaID, contentType: String, byteCount: Int64,
              checksum: V2ResourceChecksum, expiresAt: Date) async throws -> V2ResourceTransferPlan { throw V2ResourceProviderError.unsupportedCapability }
    func completedBytes(mediaID: MediaID, byteCount: Int64) async throws -> V2ResourceByteStream { throw V2ResourceProviderError.unsupportedCapability }
    func importBytes(mediaID: MediaID, contentType: String, byteCount: Int64, bytes: V2ResourceByteStream) async throws { throw V2ResourceProviderError.unsupportedCapability }
}

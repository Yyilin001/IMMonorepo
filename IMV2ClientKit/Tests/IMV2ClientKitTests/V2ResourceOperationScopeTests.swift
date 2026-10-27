import Foundation
import IMV2Core
import Synchronization
import Testing
@testable import IMV2ClientKit

@Suite("Account resource task ownership", .timeLimit(.minutes(1)))
struct V2ResourceOperationScopeTests {
    @Test("close drains cleanup for a produced value rejected by cancellation")
    func cancellationCleanupIsInsideTheCloseBoundary() async throws {
        let scope = V2ResourceOperationScope(limit: 1), producer = ScopeGate(), cleanup = ScopeGate()
        let finished = Mutex(false)
        let request = Task {
            try await scope.run(onCancelledValue: { value in
                #expect(value == 7)
                await cleanup.wait()
            }) { await producer.wait(); return 7 }
        }
        await producer.entered()
        let close = Task { await scope.close(); finished.withLock { $0 = true } }
        await producer.cancelled()
        await producer.release()
        await cleanup.entered()
        #expect(await scope.activeCount() == 1)
        #expect(!finished.withLock { $0 })
        await cleanup.release()
        await close.value
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(await scope.activeCount() == 0)
        #expect(finished.withLock { $0 })
    }

    @Test func callerCancellationRetainsCapacityUntilActualCompletion() async throws {
        let scope = V2ResourceOperationScope(limit: 1), gate = ScopeGate()
        let request = Task { try await scope.run { await gate.wait(); return 1 } }
        await gate.entered()
        await #expect(throws: V2ResourceOperationScopeError.busy) { try await scope.run { 2 } }
        request.cancel()
        await gate.cancelled()
        #expect(await scope.activeCount() == 1)
        await #expect(throws: V2ResourceOperationScopeError.busy) { try await scope.run { 3 } }
        await gate.release()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(try await scope.run { 4 } == 4)
        await scope.close()
    }

    @Test func simultaneousCloseWaitsForNonCooperativeWorkAndRejectsNewWork() async throws {
        let scope = V2ResourceOperationScope(), gate = ScopeGate()
        let finished = Mutex(0)
        let request = Task { try await scope.run { await gate.wait(); return 1 } }
        await gate.entered()
        let first = Task { await scope.close(); finished.withLock { $0 += 1 } }
        await gate.cancelled()
        let second = Task { await scope.close(); finished.withLock { $0 += 1 } }
        await #expect(throws: CancellationError.self) { try await scope.run { 2 } }
        #expect(finished.withLock { $0 } == 0)
        await gate.release()
        await first.value; await second.value
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(finished.withLock { $0 } == 2)
        await scope.close()
    }

    @Test func failedAndAlreadyCancelledAdmissionsDoNotConsumeCapacity() async throws {
        let scope = V2ResourceOperationScope(limit: 1)
        await #expect(throws: V2ResourceJournalError.conflict) {
            try await scope.run { throw V2ResourceJournalError.conflict }
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await scope.run { Issue.record("cancelled work started"); return 1 }
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await scope.run { 2 } == 2)
        await scope.close()
    }

    @Test("engine closure also drains capability reads and remote cancellation", arguments: [false, true])
    func engineControlDrain(capability: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appendingPathComponent("db.sqlite"), installationBinding: .init(value: UUID()), userID: .init(uuid: UUID()))
        let gate = ScopeGate(), control = ScopeResourceControl(gate: gate)
        let resources = try await makeResourceTestCenter(store: store, root: directory)
        let engine = V2ResourceTransferEngine(store: store, control: control, executor: ScopeExecutor(), resources: resources,
            capabilities: .init(reader: control))
        let id = UUID()
        let request = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()),
            usage: .userAvatar, contentType: "image/png", byteCount: 3, checksum: .init(value: String(repeating: "a", count: 64)))
        try await store.seedMetadataResourceAsset(.init(id), request: request)
        _ = try await engine.prepare(id: id, request: request, localAssetID: .init(id))
        let work = Task {
            if capability { try await engine.refreshCapabilitiesIfNeeded() }
            else {
                try await engine.cancel(id: id)
                #expect(try await store.resourceTransfer(id: id)?.cancellationRequested == true)
                _ = try await engine.resume(id: id)
            }
        }
        await gate.entered()
        let finished = Mutex(false)
        let close = Task { await engine.close(); finished.withLock { $0 = true } }
        await gate.cancelled()
        #expect(!finished.withLock { $0 })
        await #expect(throws: CancellationError.self) { _ = try await engine.prepare(id: UUID(), request: request, localAssetID: .init(id)) }
        await gate.release()
        await close.value
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(await control.cancelCalls == 0)
        let job = try #require(try await store.resourceTransfer(id: id))
        #expect(job.session == nil)
        #expect(job.cancellationRequested == !capability)
        await resources.close(); try await store.close()
        await #expect(throws: CancellationError.self) { try await engine.cancel(id: id) }
        await #expect(throws: CancellationError.self) { try await engine.releaseFinishedSources() }
    }
}

private actor ScopeGate {
    private let starts = AsyncStream<Void>.makeStream()
    private let cancellations = AsyncStream<Void>.makeStream()
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation {
                continuation = $0
                starts.continuation.yield(())
            }
        } onCancel: { cancellations.continuation.yield(()) }
    }
    func entered() async { var iterator = starts.stream.makeAsyncIterator(); _ = await iterator.next() }
    func cancelled() async { var iterator = cancellations.stream.makeAsyncIterator(); _ = await iterator.next() }
    func release() { continuation?.resume(); continuation = nil }
}

private actor ScopeResourceControl: V2ResourceUploadControlling, V2ResourceCapabilityReading {
    let gate: ScopeGate
    private(set) var cancelCalls = 0
    init(gate: ScopeGate) { self.gate = gate }
    func capabilities() async throws -> V2ResourceCapabilities {
        await gate.wait()
        return try .init(uploadModes: [.httpPut], maximumBytes: 4096, allowedUsages: [.userAvatar], maximumParts: 0, backgroundTransfer: false)
    }
    func create(_ request: V2ResourceUploadRequest) async throws -> V2ResourceUploadSession {
        await gate.wait()
        return try .init(locator: .init(home: .account(.init(uuid: UUID())), sessionID: .init(uuid: UUID())),
            mediaID: request.mediaID, generation: 1, state: .created, resourceState: .pending, expiresAt: Date().addingTimeInterval(60))
    }
    func status(_ locator: V2ResourceUploadLocator) throws -> V2ResourceUploadSession { throw CancellationError() }
    func target(_ session: V2ResourceUploadSession) throws -> V2ResourceTransferPlan? { throw CancellationError() }
    func finalize(_ session: V2ResourceUploadSession) throws -> V2ResourceUploadSession { throw CancellationError() }
    func cancel(_ session: V2ResourceUploadSession) -> V2ResourceUploadSession { cancelCalls += 1; return session }
}

private struct ScopeExecutor: V2ResourcePlanExecuting {
    func upload(fileURL: URL, plan: V2ResourceTransferPlan) throws { throw CancellationError() }
}

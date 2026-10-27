import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Native session setup belongs to account close", .timeLimit(.minutes(1)))
struct V2BackgroundSessionSetupTests {
    @Test func closeDrainsAnIgnoringSDKAndClosesItsLateSuccessfulResult() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "native-setup-close-\(UUID())")
        let store = try GRDBV2LocalSyncStore(databaseURL: root.appending(path: "V2.sqlite"), installationBinding: .init(value: UUID()), userID: .init(uuid: UUID()))
        let center = try await makeResourceTestCenter(store: store, root: root)
        let gate = SetupGate(), result = SetupResult(), closed = SetupResult()
        let setup = Task {
            try await center.withBackgroundSetup(onCancelledValue: { await $0.close() }) { _, _ in
                await gate.waitIgnoringCancellation()
                return result
            }
        }
        await gate.entered()
        let closing = Task { await center.close(); await closed.close() }
        while true {
            do { _ = try await center.storageSnapshot() }
            catch V2ResourceStorageError.closed { break }
            await Task.yield()
        }
        #expect(await closed.isClosed == false)
        #expect(await result.isClosed == false)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await setup.value }
        await closing.value
        #expect(await result.isClosed)
        #expect(await closed.isClosed)
        try await store.close(); try FileManager.default.removeItem(at: root)
    }

    @Test func closedAccountNeverInvokesANewSessionFactory() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "native-setup-reject-\(UUID())")
        let store = try GRDBV2LocalSyncStore(databaseURL: root.appending(path: "V2.sqlite"), installationBinding: .init(value: UUID()), userID: .init(uuid: UUID()))
        let center = try await makeResourceTestCenter(store: store, root: root), touched = SetupResult()
        await center.close()
        await #expect(throws: V2ResourceStorageError.closed) {
            try await center.withBackgroundSetup(onCancelledValue: { await $0.close() }) { _, _ in
                await touched.close(); return touched
            }
        }
        #expect(await touched.isClosed == false)
        try await store.close(); try FileManager.default.removeItem(at: root)
    }

    private actor SetupResult {
        private(set) var isClosed = false
        func close() { isClosed = true }
    }
    private actor SetupGate {
        let starts = AsyncStream<Void>.makeStream()
        var continuation: CheckedContinuation<Void, Never>?
        func waitIgnoringCancellation() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                starts.continuation.yield(())
            }
        }
        func entered() async { var iterator = starts.stream.makeAsyncIterator(); _ = await iterator.next() }
        func release() { continuation?.resume(); continuation = nil }
    }
}

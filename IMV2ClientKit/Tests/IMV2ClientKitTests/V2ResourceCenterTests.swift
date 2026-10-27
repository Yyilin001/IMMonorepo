import Foundation
import Crypto
import GRDB
import Synchronization
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Account resource snapshot coordinator", .timeLimit(.minutes(1)))
struct V2ResourceCenterTests {
    @MainActor @Test func cancellationBetweenCacheFilesStopsFurtherDeletion() async throws {
        let f = try await MaintenanceFixture.make()
        let request = MaintenanceCancellationHandle()
        try await f.store.databasePool.write { db in
            db.add(function: DatabaseFunction("cancel_resource_maintenance", argumentCount: 0) { _ in
                request.cancel(); return 1
            })
            try db.execute(sql: "CREATE TABLE maintenance_deletions(file_id TEXT NOT NULL)")
            try db.execute(sql: "CREATE TRIGGER record_maintenance_deletion AFTER DELETE ON v2_resource_files BEGIN INSERT INTO maintenance_deletions VALUES(OLD.file_id); SELECT cancel_resource_maintenance(); END")
        }
        let task = Task { try await f.center.maintainCache(now: f.future) }
        request.install(task)
        await #expect(throws: CancellationError.self) { try await task.value }
        request.clear()
        let journal = await f.store.resourceFileJournal()
        #expect(try journal.records().count == 2)
        #expect(try await f.store.databasePool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM maintenance_deletions") } == 1)
        for record in try journal.records() {
            let use = try await f.center.files.borrow(record.id)
            #expect(f.sources.map { $0.1 }.contains(try Data(contentsOf: use.fileURL)))
            await use.release()
        }
        try await f.center.maintainCache(now: f.future)
        #expect(try journal.records().isEmpty)
        #expect(try await f.store.databasePool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM maintenance_deletions") } == 3)
        for (source, bytes) in f.sources { #expect(try Data(contentsOf: source) == bytes) }
        await f.close()
    }

    @MainActor @Test func optionalMaintenanceSkipsBusyAdmissionAndCanRunAfterWorkDrains() async throws {
        let f = try await MaintenanceFixture.make(), gate = MaintenanceAdmissionGate()
        let deadline = ContinuousClock.now + .seconds(5)
        let holds = (0..<4).map { _ in
            Task {
                while ContinuousClock.now < deadline {
                    do {
                        try await f.center.withBackgroundSetup(onCancelledValue: { _ in }) { _, _ in await gate.hold() }
                        return
                    } catch V2ResourceOperationScopeError.busy { await Task.yield() }
                }
                throw V2ResourceOperationScopeError.busy
            }
        }
        while await gate.count < 4, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await gate.count == 4)
        do { try await f.center.maintainCache(now: f.future) }
        catch { Issue.record(error) }
        let journal = await f.store.resourceFileJournal()
        #expect(try journal.records().count == 3)
        for record in try journal.records() {
            let use = try await f.center.files.borrow(record.id)
            #expect(f.sources.map { $0.1 }.contains(try Data(contentsOf: use.fileURL)))
            await use.release()
        }
        await gate.release()
        for hold in holds {
            do { try await hold.value } catch { Issue.record(error) }
        }
        try await f.center.maintainCache(now: f.future)
        #expect(try journal.records().isEmpty)
        await f.close()
    }

    @MainActor @Test func cancelledCacheMaintenanceLeavesBytesForANewCaller() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "resource-maintenance-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UserID(uuid: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "V2.sqlite"),
            installationBinding: .init(value: UUID()), userID: user)
        let scope = V2AccountStorageScope(incarnation: UUID(), accountID: user, directory: directory,
            cacheDirectory: directory.appending(path: "cache-scope"))
        let center = try await V2ResourceCenter.make(scope: scope, store: store)
        let bytes = Data("maintenance bytes".utf8), source = directory.appending(path: "source")
        try bytes.write(to: source)
        let checksum = try V2ResourceChecksum(value: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let file = try await center.files.publishCopy(of: source, byteCount: Int64(bytes.count), checksum: checksum, retention: .cache)
        let journal = await store.resourceFileJournal()
        let future = Date().addingTimeInterval(8 * 24 * 60 * 60)
        // MainActor ownership guarantees cancellation before this child starts.
        let cancelled = Task { try await center.maintainCache(now: future) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try journal.record(file) != nil)
        if try journal.record(file) != nil {
            let use = try await center.files.borrow(file)
            #expect(try Data(contentsOf: use.fileURL) == bytes)
            await use.release()
        }
        try await center.maintainCache(now: future)
        #expect(try journal.record(file) == nil)
        await center.close(); try await store.close()
    }

    @Test func directoryStartsLocallyAndObservesCommittedMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resource-center-\(UUID())")
        let user = UserID(uuid: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appendingPathComponent("V2.sqlite"),
            installationBinding: .init(value: UUID()), userID: user)
        let scope = V2AccountStorageScope(incarnation: UUID(), accountID: user, directory: directory, cacheDirectory: directory.appending(path: "cache-scope"))
        let center = try await V2ResourceCenter.make(scope: scope, store: store)
        let stream = try await center.snapshots(for: .init())
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .available(.init(entries: [], nextCursor: nil)))
        let room = RoomID(uuid: UUID())
        let descriptor = try V2ResourceDescriptor(key: .init(home: .room(room), mediaID: .init(uuid: UUID())),
            revision: 1, displayName: .init("photo.jpg"), contentType: "image/jpeg", byteCount: 32,
            checksum: .init(value: String(repeating: "a", count: 64)), state: .ready)
        try await store.indexResource(descriptor, reference: .message(.init(roomID: room, messageID: .init(uuid: UUID())), ordinal: 0), businessRevision: 1)
        guard case .available(let page) = await iterator.next() else { Issue.record("Missing committed directory snapshot"); return }
        #expect(page.entries.map(\.descriptor) == [descriptor])
        await center.close()
        #expect(await iterator.next() == nil)
        await #expect(throws: V2ResourceStorageError.closed) { try await center.snapshots(for: .init()) }
        try await store.close(); try FileManager.default.removeItem(at: directory)
    }

    @Test func incorrectAccountCannotCreateFileOwner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resource-wrong-account-\(UUID())")
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appendingPathComponent("V2.sqlite"),
            installationBinding: .init(value: UUID()), userID: .init(uuid: UUID()))
        let otherScope = V2AccountStorageScope(incarnation: UUID(), accountID: .init(uuid: UUID()), directory: directory, cacheDirectory: directory.appending(path: "cache-scope"))
        await #expect(throws: V2AccountStorageError.scopeMismatch) { try await V2ResourceCenter.make(scope: otherScope, store: store) }
        #expect(!FileManager.default.fileExists(atPath: otherScope.resourceFilesDirectory.path))
        try await store.close(); try FileManager.default.removeItem(at: directory)
    }

    @Test func progressDoesNotInvalidateConversationOrAvatarPresentation() {
        for table in ["v2_resource_transfer_jobs", "v2_resource_import_jobs", "v2_resource_download_jobs",
                      "v2_resource_entries", "v2_resource_files", "v2_resource_references"] {
            let change = V2ProjectionTransactionObserver.change(table: table, kind: .update)
            #expect(change.scopes == .resources)
            #expect(!change.scopes.contains(.presentations))
            #expect(!change.scopes.contains(.conversations))
        }
    }
}

private struct MaintenanceFixture: Sendable {
    let root: URL
    let store: GRDBV2LocalSyncStore
    let center: V2ResourceCenter
    let sources: [(URL, Data)]
    let future: Date
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appending(path: "resource-maintenance-\(UUID())")
        let user = UserID(uuid: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: root.appending(path: "V2.sqlite"), installationBinding: .init(value: UUID()), userID: user)
        let scope = V2AccountStorageScope(incarnation: UUID(), accountID: user, directory: root, cacheDirectory: root.appending(path: "cache-scope"))
        let center = try await V2ResourceCenter.make(scope: scope, store: store)
        var sources: [(URL, Data)] = []
        for number in 0..<3 {
            let data = Data("maintenance-\(number)".utf8), source = root.appending(path: "source-\(number)")
            try data.write(to: source)
            let checksum = try V2ResourceChecksum(value: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            _ = try await center.files.publishCopy(of: source, byteCount: Int64(data.count), checksum: checksum, retention: .cache)
            sources.append((source, data))
        }
        return .init(root: root, store: store, center: center, sources: sources, future: Date().addingTimeInterval(8 * 24 * 60 * 60))
    }
    func close() async {
        await center.close()
        do { try await store.close(); try FileManager.default.removeItem(at: root) }
        catch { Issue.record(error) }
    }
}

private final class MaintenanceCancellationHandle: Sendable {
    private let task = Mutex<Task<Void, any Error>?>(nil)
    func install(_ value: Task<Void, any Error>) { task.withLock { $0 = value } }
    func cancel() { task.withLock { if let task = $0 { task.cancel() } } }
    func clear() { task.withLock { $0 = nil } }
}

private actor MaintenanceAdmissionGate {
    private var waits: [AsyncStream<Void>.Continuation] = []
    var count: Int { waits.count }
    func hold() async {
        let signal = AsyncStream<Void>.makeStream()
        waits.append(signal.continuation)
        for await _ in signal.stream { }
    }
    func release() { for wait in waits { wait.finish() }; waits.removeAll() }
}

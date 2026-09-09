import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Account storage incarnation cleanup", .timeLimit(.minutes(1)))
struct V2AccountStorageScopeTests {
    @Test("primary and search databases share one exact artifact set", arguments: ["V2.sqlite", "sync.sqlite", "test-scope.sqlite"])
    func companionArtifacts(name: String) {
        let artifacts = V2LocalDatabaseArtifacts(primary: URL(fileURLWithPath: "/tmp/isolated/" + name))
        #expect(artifacts.files.count == 6)
        let expected = name == "V2.sqlite" ? "V2Search.sqlite" : String(name.dropLast(7)) + ".search.sqlite"
        #expect(artifacts.search.lastPathComponent == expected)
        #expect(Set(artifacts.files).count == 6)
    }

    @Test("cleanup deletes both databases, their sidecars, and partial derived files")
    func removesWholeIncarnationAfterClosing() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = V2AccountStorageDirectory(root: root)
        let scope = try await catalog.openScope(accountID: .init("account-a"))
        let store = try GRDBV2LocalSyncStore(databaseURL: scope.database.primary, installationBinding: .init(value: UUID()))
        try await store.messageSearchDatabasePool.write { db in
            try db.execute(sql: "CREATE TABLE erase_probe (body TEXT)")
            try db.execute(sql: "INSERT INTO erase_probe VALUES ('old private body')")
        }
        let partial = scope.directory.appending(path: "download.partial")
        try Data("partial body".utf8).write(to: partial)
        try await catalog.retire(scope)
        try await catalog.completeCleanup(scope) { try await store.close() }
        #expect(!FileManager.default.fileExists(atPath: scope.directory.path))
        await #expect(throws: DatabaseError.self) { _ = try await store.cursor() }
        await #expect(throws: DatabaseError.self) {
            try await store.messageSearchDatabasePool.write { db in try db.execute(sql: "INSERT INTO erase_probe VALUES ('late old write')") }
        }
        #expect(!FileManager.default.fileExists(atPath: scope.directory.path))
    }

    @Test("an active indexer and observer drain before both pools are erased")
    func indexerAndObservationShutdown() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = V2AccountStorageDirectory(root: root)
        let scope = try await catalog.openScope(accountID: .init("account-a"))
        let store = try GRDBV2LocalSyncStore(databaseURL: scope.database.primary, installationBinding: .init(value: UUID()))
        let updates = store.messageSearchIndexUpdates()
        let observer = Task {
            for try await _ in updates { try Task.checkCancellation() }
        }
        let indexer = Task { try await store.runMessageSearchIndexer() }
        var iterator = store.messageSearchIndexUpdates().makeAsyncIterator()
        while let snapshot = try await iterator.next(), snapshot.state != .ready {}
        try await catalog.retire(scope)
        indexer.cancel()
        observer.cancel()
        _ = await indexer.result
        _ = await observer.result
        try await catalog.completeCleanup(scope) { try await store.close() }
        try await catalog.completeCleanup(scope) { Issue.record("completed cleanup must not close again") }
        #expect(!FileManager.default.fileExists(atPath: scope.directory.path))
        await #expect(throws: DatabaseError.self) { try await store.prepareMessageSearchIndex() }
    }

    @Test("failed close retains the marker and files until process restart")
    func failedClosePreservesCleanupIntent() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = V2AccountStorageDirectory(root: root)
        let scope = try await catalog.openScope(accountID: .init("account-a"))
        try Data("private body".utf8).write(to: scope.database.search)
        try await catalog.retire(scope)
        await #expect(throws: CleanupFailure.closeFailed) {
            try await catalog.completeCleanup(scope) { throw CleanupFailure.closeFailed }
        }
        #expect(FileManager.default.fileExists(atPath: scope.database.search.path))
        let restarted = V2AccountStorageDirectory(root: root)
        let replacement = try await restarted.openScope(accountID: .init("account-a"))
        #expect(replacement.incarnation != scope.incarnation)
        #expect(!FileManager.default.fileExists(atPath: scope.directory.path))
    }

    @Test("restart handles each committed cleanup boundary", arguments: [0, 1, 2])
    func resumesEachDeletionBoundary(step: Int) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = V2AccountStorageDirectory(root: root)
        let scope = try await catalog.openScope(accountID: .init("account-a"))
        let active = root.appending(path: "active.json")
        let originalActive = try Data(contentsOf: active)
        try Data("search body".utf8).write(to: scope.database.search)
        try await catalog.retire(scope)
        if step == 0 { try originalActive.write(to: active, options: .atomic) }
        if step == 2 { try FileManager.default.removeItem(at: scope.directory) }
        let restarted = V2AccountStorageDirectory(root: root)
        try await restarted.resumeCleanupBeforeOpeningStores()
        let newScope = try await restarted.openScope(accountID: .init("account-b"))
        #expect(newScope.incarnation != scope.incarnation)
        #expect(!FileManager.default.fileExists(atPath: scope.directory.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "retired").path).isEmpty)
    }

    @Test("A to B to A cannot let delayed first-A cleanup delete the new A")
    func delayedCleanupCannotDeleteReplacementAccount() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = V2AccountStorageDirectory(root: root)
        let firstA = try await catalog.openScope(accountID: .init("account-a"))
        try await catalog.retire(firstA)
        let gate = CleanupCloseGate()
        let cleanup = Task { try await catalog.completeCleanup(firstA) { await gate.close() } }
        await gate.waitForClose()
        let b = try await catalog.openScope(accountID: .init("account-b"))
        try await catalog.retire(b)
        try await catalog.completeCleanup(b) {}
        let newA = try await catalog.openScope(accountID: .init("account-a"))
        try Data("new private body".utf8).write(to: newA.database.search)
        await gate.release()
        try await cleanup.value
        #expect(try Data(contentsOf: newA.database.search) == Data("new private body".utf8))
        #expect(!FileManager.default.fileExists(atPath: firstA.directory.path))
        #expect(try await catalog.openScope(accountID: .init("account-a")) == newA)
    }

    @Test("account switching requires explicit retirement and runtime recovery cannot erase open stores")
    func cannotSilentlyEraseUnsentAccountData() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = V2AccountStorageDirectory(root: root)
        _ = try await catalog.openScope(accountID: .init("account-a"))
        await #expect(throws: V2AccountStorageError.cleanupRequired) { _ = try await catalog.openScope(accountID: .init("account-b")) }
        await #expect(throws: V2AccountStorageError.storesAlreadyOpened) { try await catalog.resumeCleanupBeforeOpeningStores() }
    }

    @Test("malformed retired metadata fails closed and cannot select a filesystem path")
    func invalidMarkerDoesNotDeleteOtherDirectories() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = V2AccountStorageDirectory(root: root)
        let scope = try await catalog.openScope(accountID: .init("account-a"))
        try Data("preserve".utf8).write(to: scope.database.search)
        let marker = root.appending(path: "retired/invalid.json")
        try Data("{\"directory\":\"../\"}".utf8).write(to: marker)
        let restarted = V2AccountStorageDirectory(root: root)
        await #expect(throws: V2AccountStorageError.invalidManifest) { try await restarted.resumeCleanupBeforeOpeningStores() }
        #expect(FileManager.default.fileExists(atPath: scope.database.search.path))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "im-storage-scope-" + UUID().uuidString, directoryHint: .isDirectory)
    }
}

private enum CleanupFailure: Error { case closeFailed }
private actor CleanupCloseGate {
    private var entered = false
    private var observer: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?
    func close() async {
        entered = true
        observer?.resume()
        observer = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func waitForClose() async {
        if entered { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

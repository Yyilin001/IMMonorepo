import Crypto
import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Account local store ownership and migration", .timeLimit(.minutes(1)))
struct V2AccountLocalStoreOwnerTests {
    @Test("legacy A outbox migrates as A even when B logs in first; global FTS is rebuilt")
    func preservesOriginalAccountDuringMigration() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let old = try await fixture.legacyStore(account: "account-a")
        let pending = try command("old-a")
        try await old.enqueue(pending)
        try await old.databasePool.write { db in try db.execute(sql: "UPDATE v2_message_search_state SET state = 'ready'") }
        try await old.messageSearchDatabasePool.write { db in try db.execute(sql: "CREATE TABLE untrusted_global_search (body TEXT)") }
        try await old.close()
        let owner = fixture.owner()
        let b = try await owner.open(accountID: .init("account-b"))
        #expect(try await b.pendingMessageCommands().isEmpty)
        let bScope = try await owner.scope(for: b)
        try await owner.close(b)
        let a = try await owner.open(accountID: .init("account-a"))
        let aScope = try await owner.scope(for: a)
        #expect(aScope.directory != bScope.directory)
        #expect(try await a.pendingMessageCommands() == [pending])
        #expect(try await a.messageSearchIndexState() == .building)
        #expect(try await a.messageSearchDatabasePool.read { db in try !db.tableExists("untrusted_global_search") })
        #expect(V2LocalDatabaseArtifacts(primary: fixture.legacyURL).files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        try await owner.close(a)
    }

    @Test("closing an old A object cannot close a new A session or erase its outbox")
    func lateCloseIsObjectScoped() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let owner = fixture.owner()
        let a = try await owner.open(accountID: .init("account-a"))
        let original = try command("first-a")
        try await a.enqueue(original)
        try await owner.close(a)
        let b = try await owner.open(accountID: .init("account-b"))
        try await owner.close(b)
        let newA = try await owner.open(accountID: .init("account-a"))
        #expect(newA !== a)
        try await owner.close(a)
        #expect(try await newA.pendingMessageCommands() == [original])
        await #expect(throws: DatabaseError.self) { try await a.enqueue(command("stale")) }
        let next = try command("new-a")
        try await newA.enqueue(next)
        #expect(try await newA.pendingMessageCommands().count == 2)
        try await owner.close(newA)
    }

    @Test("concurrent opens share one pair of pools")
    func concurrentOpenIsSingleFlight() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let owner = fixture.owner()
        let stores = try await withThrowingTaskGroup(of: GRDBV2LocalSyncStore.self) { group in
            for _ in 0..<20 { group.addTask { try await owner.open(accountID: .init("account-a")) } }
            var values: [GRDBV2LocalSyncStore] = []
            for try await store in group { values.append(store) }
            return values
        }
        let first = try #require(stores.first)
        #expect(stores.allSatisfy { $0 === first })
        try await owner.close(first)
    }

    @Test("legacy migration resumes each committed file-move prefix", arguments: [0, 1, 2])
    func migrationRestarts(step: Int) async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let account = try UserID("account-a")
        let old = try await fixture.legacyStore(account: account.rawValue)
        let pending = try command("survives-restart")
        try await old.enqueue(pending)
        try await old.requireMessageSearchIndexRebuild()
        try await old.close()
        let key = SHA256.hash(data: Data(account.rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
        let catalog = V2AccountStorageDirectory(root: fixture.root.appending(path: key))
        let scope = try await catalog.openScope(accountID: account)
        let marker = try JSONSerialization.data(withJSONObject: ["version": 1, "accountID": account.rawValue, "incarnation": scope.incarnation.uuidString])
        try marker.write(to: fixture.root.appending(path: "legacy-import.json"), options: .atomic)
        if step > 0 { try FileManager.default.moveItem(at: fixture.legacyURL, to: scope.database.primary) }
        if step == 2 {
            for file in V2LocalDatabaseArtifacts(primary: fixture.legacyURL).files.dropFirst(3) where FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
        let restarted = fixture.owner()
        let store = try await restarted.open(accountID: account)
        #expect(try await store.pendingMessageCommands() == [pending])
        #expect(try await store.messageSearchIndexState() == .building)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "legacy-import.json").path))
        try await restarted.close(store)
    }

    @Test("an unavailable installation key does not migrate or discard legacy files")
    func protectedDataFailureDoesNotErase() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let old = try await fixture.legacyStore(account: "account-a")
        try await old.close()
        await fixture.binding.setUnavailable()
        let owner = fixture.owner()
        await #expect(throws: V2LocalStoreBootstrapError.installationBindingUnavailable) { _ = try await owner.open(accountID: .init("account-a")) }
        #expect(FileManager.default.fileExists(atPath: fixture.legacyURL.path))
    }

    @Test("untrusted legacy files are discarded without leaving an unbound migration blocker")
    func missingInstallationAnchorCanStartFresh() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let old = try await fixture.legacyStore(account: "account-a")
        try await old.enqueue(command("untrusted"))
        try await old.close()
        await fixture.binding.delete()
        let owner = fixture.owner()
        let store = try await owner.open(accountID: .init("account-a"))
        #expect(try await store.pendingMessageCommands().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.legacyURL.path))
        try await owner.close(store)
    }

    private func command(_ id: String) throws -> V2PendingMessageCommand {
        try .init(roomID: .init("room"), clientMessageID: .init(id), text: id, state: .pending, attemptCount: 0,
                  nextAttemptAt: .distantPast, acceptedMessageID: nil, acceptedRoomSequence: nil, terminalCode: nil)
    }
}

private struct Fixture {
    let directory: URL
    let root: URL
    let legacyURL: URL
    let binding = OwnerBindingStore()
    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "im-account-owner-" + UUID().uuidString)
        root = directory.appending(path: "accounts")
        legacyURL = directory.appending(path: "sync.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func owner() -> V2AccountLocalStoreOwner {
        .init(root: root, legacyDatabaseURL: legacyURL, bootstrapper: .init(bindingStore: binding))
    }
    func legacyStore(account: String) async throws -> GRDBV2LocalSyncStore {
        try await V2LocalStoreBootstrapper(bindingStore: binding).open(databaseURL: legacyURL, userID: .init(account))
    }
    func removeFiles() { try? FileManager.default.removeItem(at: directory) }
}
private actor OwnerBindingStore: V2InstallationBindingStore {
    private var value: V2LocalInstallationBinding? = .init(value: UUID())
    private var unavailable = false
    func load() throws -> V2LocalInstallationBinding? {
        if unavailable { throw V2InstallationBindingStoreError.unavailable }
        return value
    }
    func save(_ binding: V2LocalInstallationBinding) { value = binding }
    func delete() { value = nil }
    func setUnavailable() { unavailable = true }
}

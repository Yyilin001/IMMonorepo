import Crypto
import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Account local store ownership", .timeLimit(.minutes(1)))
struct V2AccountLocalStoreOwnerTests {
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

    @Test("an unavailable installation key fails open without creating an account store")
    func protectedDataFailureDoesNotOpen() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        await fixture.binding.setUnavailable()
        let owner = fixture.owner()
        await #expect(throws: V2LocalStoreBootstrapError.installationBindingUnavailable) { _ = try await owner.open(accountID: .init("account-a")) }
    }

    @Test("accounts open isolated directories and the root is excluded from backup")
    func accountsAreIsolated() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let owner = fixture.owner()
        let a = try await owner.open(accountID: .init("account-a"))
        let pending = try command("only-a")
        try await a.enqueue(pending)
        let aScope = try await owner.scope(for: a)
        try await owner.close(a)
        let b = try await owner.open(accountID: .init("account-b"))
        #expect(try await b.pendingMessageCommands().isEmpty)
        #expect(try await owner.scope(for: b).directory != aScope.directory)
        #expect(try fixture.root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        try await owner.close(b)
    }

    private func command(_ id: String) throws -> V2PendingMessageCommand {
        try .init(roomID: .init("room"), clientMessageID: .init(id), text: id, state: .pending, attemptCount: 0,
                  nextAttemptAt: .distantPast, acceptedMessageID: nil, acceptedRoomSequence: nil, terminalCode: nil)
    }
}

private struct Fixture {
    let directory: URL
    let root: URL
    let binding = OwnerBindingStore()
    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "im-account-owner-" + UUID().uuidString)
        root = directory.appending(path: "accounts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func owner() -> V2AccountLocalStoreOwner {
        .init(root: root, bootstrapper: .init(bindingStore: binding))
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

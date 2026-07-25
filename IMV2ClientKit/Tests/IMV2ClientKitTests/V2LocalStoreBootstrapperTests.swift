import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 local-store installation binding")
struct V2LocalStoreBootstrapperTests {
    @Test("a database without its device-only binding is discarded before opening")
    func missingBindingDiscardsImportedDatabase() async throws {
        let url = temporaryBootstrapDatabaseURL()
        try await persistPendingCommand(in: url, binding: .init(value: UUID(uuidString: "00000000-0000-0000-0000-000000000601")!))
        let bindingStore = InMemoryInstallationBindingStore()
        let replacement = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000602")!)
        let bootstrapper = V2LocalStoreBootstrapper(bindingStore: bindingStore, makeBinding: { replacement })

        let store = try await bootstrapper.open(databaseURL: url)

        #expect(try await store.pendingMessageCommands().isEmpty)
        #expect(try await bindingStore.load() == replacement)
    }

    @Test("an existing device binding rejects a copied database with another binding")
    func mismatchedBindingDiscardsImportedDatabase() async throws {
        let url = temporaryBootstrapDatabaseURL()
        try await persistPendingCommand(in: url, binding: .init(value: UUID(uuidString: "00000000-0000-0000-0000-000000000603")!))
        let trusted = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000604")!)
        let bindingStore = InMemoryInstallationBindingStore(binding: trusted)
        let bootstrapper = V2LocalStoreBootstrapper(bindingStore: bindingStore)

        let store = try await bootstrapper.open(databaseURL: url)

        #expect(try await store.pendingMessageCommands().isEmpty)
        #expect(try await bindingStore.load() == trusted)
    }

    @Test("the same installation binding preserves a local outbox across reopen")
    func matchingBindingPreservesDatabase() async throws {
        let url = temporaryBootstrapDatabaseURL()
        let binding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000605")!)
        let bindingStore = InMemoryInstallationBindingStore()
        let bootstrapper = V2LocalStoreBootstrapper(bindingStore: bindingStore, makeBinding: { binding })
        let first = try await bootstrapper.open(databaseURL: url)
        let command = try V2PendingMessageCommand(
            roomID: .init("00000000-0000-0000-0000-000000000606"),
            clientMessageID: .init("00000000-0000-0000-0000-000000000607"),
            text: "device-local",
            state: .pending,
            attemptCount: 0,
            nextAttemptAt: .distantPast,
            acceptedMessageID: nil,
            acceptedRoomSequence: nil,
            terminalCode: nil
        )
        try await first.enqueue(command)

        let reopened = try await bootstrapper.open(databaseURL: url)

        #expect(try await reopened.pendingMessageCommands() == [command])
    }

    @Test("temporary Keychain unavailability leaves the database untouched")
    func unavailableBindingDoesNotResetDatabase() async throws {
        let url = temporaryBootstrapDatabaseURL()
        try await persistPendingCommand(in: url, binding: .init(value: UUID(uuidString: "00000000-0000-0000-0000-000000000608")!))
        let bindingStore = InMemoryInstallationBindingStore(loadError: .unavailable)
        let bootstrapper = V2LocalStoreBootstrapper(bindingStore: bindingStore)

        await #expect(throws: V2LocalStoreBootstrapError.installationBindingUnavailable) {
            _ = try await bootstrapper.open(databaseURL: url)
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    private func persistPendingCommand(in url: URL, binding: V2LocalInstallationBinding) async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        try await store.enqueue(try .init(
            roomID: .init("00000000-0000-0000-0000-000000000609"),
            clientMessageID: .init("00000000-0000-0000-0000-000000000610"),
            text: "untrusted",
            state: .pending,
            attemptCount: 0,
            nextAttemptAt: .distantPast,
            acceptedMessageID: nil,
            acceptedRoomSequence: nil,
            terminalCode: nil
        ))
    }
}

private actor InMemoryInstallationBindingStore: V2InstallationBindingStore {
    private var binding: V2LocalInstallationBinding?
    private let loadError: V2InstallationBindingStoreError?

    init(binding: V2LocalInstallationBinding? = nil, loadError: V2InstallationBindingStoreError? = nil) {
        self.binding = binding
        self.loadError = loadError
    }

    func load() throws -> V2LocalInstallationBinding? {
        if let loadError { throw loadError }
        return binding
    }

    func save(_ binding: V2LocalInstallationBinding) { self.binding = binding }
    func delete() { binding = nil }
}

private func temporaryBootstrapDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "im-v2-bootstrap-\(UUID().uuidString).sqlite")
}

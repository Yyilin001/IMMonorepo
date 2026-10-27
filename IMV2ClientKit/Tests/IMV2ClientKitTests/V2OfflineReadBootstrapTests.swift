import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("V2 offline local read trust")
struct V2OfflineReadBootstrapTests {
    @Test("expired credentials and pending refresh identify existing local data without network or credential writes")
    func expiredLocalIdentity() async throws {
        let fixture = try await OfflineReadFixture.make()
        defer { fixture.removeFiles() }
        let permit = try await fixture.bootstrap.localReadBootstrap(isLocalExitPending: { false })
        #expect(permit.identity.userID == fixture.credentials.userID)
        #expect(await fixture.transport.calls == 0)
        #expect(await fixture.store.writes == 0)
        #expect(await fixture.bindings.writes == 0)
        #expect(try await fixture.auth.restoreState() == .authenticated(accessTokenExpiresAt: .distantPast))
        try await fixture.bootstrap.requireLocalReadBootstrap(permit, isLocalExitPending: { false })
    }

    @Test("pending exit and revocation deny local bootstrap without clearing records")
    func exitMarkersFailClosed() async throws {
        let fixture = try await OfflineReadFixture.make(revoking: true)
        defer { fixture.removeFiles() }
        await #expect(throws: V2OfflineReadBootstrapError.localExitPending) {
            try await fixture.bootstrap.localReadBootstrap(isLocalExitPending: { true })
        }
        await #expect(throws: V2AuthSessionError.unauthenticated) {
            try await fixture.bootstrap.localReadBootstrap(isLocalExitPending: { false })
        }
        #expect(await fixture.store.writes == 0)
        #expect(await fixture.transport.calls == 0)
    }

    @Test("missing or mismatched installation anchors preserve existing database bytes")
    func badBindingPreservesData() async throws {
        let fixture = try await OfflineReadFixture.make()
        defer { fixture.removeFiles() }
        let bytes = try Data(contentsOf: fixture.url)
        await fixture.bindings.set(.init(value: UUID()))
        await #expect(throws: V2OfflineReadBootstrapError.installationBindingMismatch) {
            try await fixture.bootstrap.localReadBootstrap(isLocalExitPending: { false })
        }
        #expect(try Data(contentsOf: fixture.url) == bytes)
        await fixture.bindings.set(nil)
        await #expect(throws: V2OfflineReadBootstrapError.installationBindingMismatch) {
            try await fixture.bootstrap.localReadBootstrap(isLocalExitPending: { false })
        }
        #expect(await fixture.bindings.writes == 0)
        #expect(try Data(contentsOf: fixture.url) == bytes)
    }

    @Test("locked binding and an exit committed during bootstrap are rejected")
    func unavailableAndConcurrentExit() async throws {
        let fixture = try await OfflineReadFixture.make()
        defer { fixture.removeFiles() }
        let bytes = try Data(contentsOf: fixture.url)
        await fixture.bindings.setFailure(.unavailable)
        await #expect(throws: V2OfflineReadBootstrapError.installationBindingUnavailable) {
            try await fixture.bootstrap.localReadBootstrap(isLocalExitPending: { false })
        }
        await fixture.bindings.setFailure(nil)
        let marker = OfflineReadExitMarker()
        await #expect(throws: V2OfflineReadBootstrapError.localExitPending) {
            try await fixture.bootstrap.localReadBootstrap(isLocalExitPending: { await marker.isPending() })
        }
        #expect(try Data(contentsOf: fixture.url) == bytes)
        #expect(await fixture.bindings.writes == 0)
        #expect(await fixture.store.writes == 0)
    }

    @Test("read-only session preserves schema and physically rejects mutations")
    func readOnlyStoreRejectsWrites() async throws {
        let fixture = try await OfflineReadFixture.make()
        defer { fixture.removeFiles() }
        let before = try Data(contentsOf: fixture.url)
        let permit = try await fixture.bootstrap.localReadBootstrap(isLocalExitPending: { false })
        let readonly = try await fixture.bootstrap.openLocalReadSession(permit, isLocalExitPending: { false })
        #expect(try await readonly.boundAccountID() == fixture.credentials.userID)
        await #expect(throws: (any Error).self) {
            try await readonly.databasePool.write { db in
                try db.execute(sql: "UPDATE v2_local_installation SET user_id = 'foreign' WHERE singleton = 1")
            }
        }
        try await fixture.bootstrap.closeLocalStore(readonly)
        #expect(try Data(contentsOf: fixture.url) == before)
    }

    @Test("account owner closes the read-only instance before writable upgrade")
    func accountOwnedUpgradeDrainsReadonly() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "offline-owner-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = try V2AuthCredentials(userID: .init("offline-owner"), deviceID: .init("offline-device"),
            accessToken: "synthetic-access", accessTokenExpiresAt: .distantFuture, refreshCredential: "synthetic-refresh")
        let records = OfflineReadCredentialStore(record: .init(credentials: credentials))
        let auth = V2AuthSession(credentialStore: records, transport: OfflineReadTransport())
        let bootstrap = V2ClientSessionBootstrapper(authSession: auth, localStoreBootstrapper: .init(bindingStore: OfflineReadBindingStore(binding: .init(value: UUID()))),
            databaseURL: root.appending(path: "V2.sqlite"), accountStorageRoots: .init(persistent: root.appending(path: "accounts"), cache: root.appending(path: "caches")))
        let first = try await bootstrap.openEstablishedSession()
        try await bootstrap.closeLocalStore(first)
        let permit = try await bootstrap.localReadBootstrap(isLocalExitPending: { false })
        let readonly = try await bootstrap.openLocalReadSession(permit, isLocalExitPending: { false })
        let writable = try await bootstrap.openEstablishedSession()
        #expect(readonly !== writable)
        await #expect(throws: (any Error).self) { _ = try await readonly.boundAccountID() }
        try await writable.databasePool.write { db in try db.execute(sql: "UPDATE v2_local_installation SET user_id = user_id") }
        try await bootstrap.closeLocalStore(writable)
    }

    @Test("account replacement invalidates a previously issued local read context")
    func replacementInvalidatesPermit() async throws {
        let fixture = try await OfflineReadFixture.make()
        defer { fixture.removeFiles() }
        let permit = try await fixture.bootstrap.localReadBootstrap(isLocalExitPending: { false })
        try await fixture.auth.establish(try .init(userID: .init("replacement"), deviceID: .init("replacement-device"),
            accessToken: "synthetic-access", accessTokenExpiresAt: .distantFuture, refreshCredential: "synthetic-refresh"))
        await #expect(throws: V2AuthSessionError.sessionInvalidated) {
            try await fixture.bootstrap.requireLocalReadBootstrap(permit, isLocalExitPending: { false })
        }
        #expect(await fixture.transport.calls == 0)
    }
}

private struct OfflineReadFixture: Sendable {
    let url: URL
    let credentials: V2AuthCredentials
    let store: OfflineReadCredentialStore
    let bindings: OfflineReadBindingStore
    let transport: OfflineReadTransport
    let auth: V2AuthSession
    let bootstrap: V2ClientSessionBootstrapper
    static func make(revoking: Bool = false) async throws -> Self {
        let url = FileManager.default.temporaryDirectory.appending(path: "offline-read-" + UUID().uuidString).appending(path: "V2.sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let credentials = try V2AuthCredentials(userID: .init("offline-account"), deviceID: .init("offline-device"),
            accessToken: "synthetic-access", accessTokenExpiresAt: .distantPast, refreshCredential: "synthetic-refresh")
        let local = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: credentials.userID)
        try await local.close()
        let record = V2AuthCredentialRecord(credentials: credentials, pendingRefreshOperationID: UUID(),
            pendingRevocationOperationID: revoking ? UUID() : nil)
        let store = OfflineReadCredentialStore(record: record)
        let bindings = OfflineReadBindingStore(binding: binding)
        let transport = OfflineReadTransport()
        let auth = V2AuthSession(credentialStore: store, transport: transport)
        return .init(url: url, credentials: credentials, store: store, bindings: bindings, transport: transport, auth: auth,
            bootstrap: .init(authSession: auth, localStoreBootstrapper: .init(bindingStore: bindings), databaseURL: url))
    }
    func removeFiles() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}
private actor OfflineReadCredentialStore: V2CredentialStore {
    var record: V2AuthCredentialRecord
    var writes = 0
    init(record: V2AuthCredentialRecord) { self.record = record }
    func load() -> V2AuthCredentialRecord? { record }
    func save(_ record: V2AuthCredentialRecord) { writes += 1; self.record = record }
    func delete() { writes += 1 }
}
private actor OfflineReadBindingStore: V2InstallationBindingStore {
    var binding: V2LocalInstallationBinding?
    var failure: V2InstallationBindingStoreError?
    var writes = 0
    init(binding: V2LocalInstallationBinding) { self.binding = binding }
    func set(_ binding: V2LocalInstallationBinding?) { self.binding = binding }
    func setFailure(_ failure: V2InstallationBindingStoreError?) { self.failure = failure }
    func load() throws -> V2LocalInstallationBinding? { if let failure { throw failure }; return binding }
    func save(_ binding: V2LocalInstallationBinding) { writes += 1 }
    func delete() { writes += 1 }
}
private actor OfflineReadTransport: V2AuthTransport {
    var calls = 0
    func refresh(_ request: V2RefreshRequest) throws -> V2AuthCredentials {
        calls += 1
        throw V2AuthSessionError.credentialsUnavailable
    }
}

private actor OfflineReadExitMarker {
    var checks = 0
    func isPending() -> Bool { checks += 1; return checks > 1 }
}

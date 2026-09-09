import Foundation
import IMV2ClientKit
import IMV2Core
import Security
import Testing
@testable import IMApp

@Suite("Device revocation Keychain handoff", .timeLimit(.minutes(1)))
struct V2DeviceRevocationKeychainTests {
    @MainActor
    @Test("cold App reconciles pre-request Keychain proofs before opening interactive login", arguments: [false, true])
    func coldRegistrationProof(alreadyAdopted: Bool) async throws {
        let scope = try #require(V2LiveLocalAccountE2ETestScope(rawValue: UUID().uuidString))
        let service = scope.keychainService(basedOn: try V2AppConfiguration().keychainService)
        let registrations = V2DeviceRegistrationStore(service: service)
        let keychain = V2KeychainCredentialStore(service: service)
        do {
            let prepared = try await registrations.prepare(accountHandle: "cold_account")
            let pending = try #require(try await prepared.load())
            #expect(try accessibility(service: service, account: "device-registration-ledger-v1") == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            let credentials = try V2AuthCredentials(userID: .init(UUID().uuidString), deviceID: pending.deviceID,
                accessToken: "owned-access", accessTokenExpiresAt: .distantFuture, refreshCredential: "owned-refresh",
                revocationCredential: .generate(), revocationCredentialExpiresAt: .distantFuture)
            if alreadyAdopted { try await keychain.save(.init(credentials: credentials)) }
            let app = V2AppStore(startupMode: .uiTestingLiveLocalAccount, liveLocalAccountE2ETestScope: scope)
            await app.restore()
            #expect(app.route == .signedOut)
            let recreated = V2DeviceRegistrationStore(service: service)
            #expect(try await recreated.pendingCancellations() == (alreadyAdopted ? [] : [pending.cancellation]))
            #expect(try await keychain.load()?.credentials == (alreadyAdopted ? credentials : nil))
            await app.restore()
            #expect(try await recreated.pendingCancellations() == (alreadyAdopted ? [] : [pending.cancellation]))
        } catch {
            try await keychain.delete()
            try await registrations.discardPendingRegistrations()
            for proof in try await registrations.pendingCancellations() { try await registrations.completeCancellation(proof) }
            throw error
        }
        let cleanup = V2AppStore(startupMode: .uiTestingLiveLocalAccountCleanup, liveLocalAccountE2ETestScope: scope)
        await cleanup.restore()
        #expect(cleanup.route == .uiTestingLiveLocalAccountCleanupCompleted)
        #expect(try await registrations.pendingCancellations().isEmpty)
    }

    @MainActor
    @Test("App observes paused registration cancellation and retries its durable proof while inactive")
    func appRegistrationCancellationStatus() async throws {
        let scope = try #require(V2LiveLocalAccountE2ETestScope(rawValue: UUID().uuidString))
        let service = scope.keychainService(basedOn: try V2AppConfiguration().keychainService)
        let registrations = V2DeviceRegistrationStore(service: service)
        let prepared = try await registrations.prepare(accountHandle: "paused_account")
        let pending = try #require(try await prepared.load())
        try await registrations.discardPendingRegistrations()
        // Seed a paused persisted job without contacting a network service.
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "device-registration-ledger-v1"]
        do {
            var value: CFTypeRef?
            try #require(SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { _, new in new } as CFDictionary, &value) == errSecSuccess)
            let existingData = try #require(value as? Data)
            var ledger = try #require(JSONSerialization.jsonObject(with: existingData) as? [String: Any])
            var abandoned = try #require(ledger["abandoned"] as? [String: [String: Any]])
            abandoned[pending.operationID.uuidString]?["pauseReason"] = "invalidResponse"
            abandoned[pending.operationID.uuidString]?["attempts"] = 1
            ledger["abandoned"] = abandoned
            let data = try JSONSerialization.data(withJSONObject: ledger)
            try #require(SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess)
            let app = V2AppStore(startupMode: .uiTestingLiveLocalAccount, liveLocalAccountE2ETestScope: scope)
            await app.applicationDidBecomeActive()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while app.deviceRevocationPresentation != .paused, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(app.deviceRevocationPresentation == .paused)
            await app.applicationDidEnterBackground()
            await app.retryDeviceRevocation()
            let job = try #require(try await registrations.cancellationJobs().first)
            #expect(job.cancellation == pending.cancellation && job.attempts == 1 && job.pauseReason == nil)
        } catch {
            try await registrations.completeCancellation(pending.cancellation)
            throw error
        }
        let cleanup = V2AppStore(startupMode: .uiTestingLiveLocalAccountCleanup, liveLocalAccountE2ETestScope: scope)
        await cleanup.restore()
        #expect(cleanup.route == .uiTestingLiveLocalAccountCleanupCompleted)
    }

    @Test("real separate Keychain items survive owner recreation and preserve the next account")
    func persistentHandoff() async throws {
        let service = "imapp.tests.device-revocation." + UUID().uuidString
        let credentials = V2KeychainCredentialStore(service: service)
        let queue = V2DeviceRevocationStore(service: service)
        do {
            let old = try makeCredentials("old")
            let next = try makeCredentials("new")
            try await credentials.save(.init(credentials: old))
            let operationID = UUID()
            let session = V2AuthSession(credentialStore: FailDeletionCredentialStore(store: credentials),
                transport: UnexpectedRefresh(), revocationScheduler: queue, makeUUID: { operationID })
            await #expect(throws: V2AuthSessionError.credentialsUnavailable) { try await session.handleTerminalRejection() }
            #expect(try await credentials.load()?.pendingRevocationOperationID == operationID)
            let retained = try #require(try await queue.jobs().first)
            #expect(retained.intent.operationID == operationID)
            #expect(retained.intent.credential == old.revocationCredential)
            #expect(try accessibility(service: service, account: "device-credentials") == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            #expect(try accessibility(service: service, account: "device-revocation-outbox-v1") == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)

            let resumedQueue = V2DeviceRevocationStore(service: service)
            let resumedCredentials = V2KeychainCredentialStore(service: service)
            let resumed = V2AuthSession(credentialStore: resumedCredentials, transport: UnexpectedRefresh(),
                revocationScheduler: resumedQueue)
            #expect(try await resumed.restoreState() == .unauthenticated)
            #expect(try await resumedCredentials.load() == nil)
            #expect(try await resumedQueue.jobs() == [retained])
            try await resumed.establish(next)
            #expect(try await resumedQueue.complete(retained))
            #expect(try await resumed.accessToken() == next.accessToken)
            #expect(try await resumedCredentials.load()?.credentials == next)
            #expect(try await V2DeviceRevocationStore(service: service + ".other").jobs().isEmpty)
            try await cleanup(credentials: credentials, queue: queue)
        } catch {
            try await cleanup(credentials: credentials, queue: queue)
            throw error
        }
        #expect(try await credentials.load() == nil)
        #expect(try await queue.jobs().isEmpty)
    }

    @MainActor
    @Test("App logout with expired credentials completes locally without account HTTP")
    func appLogoutDoesNotNeedRefresh() async throws {
        let scope = try #require(V2LiveLocalAccountE2ETestScope(rawValue: UUID().uuidString))
        let service = scope.keychainService(basedOn: try V2AppConfiguration().keychainService)
        let credentials = V2KeychainCredentialStore(service: service)
        let queue = V2DeviceRevocationStore(service: service)
        let old = try V2AuthCredentials(userID: .init(UUID().uuidString), deviceID: .init(UUID().uuidString),
            accessToken: "expired-local-access", accessTokenExpiresAt: .distantPast,
            refreshCredential: "local-only-refresh-never-issued", revocationCredential: .generate(), revocationCredentialExpiresAt: .distantFuture)
        do {
            try await credentials.save(.init(credentials: old))
            let app = V2AppStore(startupMode: .uiTestingLiveLocalAccount, liveLocalAccountE2ETestScope: scope)
            // No foreground activation: the independent network owner is not
            // running. Neither logout nor its cold cleanup needs that owner.
            await app.signOut()
            #expect(app.route == .signedOut)
            #expect(try await credentials.load() == nil)
            let job = try #require(try await queue.jobs().first)
            #expect(job.intent.credential == old.revocationCredential)
            #expect(job.attempts == 0)
            let relaunched = V2AppStore(startupMode: .uiTestingLiveLocalAccountRestore, liveLocalAccountE2ETestScope: scope)
            await relaunched.restore()
            #expect(relaunched.route == .signedOut)
            #expect(try await queue.jobs() == [job])
        } catch {
            try await cleanup(credentials: credentials, queue: queue)
            throw error
        }
        let cleanupApp = V2AppStore(startupMode: .uiTestingLiveLocalAccountCleanup, liveLocalAccountE2ETestScope: scope)
        await cleanupApp.restore()
        #expect(cleanupApp.route == .uiTestingLiveLocalAccountCleanupCompleted)
        #expect(try await queue.jobs().isEmpty)
    }

    @MainActor
    @Test("App observes a paused outbox and explicit recovery preserves another login")
    func appRecoveryPreservesLogin() async throws {
        let scope = try #require(V2LiveLocalAccountE2ETestScope(rawValue: UUID().uuidString))
        let service = scope.keychainService(basedOn: try V2AppConfiguration().keychainService)
        let keychain = V2KeychainCredentialStore(service: service)
        let queue = V2DeviceRevocationStore(service: service)
        let old = try makeCredentials("old"), current = try makeCredentials("current")
        do {
            try await queue.enqueue(.init(credentials: old, operationID: UUID()))
            let original = try #require(try await queue.jobs().first)
            try await queue.recordFailure(original, retryAt: .distantFuture, pauseReason: .invalidResponse)
            let app = V2AppStore(startupMode: .uiTestingLiveLocalAccount, liveLocalAccountE2ETestScope: scope)
            await app.applicationDidBecomeActive()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while app.deviceRevocationPresentation != .paused, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(app.deviceRevocationPresentation == .paused)
            #expect(app.route == .signedOut)
            await app.applicationDidEnterBackground()
            try await keychain.save(.init(credentials: current))
            // No network owner runs in background; this checks the real App
            // action's durable effect independently from HTTP timing.
            await app.retryDeviceRevocation()
            let resumed = try #require(try await queue.jobs().first)
            #expect(resumed.intent == original.intent)
            #expect(resumed.attempts == 1)
            #expect(resumed.pauseReason == nil)
            #expect(try await keychain.load()?.credentials == current)
        } catch {
            try await cleanup(credentials: keychain, queue: queue)
            throw error
        }
        let cleanupApp = V2AppStore(startupMode: .uiTestingLiveLocalAccountCleanup, liveLocalAccountE2ETestScope: scope)
        await cleanupApp.restore()
        #expect(cleanupApp.route == .uiTestingLiveLocalAccountCleanupCompleted)
    }

    @MainActor
    @Test("cold App reconciles actual received-result Keychain before admitting login", arguments: [false, true])
    func coldReceivedResultRecovery(alreadyAdopted: Bool) async throws {
        let scope = try #require(V2LiveLocalAccountE2ETestScope(rawValue: UUID().uuidString))
        let service = scope.keychainService(basedOn: try V2AppConfiguration().keychainService)
        let keychain = V2KeychainCredentialStore(service: service)
        let queue = V2DeviceRevocationStore(service: service)
        let recovery = V2IssuedCredentialRecoveryStore(service: service, revocations: queue)
        let credentials = try makeCredentials("received")
        do {
            let receipt = try await recovery.receive(credentials, operationID: UUID())
            if alreadyAdopted { try await keychain.save(.init(credentials: credentials)) }
            #expect(try accessibility(service: service, account: "received-device-credentials-v1") == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            let app = V2AppStore(startupMode: .uiTestingLiveLocalAccount, liveLocalAccountE2ETestScope: scope)
            await app.restore()
            #expect(app.route == .signedOut)
            #expect(try await queue.jobs().map(\.intent) == (alreadyAdopted ? [] : [receipt]))
            #expect(try await keychain.load()?.credentials == (alreadyAdopted ? credentials : nil))
        } catch {
            try await recovery.recoverUnclaimed(ownedBy: nil)
            try await cleanup(credentials: keychain, queue: queue)
            throw error
        }
        let cleanupApp = V2AppStore(startupMode: .uiTestingLiveLocalAccountCleanup, liveLocalAccountE2ETestScope: scope)
        await cleanupApp.restore()
        #expect(cleanupApp.route == .uiTestingLiveLocalAccountCleanupCompleted)
        #expect(try await queue.jobs().isEmpty)
    }

    private func makeCredentials(_ suffix: String) throws -> V2AuthCredentials {
        try .init(userID: .init(UUID().uuidString), deviceID: .init(UUID().uuidString),
            accessToken: "access-" + suffix, accessTokenExpiresAt: .distantFuture,
            refreshCredential: "refresh-" + suffix, revocationCredential: .generate(), revocationCredentialExpiresAt: .distantFuture)
    }
    private func cleanup(credentials: V2KeychainCredentialStore, queue: V2DeviceRevocationStore) async throws {
        try await credentials.delete()
        for job in try await queue.jobs() { try await queue.complete(job) }
    }
    private func accessibility(service: String, account: String) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        try #require(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        return try #require((result as? [String: Any])?[kSecAttrAccessible as String] as? String)
    }
}

private actor FailDeletionCredentialStore: V2CredentialStore {
    let store: V2KeychainCredentialStore
    init(store: V2KeychainCredentialStore) { self.store = store }
    func load() async throws -> V2AuthCredentialRecord? { try await store.load() }
    func save(_ record: V2AuthCredentialRecord) async throws { try await store.save(record) }
    func delete() throws { throw V2CredentialStoreError.unavailable }
}
private struct UnexpectedRefresh: V2AuthTransport {
    func refresh(_ request: V2RefreshRequest) throws -> V2AuthCredentials {
        Issue.record("Revocation handoff must not refresh credentials")
        throw V2AuthTransportError.terminalRejection
    }
}

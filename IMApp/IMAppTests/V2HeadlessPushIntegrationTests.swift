import Foundation
import SQLite3
import IMV2ClientKit
import IMV2Core
import Testing
import UIKit
@testable import IMApp

/// Opt in through the disposable native-account harness. The tested delegate
/// never receives a View or a scene activation. This does not simulate OS cold
/// launch/APNs delivery; it exercises the actual credential and sync stack.
@MainActor
@Suite("Live headless Push entry", .serialized, .timeLimit(.minutes(2)),
       .enabled(if: ProcessInfo.processInfo.environment["IMV2_HEADLESS_PUSH_TEST"] == "1"))
struct V2HeadlessPushIntegrationTests {
    @Test("a cold delegate restores Keychain credentials and commits sync without a root view")
    func coldCredentialRestoreAndRevocation() async throws {
        let scope = try #require(V2LiveLocalAccountE2ETestScope(rawValue: UUID().uuidString))
        let config = try V2AppConfiguration()
        let service = scope.keychainService(basedOn: config.keychainService)
        let keychain = V2KeychainCredentialStore(service: service)
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let authenticator = try V2HTTPPasswordAccountAuthenticator(
            registrationEndpoint: config.endpoint("v2/account-auth/password/register"),
            assertionEndpoint: config.endpoint("v2/account-auth/password/assertion"))
        let assertion = try await authenticator.register(accountHandle: "headless_" + suffix,
            password: "local-headless-push-password", publicHandle: "hl" + suffix.prefix(20),
            displayName: "Headless Push integration", deviceID: scope.deviceID)
        let identity = HeadlessIdentity(assertion: assertion.value, device: scope.deviceID)
        let issuer = try V2HTTPAccountAssertionDeviceCredentialProvider(
            issueEndpoint: config.endpoint("v2/device-credentials"), assertionProvider: identity,
            deviceIdentityProvider: identity,
            operationStore: V2KeychainDeviceCredentialRegistrationOperationStore(service: service))
        let credentials = try await issuer.issueDeviceCredentials()
        try await keychain.save(.init(credentials: credentials))
        try await issuer.finalizeIssuedDeviceCredentials(credentials)
        let delegate = V2AppPushDelegate(makeStore: {
            V2AppStore(startupMode: .uiTestingLiveLocalAccountRestore,
                       liveLocalAccountE2ETestScope: scope, remoteNotificationRegistrar: $0)
        })
        do {
            #expect(delegate.store.route == .launching)
            let result = await deliverPush(delegate)
            #expect(result == .newData || result == .noData)
            #expect(delegate.store.route == .signedIn(userID: credentials.userID.rawValue))
            let credentialsUnchanged = try await keychain.load()?.credentials == credentials
            #expect(credentialsUnchanged)
            let cursor = try readCursor(scope)
            #expect(cursor.state == "ready")
            #expect(cursor.applied == cursor.acknowledged)
            #expect(cursor.token != nil)
            // The same callback can run again from its durable cursor.
            #expect(await deliverPush(delegate) == .noData)
            let replay = try readCursor(scope)
            #expect(replay.applied == cursor.applied)
            #expect(replay.acknowledged == cursor.acknowledged)

            // Device inventory revocation intentionally targets another
            // device; use a separately authenticated device as the actor.
            let revokerDevice = try DeviceID(UUID().uuidString)
            let revokerAssertion = try await authenticator.authenticate(accountHandle: "headless_" + suffix,
                password: "local-headless-push-password", deviceID: revokerDevice)
            let revokerIdentity = HeadlessIdentity(assertion: revokerAssertion.value, device: revokerDevice)
            let revokerIssuer = try V2HTTPAccountAssertionDeviceCredentialProvider(
                issueEndpoint: config.endpoint("v2/device-credentials"), assertionProvider: revokerIdentity,
                deviceIdentityProvider: revokerIdentity,
                operationStore: V2KeychainDeviceCredentialRegistrationOperationStore(service: service + ".revoker"))
            let revoker = try await revokerIssuer.issueDeviceCredentials()
            try await V2KeychainCredentialStore(service: service + ".revoker").save(.init(credentials: revoker))
            try await revokerIssuer.finalizeIssuedDeviceCredentials(revoker)
            var request = URLRequest(url: config.endpoint("v2/devices/revoke"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + revoker.accessToken, forHTTPHeaderField: "Authorization")
            request.setValue(revoker.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
            request.httpBody = try JSONEncoder().encode(["deviceID": scope.deviceID.rawValue, "operationID": UUID().uuidString])
            let (_, response) = try await URLSession.shared.data(for: request)
            try #require((response as? HTTPURLResponse)?.statusCode == 204)
            #expect(await deliverPush(delegate) == .failed)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while delegate.store.route != .signedOut {
                guard ContinuousClock.now < deadline else { throw HeadlessFailure.cleanupTimedOut }
                try await Task.sleep(for: .milliseconds(1))
            }
            let credentialsCleared = try await keychain.load() == nil
            #expect(credentialsCleared)
            #expect(await deliverPush(delegate) == .noData)
            await cleanup(delegate, scope: scope)
        } catch {
            await cleanup(delegate, scope: scope)
            throw error
        }
    }

    private func deliverPush(_ delegate: V2AppPushDelegate) async -> UIBackgroundFetchResult {
        var calls = 0
        let result: UIBackgroundFetchResult = await withCheckedContinuation { continuation in
            delegate.application(UIApplication.shared, didReceiveRemoteNotification: ["aps": ["content-available": 1]]) { result in
                calls += 1
                continuation.resume(returning: result)
            }
        }
        #expect(calls == 1)
        return result
    }

    private func cleanup(_ delegate: V2AppPushDelegate, scope: V2LiveLocalAccountE2ETestScope) async {
        await delegate.store.signOut()
        do {
            let service = scope.keychainService(basedOn: try V2AppConfiguration().keychainService) + ".revoker"
            try await V2KeychainCredentialStore(service: service).delete()
            try await V2KeychainDeviceCredentialRegistrationOperationStore(service: service).delete()
        } catch { Issue.record("Could not clean the isolated revoker Keychain scope") }
        let cleanup = V2AppStore(startupMode: .uiTestingLiveLocalAccountCleanup, liveLocalAccountE2ETestScope: scope)
        await cleanup.restore()
        #expect(cleanup.route == .uiTestingLiveLocalAccountCleanupCompleted)
    }

    private struct Cursor {
        let state: String
        let applied: Int64
        let acknowledged: Int64
        let token: String?
    }
    private func readCursor(_ scope: V2LiveLocalAccountE2ETestScope) throws -> Cursor {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let root = support.appending(path: "IMAppV2").appending(path: scope.databaseFileName).appendingPathExtension("accounts")
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "V2.sqlite" }
        #expect(files.count == 1)
        let file = try #require(files.first)
        var database: OpaquePointer?
        guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw HeadlessFailure.databaseReadFailed
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT state, applied_sequence, server_acknowledged_sequence, sync_token FROM v2_sync_cursor WHERE singleton = 1", -1, &statement, nil) == SQLITE_OK else {
            throw HeadlessFailure.databaseReadFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let state = sqlite3_column_text(statement, 0) else {
            throw HeadlessFailure.databaseReadFailed
        }
        return Cursor(state: String(cString: state), applied: sqlite3_column_int64(statement, 1),
                      acknowledged: sqlite3_column_int64(statement, 2),
                      token: sqlite3_column_text(statement, 3).map { String(cString: $0) })
    }
}

private enum HeadlessFailure: Error { case cleanupTimedOut, databaseReadFailed }
private struct HeadlessIdentity: V2DeviceBoundAccountAssertionProvider, V2DeviceIdentityProvider {
    let assertion: String
    let device: DeviceID
    func accountAssertion(for deviceID: DeviceID) throws -> String {
        guard deviceID == device else { throw V2AuthSessionError.deviceMismatch }
        return assertion
    }
    func deviceID() -> DeviceID { device }
}

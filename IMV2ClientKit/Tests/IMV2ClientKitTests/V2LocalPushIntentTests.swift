import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Durable local Push intent")
struct V2LocalPushIntentTests {
    @Test("reopened Push intents reject REAL integer fields without replacing durable intent",
          arguments: ["intent_revision", "acknowledged_revision", "attempt_count", "expected_epoch", "session_epoch"],
          [1.5, Double(Int64.max)])
    func reopenedIntegerStorageTypes(field: String, value: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-push-storage-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = try V2PushIntentScope(userID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()), installation: .init(value: UUID()))
        let owner = UUID(), url = directory.appending(path: "state.sqlite")
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: scope.installation, userID: scope.userID)
        let initial: V2LocalPushIntent
        let original: Int64
        do {
            var state = try await store.activatePushIntent(scope: scope, ownerID: owner, initialPreference: true)
            #expect(try await store.savePushClaim(.init(requestID: UUID(), expectedEpoch: 7), expected: state))
            state = try await store.pushIntent(scope: scope, ownerID: owner)
            #expect(try await store.completePushClaim(epoch: 8, expected: state))
            initial = try await store.pushIntent(scope: scope, ownerID: owner)
            let pool = await store.databasePool
            original = try await pool.write { db in
                let old = try #require(try Int64.fetchOne(db, sql: "SELECT \(field) FROM v2_push_intent"))
                // Fractional attempt_count is allowed by the normal numeric CHECK.
                // Other injections model corrupted storage by explicitly bypassing constraints.
                let bypass = field != "attempt_count" || value != 1.5
                if bypass { try db.execute(sql: "PRAGMA ignore_check_constraints = ON") }
                defer { if bypass { try? db.execute(sql: "PRAGMA ignore_check_constraints = OFF") } }
                try db.execute(sql: "UPDATE v2_push_intent SET \(field) = ?", arguments: [value])
                return old
            }
            try await store.close()
        } catch { try? await store.close(); throw error }
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: scope.installation, userID: scope.userID)
        do {
            await #expect(throws: V2LocalPushIntentError.invalidState) { _ = try await reopened.inspectPushIntent(scope: scope) }
            await #expect(throws: V2LocalPushIntentError.invalidState) { _ = try await reopened.pushIntent(scope: scope, ownerID: owner) }
            await #expect(throws: V2LocalPushIntentError.invalidState) { _ = try await reopened.retryPushIntent(at: .init(timeIntervalSince1970: 50), expected: initial) }
            await #expect(throws: V2LocalPushIntentError.invalidState) {
                _ = try await reopened.activatePushIntent(scope: scope, ownerID: UUID(), initialPreference: false, replacing: initial)
            }
            let pool = await reopened.databasePool
            try await pool.read { db in
                let type = try String.fetchOne(db, sql: "SELECT typeof(\(field)) FROM v2_push_intent")
                let stored = try Double.fetchOne(db, sql: "SELECT \(field) FROM v2_push_intent")
                let storedOwner = try String.fetchOne(db, sql: "SELECT owner_id FROM v2_push_intent")
                let retryAt = try Double.fetchOne(db, sql: "SELECT next_attempt_at FROM v2_push_intent")
                #expect(type == "real" && stored == value)
                #expect(storedOwner == owner.uuidString && retryAt == initial.nextAttemptAt.timeIntervalSince1970)
            }
            try await pool.write { db in try db.execute(sql: "UPDATE v2_push_intent SET \(field) = ?", arguments: [original]) }
            #expect(try await reopened.pushIntent(scope: scope, ownerID: owner) == initial)
            #expect(try await reopened.retryPushIntent(at: .init(timeIntervalSince1970: 50), expected: initial))
            #expect(try await reopened.pushIntent(scope: scope, ownerID: owner).attemptCount == initial.attemptCount + 1)
            try await reopened.close()
        } catch { try? await reopened.close(); throw error }
    }

    @Test("restored Push retry counters are bounded before arithmetic", arguments: [Int64.min, -1, 0, 1, Int64(Int32.max), Int64(Int32.max) + 1, Int64.max])
    func restoredRetryCounterBounds(value: Int64) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-push-counter-bounds-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = try V2PushIntentScope(userID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()), installation: .init(value: UUID()))
        let owner = UUID()
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: scope.installation, userID: scope.userID)
        do {
            let initial = try await store.activatePushIntent(scope: scope, ownerID: owner, initialPreference: true)
            let pool = await store.databasePool
            try await pool.write { db in
                try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
                defer { try? db.execute(sql: "PRAGMA ignore_check_constraints = OFF") }
                try db.execute(sql: "UPDATE v2_push_intent SET attempt_count = ?", arguments: [value])
            }
            let retryAt = Date(timeIntervalSince1970: 50)
            if value < 0 || value > Int32.max {
                await #expect(throws: V2LocalPushIntentError.invalidState) { try await store.pushIntent(scope: scope, ownerID: owner) }
                await #expect(throws: V2LocalPushIntentError.invalidState) { try await store.retryPushIntent(at: retryAt, expected: initial) }
                #expect(try await pool.read { try Int64.fetchOne($0, sql: "SELECT attempt_count FROM v2_push_intent") } == value)
            } else {
                let restored = try await store.pushIntent(scope: scope, ownerID: owner)
                #expect(restored.attemptCount == Int(value))
                #expect(try await store.retryPushIntent(at: retryAt, expected: restored))
                let retried = try await store.pushIntent(scope: scope, ownerID: owner)
                #expect(retried.attemptCount == (value == Int32.max ? Int(Int32.max) : Int(value + 1)))
                #expect(retried.nextAttemptAt == retryAt)
                #expect(retried.revision == restored.revision && retried.ownerID == restored.ownerID)
            }
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("restored Push retry dates reject invalid storage and preserve finite deadlines", arguments: [-Double.infinity, -1, 0, 50, 1e300.nextDown, 1e300, Double.infinity])
    func restoredRetryDateBounds(value: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-push-date-bounds-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = try V2PushIntentScope(userID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()), installation: .init(value: UUID()))
        let owner = UUID()
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: scope.installation, userID: scope.userID)
        do {
            let initial = try await store.activatePushIntent(scope: scope, ownerID: owner, initialPreference: true)
            let pool = await store.databasePool
            try await pool.write { db in
                try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
                defer { try? db.execute(sql: "PRAGMA ignore_check_constraints = OFF") }
                try db.execute(sql: "UPDATE v2_push_intent SET next_attempt_at = ?", arguments: [value])
            }
            let retryAt = Date(timeIntervalSince1970: 50)
            if !value.isFinite || value < 0 || value >= 1e300 {
                await #expect(throws: V2LocalPushIntentError.invalidState) { try await store.pushIntent(scope: scope, ownerID: owner) }
                await #expect(throws: V2LocalPushIntentError.invalidState) { try await store.retryPushIntent(at: retryAt, expected: initial) }
                #expect(try await pool.read { try Double.fetchOne($0, sql: "SELECT next_attempt_at FROM v2_push_intent") } == value)
            } else {
                let restored = try await store.pushIntent(scope: scope, ownerID: owner)
                #expect(restored.nextAttemptAt.timeIntervalSince1970 == value)
                #expect(try await store.retryPushIntent(at: retryAt, expected: restored))
                let retried = try await store.pushIntent(scope: scope, ownerID: owner)
                #expect(retried.attemptCount == 1)
                #expect(retried.nextAttemptAt == retryAt)
                #expect(retried.revision == restored.revision && retried.ownerID == restored.ownerID)
            }
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("uncertain session claim survives restart and old owner results cannot settle a new token")
    func restartClaim() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let owner = UUID()
        var state = try await store.activatePushIntent(scope: fixture.scope, ownerID: owner, initialPreference: true)
        let claim = try V2PushIntentSessionClaim(requestID: UUID(), expectedEpoch: 7)
        #expect(try await store.savePushClaim(claim, expected: state))
        state = try await store.pushIntent(scope: fixture.scope, ownerID: owner)
        try await store.beginReset(.init(snapshotID: .init(uuid: UUID()), generation: 2, baseSequence: 0, expiresAt: .distantFuture))
        #expect(try await store.pushIntent(scope: fixture.scope, ownerID: owner) == state)
        try await store.close()
        let reopened = try fixture.open()
        let nextOwner = UUID()
        let resumed = try await reopened.activatePushIntent(scope: fixture.scope, ownerID: nextOwner, initialPreference: false, replacing: state)
        #expect(resumed.claim == claim && resumed.epoch == nil && resumed.preferenceEnabled)
        #expect(resumed.waitingForToken && resumed.revision > state.revision)
        #expect(try await reopened.completePushClaim(epoch: 8, expected: state) == false)
        #expect(try await reopened.completePushClaim(epoch: 8, expected: resumed))
        let ready = try await reopened.pushIntent(scope: fixture.scope, ownerID: nextOwner)
        await #expect(throws: V2LocalPushIntentError.invalidState) { try await reopened.acknowledgePushIntent(ready) }
        let first = try await reopened.stagePushToken(reference: UUID(), scope: fixture.scope, ownerID: nextOwner)
        let second = try await reopened.stagePushToken(reference: UUID(), scope: fixture.scope, ownerID: nextOwner)
        #expect(try await reopened.acknowledgePushIntent(first) == false)
        #expect(try await reopened.acknowledgePushIntent(second))
        #expect(try await reopened.pushIntent(scope: fixture.scope, ownerID: nextOwner).pending == false)
        try await reopened.close()
    }

    @Test("disable, sign-out, pause and retry preserve preference and reject stale completion")
    func desiredOrdering() async throws {
        let f = try Fixture(); let store = try f.open(); let owner = UUID()
        let initial = try await store.activatePushIntent(scope: f.scope, ownerID: owner, initialPreference: true)
        #expect(try await store.savePushClaim(.init(requestID: UUID(), expectedEpoch: 0), expected: initial))
        let claiming = try await store.pushIntent(scope: f.scope, ownerID: owner)
        let off = try await store.setPushIntentEnabled(false, scope: f.scope, ownerID: owner)
        #expect(try await store.completePushClaim(epoch: 1, expected: claiming) == false)
        #expect(try await store.completePushClaim(epoch: 1, expected: off))
        let disabled = try await store.pushIntent(scope: f.scope, ownerID: owner)
        #expect(try await store.acknowledgePushIntent(disabled))
        _ = try await store.setPushIntentEnabled(true, scope: f.scope, ownerID: owner)
        let sending = try await store.stagePushToken(reference: UUID(), scope: f.scope, ownerID: owner)
        let signOut = try await store.preparePushSignOut(scope: f.scope, ownerID: owner)
        #expect(signOut.preferenceEnabled && !signOut.desiredEnabled && signOut.revision > sending.revision)
        #expect(try await store.acknowledgePushIntent(sending) == false)
        #expect(try await store.retryPushIntent(at: .init(timeIntervalSince1970: 50), expected: signOut))
        #expect(try await store.pausePushIntent(.staleSession, expected: signOut) == false)
        let retrying = try await store.pushIntent(scope: f.scope, ownerID: owner)
        #expect(retrying.attemptCount == 1 && retrying.nextAttemptAt.timeIntervalSince1970 == 50)
        #expect(try await store.pausePushIntent(.staleSession, expected: retrying))
        let paused = try await store.pushIntent(scope: f.scope, ownerID: owner)
        #expect(try await store.restartPushIntentSession(expected: paused))
        let restarted = try await store.pushIntent(scope: f.scope, ownerID: owner)
        #expect(restarted.claim == nil && restarted.epoch == nil && restarted.pauseReason == nil && restarted.pending)
        #expect(restarted.revision > paused.revision)
        try await store.close()
    }

    @Test("account, installation, device and owner boundaries reject old work")
    func scopeFences() async throws {
        let f = try Fixture(); let store = try f.open(); let owner = UUID()
        let state = try await store.activatePushIntent(scope: f.scope, ownerID: owner, initialPreference: false)
        let wrongUser = try V2PushIntentScope(userID: .init(uuid: UUID()), deviceID: f.scope.deviceID, installation: f.scope.installation)
        let wrongInstall = try V2PushIntentScope(userID: f.scope.userID, deviceID: f.scope.deviceID, installation: .init(value: UUID()))
        for scope in [wrongUser, wrongInstall] {
            await #expect(throws: V2LocalPushIntentError.scopeMismatch) { try await store.activatePushIntent(scope: scope, ownerID: UUID(), initialPreference: true) }
        }
        let newDevice = try V2PushIntentScope(userID: f.scope.userID, deviceID: .init(uuid: UUID()), installation: f.scope.installation)
        let replacement = try await store.activatePushIntent(scope: newDevice, ownerID: UUID(), initialPreference: true, replacing: state)
        #expect(replacement.revision == 1 && replacement.claim == nil)
        await #expect(throws: V2LocalPushIntentError.staleOwner) {
            try await store.activatePushIntent(scope: f.scope, ownerID: owner, initialPreference: false, replacing: state)
        }
        #expect(try await store.inspectPushIntent(scope: newDevice) == replacement)
        #expect(try await store.savePushClaim(.init(requestID: UUID(), expectedEpoch: 0), expected: state) == false)
        await #expect(throws: V2LocalPushIntentError.staleOwner) { try await store.setPushIntentEnabled(true, scope: f.scope, ownerID: owner) }
        try await store.close()
    }

    @Test("failed transaction and integer exhaustion never partially change desired state")
    func rollbackAndBounds() async throws {
        let f = try Fixture(); let store = try f.open(); let owner = UUID()
        let original = try await store.activatePushIntent(scope: f.scope, ownerID: owner, initialPreference: false)
        let pool = await store.databasePool
        try await pool.write { try $0.execute(sql: "CREATE TRIGGER test_push_abort BEFORE UPDATE ON v2_push_intent BEGIN SELECT RAISE(ABORT, 'test rollback'); END") }
        await #expect(throws: (any Error).self) { try await store.setPushIntentEnabled(true, scope: f.scope, ownerID: owner) }
        #expect(try await store.pushIntent(scope: f.scope, ownerID: owner) == original)
        try await pool.write { db in
            try db.execute(sql: "DROP TRIGGER test_push_abort")
            try db.execute(sql: "UPDATE v2_push_intent SET intent_revision = 9223372036854775807")
        }
        await #expect(throws: V2LocalPushIntentError.versionExhausted) { try await store.setPushIntentEnabled(true, scope: f.scope, ownerID: owner) }
        #expect(try await store.pushIntent(scope: f.scope, ownerID: owner).desiredEnabled == false)
        for sql in ["UPDATE v2_push_intent SET intent_revision = 9223372036854775808", "UPDATE v2_push_intent SET session_epoch = 1", "UPDATE v2_push_intent SET claim_id = '\(UUID())'", "UPDATE v2_push_intent SET attempt_count = -1", "UPDATE v2_push_intent SET next_attempt_at = -1", "UPDATE v2_push_intent SET token_reference = '\(UUID())'"] {
            await #expect(throws: (any Error).self) { try await pool.write { try $0.execute(sql: sql) } }
        }
        try await store.close()
    }

    @Test("reopening preserves account, cursor and pending commands without inventing push intent")
    func reopenPreservesOutbox() async throws {
        let f = try Fixture(); let store = try f.open()
        let command = try await persistDurableMessage(in: store, roomID: .init(uuid: UUID()), clientMessageID: .init(uuid: UUID()), text: "pending during restart")
        try await store.beginReset(.init(snapshotID: .init(uuid: UUID()), generation: 2, baseSequence: 0, expiresAt: .distantFuture))
        let cursor = try #require(try await store.cursor())
        #expect(cursor.pendingReset != nil)
        try await store.close()
        let reopened = try f.open()
        #expect(try await reopened.boundAccountID() == f.scope.userID)
        #expect(try await reopened.cursor() == cursor)
        #expect(try await savedDurableMessages(in: reopened).first?.clientMessageID == command.clientMessageID)
        let reopenedPool = await reopened.databasePool
        #expect(try await reopenedPool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM v2_push_intent") } == 0)
        let state = try await reopened.activatePushIntent(scope: f.scope, ownerID: UUID(), initialPreference: false)
        #expect(!state.desiredEnabled && state.pending && state.revision == 1)
        try await reopened.close()
    }

    private struct Fixture {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-push-intent-\(UUID()).sqlite")
        let scope: V2PushIntentScope
        init() throws { scope = try .init(userID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()), installation: .init(value: UUID())) }
        func open() throws -> GRDBV2LocalSyncStore { try .init(databaseURL: url, installationBinding: scope.installation, userID: scope.userID) }
    }
}

import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Push intent reconciler")
struct V2PushIntentReconcilerTests {
    @Test("structured service cooldown persists across restart without publishing early")
    func structuredCooldownPersists() async throws {
        let f = try Fixture(); let store = try f.open(); let remote = PushReconcileRemote()
        let now = Date(timeIntervalSince1970: 100)
        let engine = try await V2PushIntentReconciler.activate(store: store, transport: remote, scope: f.scope,
            initialPreference: false, now: { now })
        _ = try await engine.flushOnce()
        _ = try await engine.flushOnce()
        await remote.failHTTP(.init(kind: .httpStatus, service: "pushEndpoints", statusCode: 503,
            retryAfter: now.addingTimeInterval(10000), certainty: .responseReceived))
        #expect(try await engine.flushOnce() == .retryScheduled)
        #expect(try await engine.state().nextAttemptAt.timeIntervalSince1970 == 10100)
        await engine.stop(); try await store.close()
        let reopened = try f.open()
        let resumed = try await V2PushIntentReconciler.activate(store: reopened, transport: remote, scope: f.scope,
            initialPreference: false, now: { Date(timeIntervalSince1970: 200) })
        #expect(try await resumed.flushOnce() == .idle)
        #expect(try await resumed.state().nextAttemptAt.timeIntervalSince1970 == 10100)
        await resumed.stop(); try await reopened.close()
    }

    @Test("automatic observation discovers disable, waits for token and applies newer token changes")
    func automaticDiscovery() async throws {
        let fixture = try Fixture(); let store = try fixture.open(); let remote = PushReconcileRemote()
        let engine = try await V2PushIntentReconciler.activate(store: store, transport: remote, scope: fixture.scope, initialPreference: false)
        await remote.failPublish(.networkFailure)
        let run = Task { try await engine.run() }
        try await wait { await remote.publications.count == 1 }
        #expect(await remote.enabled == false)
        #expect(await remote.publishAttempts == 2)
        try await engine.setEnabled(true)
        #expect(try await engine.state().waitingForToken)
        try await engine.receiveToken(provider: .apns, environment: .development, value: "token-a")
        try await wait { await remote.publications.count == 2 }
        try await engine.receiveToken(provider: .apns, environment: .development, value: "token-b")
        try await wait { await remote.publications.count == 3 }
        #expect(await remote.token == "token-b")
        try await engine.setEnabled(false)
        try await wait { await remote.publications.count == 4 }
        try await wait { try await engine.state().pending == false }
        await engine.stop(); _ = await run.result
        #expect(await remote.maximumInFlight == 1)
        try await store.close()
    }

    @Test("old in-flight enable cannot settle a newer persisted disable; concurrent flushes share transport")
    func disableWhileSending() async throws {
        let f = try Fixture(); let store = try f.open(); let remote = PushReconcileRemote()
        let engine = try await V2PushIntentReconciler.activate(store: store, transport: remote, scope: f.scope, initialPreference: true)
        try await engine.receiveToken(provider: .apns, environment: .development, value: "old-token")
        _ = try await engine.flushOnce(); _ = try await engine.flushOnce()
        await remote.holdNextPublication()
        let send = Task { try await engine.flushOnce() }
        try await wait { await remote.waiting }
        let other = Task { try await engine.flushOnce() }
        other.cancel()
        try await engine.setEnabled(false)
        let off = try await engine.state()
        #expect(!off.desiredEnabled && off.pending)
        await remote.releasePublication()
        #expect(try await send.value == .superseded)
        await #expect(throws: CancellationError.self) { try await other.value }
        _ = try await engine.flushOnce()
        #expect(await remote.enabled == false)
        #expect(try await engine.state().pending == false)
        #expect(await remote.maximumInFlight == 1)
        await engine.stop(); try await store.close()
    }

    @Test("late throttling preserves a newer disable and its cooldown through restart")
    func throttleWhileReplacingIntent() async throws {
        let f = try Fixture(); let store = try f.open(); let remote = PushReconcileRemote()
        let now = Date(timeIntervalSince1970: 100)
        let engine = try await V2PushIntentReconciler.activate(store: store, transport: remote, scope: f.scope,
            initialPreference: true, now: { now })
        try await engine.receiveToken(provider: .apns, environment: .development, value: "old-token")
        _ = try await engine.flushOnce(); _ = try await engine.flushOnce()
        await remote.holdNextPublication()
        await remote.failHTTP(.init(kind: .httpStatus, service: "pushEndpoints", statusCode: 503,
            retryAfter: now.addingTimeInterval(10000), certainty: .responseReceived))
        let send = Task { try await engine.flushOnce() }
        try await wait { await remote.waiting }
        try await engine.setEnabled(false)
        let newer = try await engine.state()
        await remote.releasePublication()
        #expect(try await send.value == .superseded)
        let cooled = try await engine.state()
        #expect(!cooled.desiredEnabled && cooled.pending && cooled.revision == newer.revision)
        #expect(cooled.nextAttemptAt.timeIntervalSince1970 == 10100)
        await engine.stop(); try await store.close()
        let reopened = try f.open()
        let resumed = try await V2PushIntentReconciler.activate(store: reopened, transport: remote, scope: f.scope,
            initialPreference: false, now: { Date(timeIntervalSince1970: 200) })
        #expect(try await resumed.flushOnce() == .idle)
        #expect(try await resumed.state().nextAttemptAt.timeIntervalSince1970 == 10100)
        await resumed.stop(); try await reopened.close()
    }

    @Test("lost claim response retries exact identity after reopening and honors a long server delay")
    func lostClaimAndRetry() async throws {
        let f = try Fixture(); let store = try f.open(); let remote = PushReconcileRemote()
        let engine = try await V2PushIntentReconciler.activate(store: store, transport: remote, scope: f.scope, initialPreference: false, now: { Date(timeIntervalSince1970: 100) })
        _ = try await engine.flushOnce()
        await remote.failClaimAfterCommit()
        #expect(try await engine.flushOnce() == .retryScheduled)
        let uncertain = try await engine.state()
        #expect(uncertain.claim != nil && uncertain.epoch == nil && uncertain.nextAttemptAt.timeIntervalSince1970 == 101)
        await engine.stop(); try await store.close()
        let reopened = try f.open()
        let resumed = try await V2PushIntentReconciler.activate(store: reopened, transport: remote, scope: f.scope, initialPreference: true, now: { Date(timeIntervalSince1970: 200) })
        #expect(try await resumed.state().claim == uncertain.claim)
        _ = try await resumed.flushOnce()
        let claims = await remote.claims
        #expect(claims.count == 2 && claims[0] == claims[1])
        await remote.failPublish(.rateLimited(retryAfter: 120))
        #expect(try await resumed.flushOnce() == .retryScheduled)
        #expect(try await resumed.state().nextAttemptAt.timeIntervalSince1970 == 320)
        #expect(try await resumed.flushOnce() == .idle)
        await resumed.stop(); try await reopened.close()
    }

    @Test("stale session pauses without claiming again; explicit restart retains final sign-out intent")
    func stalePauses() async throws {
        let f = try Fixture(); let store = try f.open(); let remote = PushReconcileRemote()
        let engine = try await V2PushIntentReconciler.activate(store: store, transport: remote, scope: f.scope, initialPreference: true)
        try await engine.prepareSignOut()
        await #expect(throws: CancellationError.self) { try await engine.receiveToken(provider: .apns, environment: .development, value: "late-token") }
        _ = try await engine.flushOnce(); _ = try await engine.flushOnce()
        await remote.failPublish(.staleIntent)
        #expect(try await engine.flushOnce() == .paused)
        #expect(try await engine.flushOnce() == .idle)
        #expect(await remote.claims.count == 1)
        let paused = try await engine.state()
        #expect(paused.preferenceEnabled && !paused.desiredEnabled && paused.pauseReason == .staleSession)
        try await engine.restartSession()
        _ = try await engine.flushOnce(); _ = try await engine.flushOnce(); _ = try await engine.flushOnce()
        #expect(await remote.claims.count == 2)
        #expect(await remote.enabled == false)
        #expect(try await engine.state().pending == false)
        await engine.stop(); try await store.close()
    }

    @Test("stop cancels an HTTP flight and late success leaves durable work pending")
    func stopDoesNotAcknowledge() async throws {
        let f = try Fixture(); let store = try f.open(); let remote = PushReconcileRemote()
        let engine = try await V2PushIntentReconciler.activate(store: store, transport: remote, scope: f.scope, initialPreference: false)
        _ = try await engine.flushOnce(); _ = try await engine.flushOnce()
        await remote.holdNextPublication()
        let send = Task { try await engine.flushOnce() }
        try await wait { await remote.waiting }
        let stopping = Task { await engine.stop() }
        try await wait { await remote.wasCancelled }
        await remote.releasePublication()
        await stopping.value
        _ = await send.result
        #expect(try await engine.state().pending)
        try await store.close()
    }

    @Test("a replacement owner cannot be completed or failed by the old HTTP flight")
    func replacementOwner() async throws {
        let f = try Fixture(); let store = try f.open(); let remote = PushReconcileRemote()
        let old = try await V2PushIntentReconciler.activate(store: store, transport: remote, scope: f.scope, initialPreference: false)
        _ = try await old.flushOnce(); _ = try await old.flushOnce()
        await remote.holdNextPublication()
        let sending = Task { try await old.flushOnce() }
        try await wait { await remote.waiting }
        let replacement = try await V2PushIntentReconciler.activate(store: store, transport: remote, scope: f.scope, initialPreference: true)
        let before = try await replacement.state()
        await remote.releasePublication()
        #expect(try await sending.value == .superseded)
        #expect(try await replacement.state() == before)
        await #expect(throws: V2LocalPushIntentError.staleOwner) { try await old.flushOnce() }
        _ = try await replacement.flushOnce()
        #expect(try await replacement.state().pending == false)
        await old.stop(); await replacement.stop(); try await store.close()
    }

    private func wait(_ condition: @escaping @Sendable () async throws -> Bool) async throws {
        for _ in 0..<500 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("bounded wait expired")
        throw V2LocalPushIntentError.invalidState
    }
    private struct Fixture {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-push-runner-\(UUID()).sqlite")
        let scope: V2PushIntentScope
        init() throws { scope = try .init(userID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()), installation: .init(value: UUID())) }
        func open() throws -> GRDBV2LocalSyncStore { try .init(databaseURL: url, installationBinding: scope.installation, userID: scope.userID) }
    }
}

private actor PushReconcileRemote: V2ClientPushIntentPublishing {
    var epoch: UInt64 = 0
    var claims: [V2PushIntentSessionClaim] = []
    var publications: [V2PushIntentVersion] = []
    var publishAttempts = 0
    var wasCancelled = false
    func recordCancellation() { wasCancelled = true }
    var enabled = false
    var token: String?
    var maximumInFlight = 0
    private var inFlight = 0
    private var dropClaim = false
    private var publishFailure: (any Error)?
    private var hold = false
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func failClaimAfterCommit() { dropClaim = true }
    func failHTTP(_ error: V2HTTPFailure) { publishFailure = error }
    func failPublish(_ error: V2ClientPushEndpointError) { publishFailure = error }
    func holdNextPublication() { hold = true }
    func releasePublication() { continuation?.resume(); continuation = nil }
    func intentEpoch(deviceID: DeviceID) -> UInt64 { epoch }
    func claimIntentSession(deviceID: DeviceID, claim: V2PushIntentSessionClaim) throws -> UInt64 {
        claims.append(claim)
        epoch = claim.expectedEpoch + 1
        if dropClaim { dropClaim = false; throw V2ClientPushEndpointError.networkFailure }
        return epoch
    }
    func publishIntent(deviceID: DeviceID, version: V2PushIntentVersion, intent: V2ClientPushIntent) async throws {
        publishAttempts += 1
        inFlight += 1; maximumInFlight = max(maximumInFlight, inFlight)
        defer { inFlight -= 1 }
        if hold {
            hold = false
            await withTaskCancellationHandler { await withCheckedContinuation { continuation = $0 } } onCancel: {
                Task { await self.recordCancellation() }
            }
        }
        if let error = publishFailure { publishFailure = nil; throw error }
        publications.append(version)
        switch intent {
        case .disabled: enabled = false; token = nil
        case .enabled(_, _, let value): enabled = true; token = value
        }
    }
}

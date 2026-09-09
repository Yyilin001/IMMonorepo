import Foundation
import IMV2Core

public enum V2PushReconcileResult: Equatable, Sendable {
    case idle, advanced, superseded, retryScheduled, paused
}

/// One account/installation owner. Local inputs coalesce independently from
/// the one HTTP flight so an opt-out is persisted while an old PUT is pending.
public actor V2PushIntentReconciler {
    private struct Token: Sendable {
        let id: UUID; let provider: V2ClientPushEndpointProvider
        let environment: V2ClientPushEndpointEnvironment; let value: String
    }
    private let store: GRDBV2LocalSyncStore
    private let transport: any V2ClientPushIntentPublishing
    private let scope: V2PushIntentScope
    private let ownerID: UUID
    private let now: @Sendable () -> Date
    private var preference: Bool
    private var desired: Bool
    private var token: Token?
    private var inputID = UUID()
    private var persistedInputID: UUID?
    private var inputTask: (UUID, Task<Void, any Error>)?
    private var flight: (UUID, Task<V2PushReconcileResult, any Error>)?
    private var runTask: (UUID, Task<Void, any Error>)?
    private var stopped = false
    private var signingOut = false

    /// The caller must validate its current authentication lifecycle before
    /// acquisition and after this await; a stale CAS is never retried here.
    public static func activate(store: GRDBV2LocalSyncStore, transport: any V2ClientPushIntentPublishing,
                                scope: V2PushIntentScope, initialPreference: Bool, now: @escaping @Sendable () -> Date = Date.init) async throws -> V2PushIntentReconciler {
        try Task.checkCancellation()
        let previous = try await store.inspectPushIntent(scope: scope)
        try Task.checkCancellation()
        let owner = UUID()
        let state = try await store.activatePushIntent(scope: scope, ownerID: owner, initialPreference: initialPreference, replacing: previous)
        try Task.checkCancellation()
        return .init(store: store, transport: transport, state: state, now: now)
    }

    private init(store: GRDBV2LocalSyncStore, transport: any V2ClientPushIntentPublishing, state: V2LocalPushIntent, now: @escaping @Sendable () -> Date) {
        self.store = store; self.transport = transport; scope = state.scope; ownerID = state.ownerID
        preference = state.preferenceEnabled; desired = state.desiredEnabled; self.now = now
        persistedInputID = inputID
    }

    public nonisolated func updates() -> AsyncThrowingStream<V2LocalPushIntent, any Error> {
        store.pushIntentUpdates(scope: scope, ownerID: ownerID)
    }

    public func state() async throws -> V2LocalPushIntent {
        try await store.pushIntent(scope: scope, ownerID: ownerID)
    }

    public func setEnabled(_ enabled: Bool) async throws {
        guard !stopped, !signingOut else { throw CancellationError() }
        if desired != enabled { token = nil }
        preference = enabled; desired = enabled; inputID = UUID()
        try await persistInputs()
    }

    public func receiveToken(provider: V2ClientPushEndpointProvider, environment: V2ClientPushEndpointEnvironment, value: String) async throws {
        guard !stopped, !signingOut else { throw CancellationError() }
        guard desired else { return }
        guard !value.isEmpty, value.utf8.count <= 4_096, value.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0) }) else { throw V2ClientPushEndpointError.invalidRegistration }
        if token?.provider == provider, token?.environment == environment, token?.value == value {
            try await persistInputs()
            return
        }
        token = .init(id: UUID(), provider: provider, environment: environment, value: value); inputID = UUID()
        try await persistInputs()
    }

    /// Persists the final disable before the caller clears credentials. A
    /// later token callback cannot reverse this owner's sign-out decision.
    public func prepareSignOut() async throws {
        guard !stopped else { throw CancellationError() }
        signingOut = true; desired = false; token = nil; inputID = UUID()
        try await persistInputs()
    }

    /// Explicit user/reauthentication recovery only. Stale never auto-reclaims.
    public func restartSession() async throws {
        guard !stopped else { throw CancellationError() }
        try await persistInputs()
        let current = try await state()
        try Task.checkCancellation()
        _ = try await store.restartPushIntentSession(expected: current)
    }

    public func run() async throws {
        guard !stopped else { throw CancellationError() }
        let current: (UUID, Task<Void, any Error>)
        if let runTask { current = runTask }
        else {
            current = (UUID(), Task { [self] in
                try await V2CommandRetryScheduler(schedule: store.pushIntentSchedule(scope: scope, ownerID: ownerID), flush: { [self] in _ = try await flushOnce() }, now: now).run()
            })
            runTask = current
        }
        let result = await withTaskCancellationHandler { await current.1.result } onCancel: {
            current.1.cancel()
            Task { await self.stop() }
        }
        if runTask?.0 == current.0 { runTask = nil }
        try Task.checkCancellation()
        try result.get()
    }

    public func flushOnce() async throws -> V2PushReconcileResult {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        let current: (UUID, Task<V2PushReconcileResult, any Error>)
        if let flight { current = flight }
        else { current = (UUID(), Task { [self] in try await flushOwned() }); flight = current }
        let result = await current.1.result
        if flight?.0 == current.0 { flight = nil }
        try Task.checkCancellation()
        return try result.get()
    }

    public func stop() async {
        stopped = true; token = nil
        let running = runTask, sending = flight, saving = inputTask
        running?.1.cancel(); sending?.1.cancel(); saving?.1.cancel()
        _ = await saving?.1.result; _ = await sending?.1.result; _ = await running?.1.result
    }

    private func persistInputs() async throws {
        guard !stopped else { throw CancellationError() }
        while persistedInputID != inputID {
            let current: (UUID, Task<Void, any Error>)
            if let inputTask { current = inputTask }
            else { current = (UUID(), Task { [self] in try await persistLatestInput() }); inputTask = current }
            let result = await current.1.result
            if inputTask?.0 == current.0 { inputTask = nil }
            try Task.checkCancellation()
            try result.get()
            guard !stopped else { throw CancellationError() }
        }
    }

    private func persistLatestInput() async throws {
        while persistedInputID != inputID {
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            let id = inputID, pref = preference, target = desired, reference = token?.id
            let current = try await state()
            try Task.checkCancellation()
            guard id == inputID else { continue }
            let saved = try await store.savePushInput(preferenceEnabled: pref, desiredEnabled: target, tokenReference: reference, expected: current)
            if saved { persistedInputID = id }
        }
    }

    private func flushOwned() async throws -> V2PushReconcileResult {
        try await persistInputs()
        try Task.checkCancellation()
        let current = try await state()
        guard !stopped else { throw CancellationError() }
        guard current.pending, current.pauseReason == nil, !current.waitingForToken, current.nextAttemptAt <= now() else { return .idle }
        do {
            if current.claim == nil {
                let epoch = try await transport.intentEpoch(deviceID: scope.deviceID)
                try Task.checkCancellation()
                return try await store.savePushClaim(.init(requestID: UUID(), expectedEpoch: epoch), expected: current) ? .advanced : .superseded
            }
            if current.epoch == nil, let claim = current.claim {
                let epoch = try await transport.claimIntentSession(deviceID: scope.deviceID, claim: claim)
                try Task.checkCancellation()
                return try await store.completePushClaim(epoch: epoch, expected: current) ? .advanced : .superseded
            }
            guard let version = current.version else { throw V2LocalPushIntentError.invalidState }
            let intent: V2ClientPushIntent
            if current.desiredEnabled {
                guard let token, token.id == current.tokenReference else { return .superseded }
                intent = .enabled(provider: token.provider, environment: token.environment, token: token.value)
            } else { intent = .disabled }
            try await transport.publishIntent(deviceID: scope.deviceID, version: version, intent: intent)
            try Task.checkCancellation()
            return try await store.acknowledgePushIntent(current) ? .advanced : .superseded
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            let pause: V2PushIntentPauseReason?
            switch error {
            case V2ClientPushEndpointError.authorizationDenied: pause = .authorization
            case V2ClientPushEndpointError.staleIntent, V2ClientPushEndpointError.intentVersionRequired: pause = .staleSession
            case V2ClientPushEndpointError.intentConflict, V2ClientPushEndpointError.invalidRegistration, V2ClientPushEndpointError.invalidResponse, is V2PushIntentVersionError: pause = .conflictingIntent
            default: pause = nil
            }
            if let pause {
                let saved = try await store.pausePushIntent(pause, expected: current)
                if pause == .authorization { throw error }
                return saved ? .paused : .superseded
            }
            var delay = min(60, pow(2, Double(min(current.attemptCount, 6))))
            if case V2ClientPushEndpointError.rateLimited(let minimum) = error, minimum.isFinite, minimum > 0 { delay = max(delay, minimum) }
            return try await store.retryPushIntent(at: now().addingTimeInterval(delay), expected: current) ? .retryScheduled : .superseded
        }
    }
}

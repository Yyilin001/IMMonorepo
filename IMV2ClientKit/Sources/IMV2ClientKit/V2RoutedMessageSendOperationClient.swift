import Foundation
import IMV2Core

public enum V2MessageSendTransportMode: String, Sendable {
    case automatic, httpOnly, realtimeOnly
}

/// Certainty describes whether another submit could duplicate work without recovery.
public enum V2MessageSendTransportError: Error, Equatable, Sendable {
    case unavailableBeforeSubmission
    case outcomeUnknown
    case authenticationRequired
    case invalidResponse
    case unsupportedCapability
    case retryAfter(Date)
}

/// A session witness must be read from the connection immediately before the request.
public struct V2MessageSendRealtimeReadiness: Equatable, Sendable {
    public let generation: UUID
    public let accountID: UserID
    public let deviceID: DeviceID
    public let protocolVersion: UInt8
    public let maximumPayloadBytes: Int

    public init(generation: UUID, accountID: UserID, deviceID: DeviceID,
                protocolVersion: UInt8, maximumPayloadBytes: Int) {
        self.generation = generation
        self.accountID = accountID
        self.deviceID = deviceID
        self.protocolVersion = protocolVersion
        self.maximumPayloadBytes = maximumPayloadBytes
    }
}

public protocol V2MessageSendRealtimeClient: V2MessageSendOperationClient {
    func readiness() async -> V2MessageSendRealtimeReadiness?
    func canSubmit(_ command: V2MessageSendOperationCommand) async throws -> Bool
}

public extension V2MessageSendRealtimeClient {
    func canSubmit(_: V2MessageSendOperationCommand) async throws -> Bool { true }
}

public struct V2MessageSendRouteObservation: Sendable {
    public enum Transport: Sendable { case tcp, http }
    public enum Result: Sendable { case receipt, deferred, unresolved, fingerprintConflict, unavailable, unknown, failed, cancelled }
    public enum Reason: Sendable { case selected, recovery, absentSession, cooldown, payloadLimit, forcedMode }
    public let transport: Transport
    public let action: V2OperationWorkAction
    public let result: Result
    public let reason: Reason
}

/// Selects one physical transport per durable claim. A later claim owns any fallback.
public actor V2RoutedMessageSendOperationClient: V2MessageSendOperationClient {
    private let realtime: any V2MessageSendRealtimeClient
    private let http: any V2MessageSendOperationClient
    private let mode: V2MessageSendTransportMode
    private let accountID: UserID
    private var recentFailures: [(generation: UUID, time: Date)] = []
    private var httpPreferredUntil: Date = .distantPast
    private var observations: [V2MessageSendRouteObservation] = []

    public init(accountID: UserID, realtime: any V2MessageSendRealtimeClient,
                http: any V2MessageSendOperationClient, mode: V2MessageSendTransportMode = .automatic) {
        self.accountID = accountID
        self.realtime = realtime
        self.http = http
        self.mode = mode
    }

    public func submit(_ command: V2MessageSendOperationCommand) async throws -> V2MessageSendOperationRecoveryResult {
        try await execute(accountID: command.command.senderUserID, isRecovery: false, command: command) { client in
            try await client.submit(command)
        }
    }

    public func recover(_ request: V2MessageSendOperationRecoveryRequest) async throws -> V2MessageSendOperationRecoveryResult {
        try await execute(accountID: request.identity.accountID, isRecovery: true, command: nil) { client in
            try await client.recover(request)
        }
    }

    public func routeObservations() -> [V2MessageSendRouteObservation] { observations }

    private func execute(accountID requestedAccount: UserID, isRecovery: Bool, command: V2MessageSendOperationCommand?,
                         operation: (any V2MessageSendOperationClient) async throws -> V2MessageSendOperationRecoveryResult) async throws -> V2MessageSendOperationRecoveryResult {
        try Task.checkCancellation()
        guard requestedAccount == accountID else { throw V2OperationWorkError.accountMismatch }
        let useHTTP: Bool
        let reason: V2MessageSendRouteObservation.Reason
        var selectedGeneration: UUID?
        switch mode {
        case .httpOnly: useHTTP = true; reason = .forcedMode
        case .realtimeOnly: useHTTP = false; reason = .forcedMode
        case .automatic:
            var ready = await realtime.readiness()
            if ready == nil && !isRecovery && Date() >= httpPreferredUntil {
                for _ in 0..<3 {
                    try await Task.sleep(for: .milliseconds(100))
                    ready = await realtime.readiness()
                    if ready != nil { break }
                }
            }
            let payloadNeedsHTTP = if let command, ready != nil {
                !(try await realtime.canSubmit(command))
            } else { false }
            selectedGeneration = ready?.generation
            // A persisted reconciliation may follow a process restart, so HTTP is
            // the stable recovery path for automatic mode.
            useHTTP = payloadNeedsHTTP || isRecovery || ready?.accountID != accountID || Date() < httpPreferredUntil
            if isRecovery { reason = .recovery }
            else if payloadNeedsHTTP { reason = .payloadLimit }
            else if ready?.accountID != accountID { reason = .absentSession }
            else if Date() < httpPreferredUntil { reason = .cooldown }
            else { reason = .selected }
        }
        let action: V2OperationWorkAction = isRecovery ? .reconcile : .submit
        try Task.checkCancellation()
        if useHTTP {
            do {
                let result = try await operation(http)
                record(.http, action, Self.resultKind(result), reason)
                return result
            } catch {
                if Task.isCancelled { record(.http, action, .cancelled, reason); throw CancellationError() }
                let classified = Self.classifyHTTP(error)
                record(.http, action, Self.errorKind(classified), reason)
                throw classified
            }
        }
        do {
            let result = try await operation(realtime)
            record(.tcp, action, Self.resultKind(result), reason)
            return result
        } catch {
            if Task.isCancelled { record(.tcp, action, .cancelled, reason); throw CancellationError() }
            record(.tcp, action, Self.errorKind(error), reason)
            if let failure = error as? V2MessageSendTransportError {
                switch failure {
                case .outcomeUnknown:
                    await recordRealtimeFailure(generation: selectedGeneration)
                case .unavailableBeforeSubmission:
                    await recordRealtimeFailure(generation: selectedGeneration)
                    let current = await realtime.readiness()
                    if mode == .automatic, current == nil || current?.generation == selectedGeneration {
                        httpPreferredUntil = max(httpPreferredUntil, Date().addingTimeInterval(1))
                    }
                default: break
                }
                throw failure
            }
            throw error
        }
    }

    private func record(_ transport: V2MessageSendRouteObservation.Transport, _ action: V2OperationWorkAction,
                        _ result: V2MessageSendRouteObservation.Result, _ reason: V2MessageSendRouteObservation.Reason) {
        observations.append(.init(transport: transport, action: action, result: result, reason: reason))
        if observations.count > 64 { observations.removeFirst(observations.count - 64) }
    }

    private static func resultKind(_ result: V2MessageSendOperationRecoveryResult) -> V2MessageSendRouteObservation.Result {
        switch result {
        case .receipt: .receipt
        case .deferred: .deferred
        case .unresolved: .unresolved
        case .fingerprintConflict: .fingerprintConflict
        }
    }

    private static func errorKind(_ error: any Error) -> V2MessageSendRouteObservation.Result {
        switch error as? V2MessageSendTransportError {
        case .unavailableBeforeSubmission: .unavailable
        case .outcomeUnknown: .unknown
        default: .failed
        }
    }

    private func recordRealtimeFailure(generation: UUID?) async {
        guard let generation else { return }
        if let current = await realtime.readiness(), current.generation != generation { return }
        let now = Date()
        recentFailures.removeAll { now.timeIntervalSince($0.time) > 30 }
        guard !recentFailures.contains(where: { $0.generation == generation }) else { return }
        recentFailures.append((generation, now))
        if recentFailures.count > 2 { recentFailures.removeFirst(recentFailures.count - 2) }
        if recentFailures.count >= 2 { httpPreferredUntil = now.addingTimeInterval(30) }
    }

    private static func classifyHTTP(_ error: any Error) -> any Error {
        guard let failure = error as? V2HTTPFailure else { return error }
        if failure.statusCode == 401 { return V2MessageSendTransportError.authenticationRequired }
        if let retryAfter = failure.retryAfter { return V2MessageSendTransportError.retryAfter(retryAfter) }
        switch failure.kind {
        case .invalidEndpoint, .invalidResponse, .responseTooLarge: return V2MessageSendTransportError.invalidResponse
        default:
            return failure.certainty == .notStarted ? V2MessageSendTransportError.unavailableBeforeSubmission : V2MessageSendTransportError.outcomeUnknown
        }
    }
}

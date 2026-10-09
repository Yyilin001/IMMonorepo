import Foundation
import IMV2Core

/// Certainty describes whether another submit could duplicate work without recovery.
public enum V2MessageSendTransportError: Error, Equatable, Sendable {
    case unavailableBeforeSubmission
    case busyBeforeSubmission(Date)
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
    public enum Result: Sendable { case receipt, deferred, unresolved, fingerprintConflict, unavailable, unknown, failed, cancelled }
    public enum Reason: Sendable { case selected, recovery, absentSession, payloadLimit }
    public let action: V2OperationWorkAction
    public let result: Result
    public let reason: Reason
}

/// Product message operations retain one identity on TCP for submission and recovery.
public actor V2RoutedMessageSendOperationClient: V2MessageSendOperationClient {
    private let realtime: any V2MessageSendRealtimeClient
    private let accountID: UserID
    private var observations: [V2MessageSendRouteObservation] = []

    public init(accountID: UserID, realtime: any V2MessageSendRealtimeClient) {
        self.accountID = accountID
        self.realtime = realtime
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
        let ready = await realtime.readiness()
        let reason: V2MessageSendRouteObservation.Reason = isRecovery ? .recovery :
            (ready?.accountID == accountID ? .selected : .absentSession)
        let action: V2OperationWorkAction = isRecovery ? .reconcile : .submit
        try Task.checkCancellation()
        if let command, !(try await realtime.canSubmit(command)) {
            record(action, .failed, .payloadLimit)
            throw V2MessageSendTransportError.unsupportedCapability
        }
        do {
            let result = try await operation(realtime)
            record(action, Self.resultKind(result), reason)
            return result
        } catch {
            if Task.isCancelled { record(action, .cancelled, reason); throw CancellationError() }
            record(action, Self.errorKind(error), reason)
            throw error
        }
    }

    private func record(_ action: V2OperationWorkAction,
                        _ result: V2MessageSendRouteObservation.Result, _ reason: V2MessageSendRouteObservation.Reason) {
        observations.append(.init(action: action, result: result, reason: reason))
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

}

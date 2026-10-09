import Foundation
import IMV2Core

/// Shares the sync transport's request counter and the authenticated socket.
public struct V2ProtobufMessageSendOperationClient: V2MessageSendRealtimeClient {
    private let transport: V2ProtobufSyncTransport
    private let connection: V2TLSFrameConnection

    public init(transport: V2ProtobufSyncTransport, connection: V2TLSFrameConnection) {
        self.transport = transport
        self.connection = connection
    }

    public func readiness() async -> V2MessageSendRealtimeReadiness? {
        await connection.messageSendSession()
    }

    public func canSubmit(_ command: V2MessageSendOperationCommand) async throws -> Bool {
        guard let session = await connection.messageSendSession() else { return true }
        var envelope = IMV2Envelope()
        envelope.messageSendOperation = try V2MessageSendOperationWireCodec.encode(command: command)
        return try serializedSize(envelope, version: session.protocolVersion) <= session.maximumPayloadBytes
    }

    public func submit(_ command: V2MessageSendOperationCommand) async throws -> V2MessageSendOperationRecoveryResult {
        var envelope = IMV2Envelope()
        envelope.messageSendOperation = try V2MessageSendOperationWireCodec.encode(command: command)
        return try await send(envelope, accountID: command.command.senderUserID,
                              identity: command.identity, fingerprint: command.fingerprint)
    }

    public func recover(_ request: V2MessageSendOperationRecoveryRequest) async throws -> V2MessageSendOperationRecoveryResult {
        var envelope = IMV2Envelope()
        envelope.messageSendOperationRecover = V2MessageSendOperationWireCodec.encode(recovery: request)
        return try await send(envelope, accountID: request.identity.accountID,
                              identity: request.identity, fingerprint: request.fingerprint)
    }

    private func send(_ envelope: IMV2Envelope, accountID: UserID,
                      identity: V2OperationIdentity, fingerprint: V2OperationFingerprint) async throws -> V2MessageSendOperationRecoveryResult {
        try Task.checkCancellation()
        guard let session = await connection.messageSendSession() else {
            throw V2MessageSendTransportError.unavailableBeforeSubmission
        }
        guard session.accountID == accountID else { throw V2MessageSendTransportError.authenticationRequired }
        guard try serializedSize(envelope, version: session.protocolVersion) <= session.maximumPayloadBytes else {
            throw V2MessageSendTransportError.unsupportedCapability
        }
        try await connection.requireMessageSendSession(session)
        let response: IMV2Envelope
        do {
            response = try await V2MessageSendConnectionScope.$generation.withValue(session.generation) {
                try await transport.requestEnvelope(envelope, maximumMessageSendPayloadBytes: session.maximumPayloadBytes)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as V2MessageSendTransportError {
            throw error
        } catch let error as V2TLSFrameConnectionError {
            switch error {
            case .notConnected:
                throw V2MessageSendTransportError.unavailableBeforeSubmission
            case .tooManyPendingRequests:
                throw V2MessageSendTransportError.busyBeforeSubmission(Date().addingTimeInterval(0.5))
            case .authenticationFailed:
                throw V2MessageSendTransportError.authenticationRequired
            default:
                throw V2MessageSendTransportError.outcomeUnknown
            }
        } catch let error as V2RealtimeTransportError {
            if case .server(let code, let retryable, let retryAfterSeconds, _) = error,
               retryable || code == "SERVER_BUSY" || retryAfterSeconds > 0 {
                throw V2MessageSendTransportError.retryAfter(Date().addingTimeInterval(max(0.5, TimeInterval(retryAfterSeconds))))
            }
            throw V2MessageSendTransportError.invalidResponse
        } catch {
            // Once requestEnvelope starts, local decoding failures cannot prove
            // whether the server committed the command.
            throw V2MessageSendTransportError.outcomeUnknown
        }
        return try Self.decodeCorrelatedResponse(response, identity: identity, fingerprint: fingerprint)
    }

    /// Only called after requestEnvelope has verified the request ID and wire
    /// version. SERVER_BUSY is emitted before message dispatch by Gateway's
    /// connection/process budget or foreground admission; UNAVAILABLE can also
    /// represent a lost COMMIT acknowledgement and does not prove rejection.
    static func decodeCorrelatedResponse(_ response: IMV2Envelope,
        identity: V2OperationIdentity, fingerprint: V2OperationFingerprint
    ) throws -> V2MessageSendOperationRecoveryResult {
        if case .error(let error)? = response.body {
            if error.code == "SERVER_BUSY" {
                return .deferred(try .init(identity: identity, fingerprint: fingerprint,
                    reason: .admissionUnavailable,
                    retryAfterMilliseconds: max(500, UInt64(error.retryAfterSeconds) * 1_000)))
            }
            if error.retryable || error.retryAfterSeconds > 0 {
                throw V2MessageSendTransportError.retryAfter(Date().addingTimeInterval(max(0.5, TimeInterval(error.retryAfterSeconds))))
            }
            if error.code == "UNAUTHENTICATED" { throw V2MessageSendTransportError.authenticationRequired }
            throw V2MessageSendTransportError.invalidResponse
        }
        guard case .messageSendOperationResult(let wire)? = response.body else {
            throw V2MessageSendTransportError.invalidResponse
        }
        let result: V2MessageSendOperationRecoveryResult
        do { result = try V2MessageSendOperationWireCodec.decode(result: wire) }
        catch { throw V2MessageSendTransportError.invalidResponse }
        switch result {
        case .receipt(let receipt):
            guard receipt.validates(identity: identity, fingerprint: fingerprint) else { throw V2MessageSendTransportError.invalidResponse }
        case .deferred(let hint):
            guard hint.validates(identity: identity, fingerprint: fingerprint) else { throw V2MessageSendTransportError.invalidResponse }
        case .unresolved, .fingerprintConflict: break
        }
        return result
    }

    private func serializedSize(_ envelope: IMV2Envelope, version: UInt8) throws -> Int {
        var sized = envelope
        sized.requestID = UInt64.max
        sized.protocolVersion = UInt32(version)
        return try sized.serializedData().count
    }
}

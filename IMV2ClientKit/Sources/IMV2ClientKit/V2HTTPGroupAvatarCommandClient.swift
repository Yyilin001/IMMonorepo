import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

public protocol V2GroupAvatarCommandSubmitting: Sendable {
    /// The caller persists the command before submission and reuses it for recovery.
    func submitGroupAvatar(_ command: V2GroupAvatarCommand) async throws -> V2GroupAvatarCommandResponse
}

public protocol V2GroupAvatarOperationRecovering: Sendable {
    /// Only a response bound to the complete request proves a permanent outcome.
    func recoverGroupAvatar(_ request: V2GroupAvatarRecoveryRequest) async throws -> V2GroupAvatarRecoveryResponse
}

public enum V2GroupAvatarSubmissionError: Error, Equatable, Sendable {
    case authorizationUnavailable
    case outcomeUnknown
    case invalidResponse
    /// A status hint, not a closure proof. Resolve through the recovery endpoint.
    case operationClosed
    case throttled(retryAfter: TimeInterval)
}

/// Business commands carry only logical identities. Provider plans and upload
/// credentials belong to the separate resource transfer client.
public struct V2HTTPGroupAvatarCommandClient: V2GroupAvatarCommandSubmitting, V2GroupAvatarOperationRecovering {
    private let roomsEndpoint: URL
    private let actorUserID: UserID
    private let credentials: any V2ClientMediaEdgeCredentialProvider
    private let transport: any V2ClientMediaEdgeHTTPTransport

    public init(roomsEndpoint: URL, actorUserID: UserID, credentials: any V2ClientMediaEdgeCredentialProvider,
                transport: any V2ClientMediaEdgeHTTPTransport) throws {
        guard roomsEndpoint.scheme == "https", roomsEndpoint.host?.isEmpty == false,
              roomsEndpoint.user == nil, roomsEndpoint.password == nil, roomsEndpoint.fragment == nil,
              roomsEndpoint.query == nil, actorUserID.uuidValue != nil else { throw V2ClientMediaTransferError.invalidMediaEdgeEndpoint }
        self.roomsEndpoint = roomsEndpoint; self.actorUserID = actorUserID
        self.credentials = credentials; self.transport = transport
    }

    public func submitGroupAvatar(_ command: V2GroupAvatarCommand) async throws -> V2GroupAvatarCommandResponse {
        let endpoint = roomsEndpoint.appendingPathComponent(command.roomID.rawValue).appendingPathComponent("avatar")
        let (data, response, deviceID) = try await send(body: command, endpoint: endpoint)
        switch response.statusCode {
        case 200, 403, 409, 422: break
        case 410: throw V2GroupAvatarSubmissionError.operationClosed
        default: throw V2GroupAvatarSubmissionError.outcomeUnknown
        }
        guard data.count <= 16 * 1_024, V2HTTPContract.isJSON(response) else {
            throw V2GroupAvatarSubmissionError.invalidResponse
        }
        let value: V2GroupAvatarCommandResponse
        do { value = try JSONDecoder().decode(V2GroupAvatarCommandResponse.self, from: data) }
        catch {
            // A control-domain denial is deliberately not a room receipt.
            if response.statusCode == 403 { throw V2GroupAvatarSubmissionError.authorizationUnavailable }
            throw V2GroupAvatarSubmissionError.invalidResponse
        }
        guard value.actorUserID == actorUserID, value.deviceID == deviceID, value.command == command else {
            throw V2GroupAvatarSubmissionError.invalidResponse
        }
        let expectedStatus: Int
        switch value.outcome {
        case .committed: expectedStatus = 200
        case .revisionConflict, .idempotencyConflict: expectedStatus = 409
        case .resourceUnavailable: expectedStatus = 422
        case .forbidden: expectedStatus = 403
        }
        guard response.statusCode == expectedStatus else { throw V2GroupAvatarSubmissionError.invalidResponse }
        return value
    }

    public func recoverGroupAvatar(_ request: V2GroupAvatarRecoveryRequest) async throws -> V2GroupAvatarRecoveryResponse {
        let endpoint = roomsEndpoint.appendingPathComponent(request.command.roomID.rawValue)
            .appendingPathComponent("avatar").appendingPathComponent("recovery")
        let (data, response, deviceID) = try await send(body: request, endpoint: endpoint)
        if response.statusCode == 403 { throw V2GroupAvatarSubmissionError.authorizationUnavailable }
        guard response.statusCode == 200 else { throw V2GroupAvatarSubmissionError.outcomeUnknown }
        guard data.count <= 16 * 1_024, V2HTTPContract.isJSON(response) else { throw V2GroupAvatarSubmissionError.invalidResponse }
        let value: V2GroupAvatarRecoveryResponse
        do { value = try JSONDecoder().decode(V2GroupAvatarRecoveryResponse.self, from: data) }
        catch { throw V2GroupAvatarSubmissionError.invalidResponse }
        guard value.actorUserID == actorUserID, value.deviceID == deviceID, value.request == request else {
            throw V2GroupAvatarSubmissionError.invalidResponse
        }
        return value
    }

    private func send<Body: Encodable>(body: Body, endpoint: URL) async throws -> (Data, HTTPURLResponse, DeviceID) {
        try Task.checkCancellation()
        let identity = try await credentials.mediaEdgeCredentials()
        guard !identity.accessToken.isEmpty, identity.deviceID.uuidValue != nil,
              !identity.accessToken.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw V2GroupAvatarSubmissionError.authorizationUnavailable
        }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("Bearer \(identity.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(identity.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw V2GroupAvatarSubmissionError.outcomeUnknown }
        // Even cancellation after send does not prove that the room did not commit.
        try Task.checkCancellation()
        switch response.statusCode {
        case 401: throw V2GroupAvatarSubmissionError.authorizationUnavailable
        case 429:
            let raw = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 1
            throw V2GroupAvatarSubmissionError.throttled(retryAfter: raw.isFinite ? min(60, max(1, raw)) : 1)
        default: break
        }
        return (data, response, identity.deviceID)
    }
}

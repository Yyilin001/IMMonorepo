import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

/// Credentials and HTTP response handling for one account lifetime. Reuse the
/// same value for both client dependencies so old owners cannot borrow a new
/// login's credentials or deliver late responses into its presentation.
public struct V2SessionHTTPAuthorization: Sendable,
    V2ClientPushEndpointCredentialProvider, V2ClientDeviceSessionCredentialProvider,
    V2ClientMediaEdgeCredentialProvider, V2ClientPushEndpointHTTPTransport,
    V2ClientDeviceSessionHTTPTransport, V2ClientGroupInvitationHTTPTransport,
    V2ClientMediaEdgeHTTPTransport
{
    private let session: V2AuthSession
    private let epoch: V2AuthSessionEpoch
    private let transport: any V2AuthHTTPTransport

    public init(session: V2AuthSession, epoch: V2AuthSessionEpoch,
                transport: any V2AuthHTTPTransport = V2URLSessionAuthHTTPTransport()) {
        self.session = session
        self.epoch = epoch
        self.transport = transport
    }

    public func pushEndpointCredentials() async throws -> V2ClientPushEndpointCredentials {
        let credentials = try await credentials()
        return .init(accessToken: credentials.accessToken, deviceID: credentials.deviceID)
    }

    public func deviceSessionCredentials() async throws -> V2ClientDeviceSessionCredentials {
        let credentials = try await credentials()
        return .init(accessToken: credentials.accessToken, deviceID: credentials.deviceID)
    }

    public func mediaEdgeCredentials() async throws -> V2ClientMediaEdgeCredentials {
        let credentials = try await credentials()
        return .init(accessToken: credentials.accessToken, deviceID: credentials.deviceID)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await requireCurrent()
        guard let authorization = request.value(forHTTPHeaderField: "Authorization"),
              authorization.hasPrefix("Bearer "), authorization.count > 7,
              let rawDevice = request.value(forHTTPHeaderField: "X-IM-Device-ID"),
              let device = try? DeviceID(rawDevice)
        else { throw V2AuthSessionError.malformedCredentials }
        let result: (Data, HTTPURLResponse)
        do { result = try await transport.data(for: request) }
        catch {
            try await requireCurrent()
            if let urlError = error as? URLError, urlError.code == .cancelled { throw CancellationError() }
            throw error
        }
        try await requireCurrent()
        if result.1.statusCode == 401 {
            // An expired access token alone does not prove session revocation.
            // Only the refresh contract can make that terminal decision. Do
            // not replay an application write or one-use media grant here.
            do {
                try await session.refreshAfterHTTPUnauthorized(
                    ifCurrent: epoch, rejectedAccessToken: String(authorization.dropFirst(7)),
                    deviceID: device
                )
            } catch V2AuthSessionError.sessionInvalidated {
                throw CancellationError()
            }
            try await requireCurrent()
        }
        return result
    }

    private func credentials() async throws -> V2ClientRealtimeCredentials {
        try await requireCurrent()
        let credentials: V2ClientRealtimeCredentials
        do { credentials = try await session.realtimeCredentials() }
        catch {
            // Preserve terminal/locked-store errors from this epoch. A
            // replacement login is instead cancellation of the old owner.
            if case V2AuthSessionError.sessionInvalidated = error { throw CancellationError() }
            throw error
        }
        try await requireCurrent()
        guard credentials.sessionEpoch == epoch else { throw CancellationError() }
        return credentials
    }

    private func requireCurrent() async throws {
        try Task.checkCancellation()
        do { try await session.requireCurrentEpoch(epoch) }
        catch V2AuthSessionError.sessionInvalidated { throw CancellationError() }
        try Task.checkCancellation()
    }
}

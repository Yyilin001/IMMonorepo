import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

public protocol V2GroupAvatarPresentationReading: Sendable {
    func readGroupAvatar(roomID: RoomID) async throws -> V2GroupAvatarPresentation
}
public enum V2GroupAvatarReadError: Error, Equatable, Sendable {
    case forbidden, unavailable, invalidResponse, throttled(retryAfter: TimeInterval)
}

/// Uses only the account API and portable resource plans. No provider SDK or persistent capability cache.
public struct V2HTTPGroupAvatarPresentationClient: V2GroupAvatarPresentationReading {
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
    public func readGroupAvatar(roomID: RoomID) async throws -> V2GroupAvatarPresentation {
        try Task.checkCancellation()
        guard roomID.uuidValue != nil else { throw V2GroupAvatarReadError.invalidResponse }
        let identity = try await credentials.mediaEdgeCredentials()
        guard !identity.accessToken.isEmpty, identity.deviceID.uuidValue != nil,
              !identity.accessToken.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw V2ClientMediaTransferError.authorizationUnavailable
        }
        let endpoint = roomsEndpoint.appendingPathComponent(roomID.rawValue).appendingPathComponent("avatar")
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(identity.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(identity.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        switch response.statusCode {
        case 200: break
        case 401: throw V2ClientMediaTransferError.authorizationUnavailable
        case 403: throw V2GroupAvatarReadError.forbidden
        case 429:
            let raw = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 1
            throw V2GroupAvatarReadError.throttled(retryAfter: raw.isFinite ? min(60, max(1, raw)) : 1)
        default: throw V2GroupAvatarReadError.unavailable
        }
        guard V2HTTPContract.isJSON(response), data.count <= 64 * 1_024 else { throw V2GroupAvatarReadError.invalidResponse }
        let value: V2GroupAvatarPresentation
        do { value = try JSONDecoder().decode(V2GroupAvatarPresentation.self, from: data) }
        catch { throw V2GroupAvatarReadError.invalidResponse }
        guard value.actorUserID == actorUserID, value.deviceID == identity.deviceID, value.state.roomID == roomID else {
            throw V2GroupAvatarReadError.invalidResponse
        }
        if let plan = value.avatar?.plan {
            guard !plan.url.absoluteString.contains(identity.accessToken),
                  !plan.headers.contains(where: { $0.value.contains(identity.accessToken) }) else {
                throw V2ClientMediaTransferError.invalidTarget
            }
        }
        return value
    }
}

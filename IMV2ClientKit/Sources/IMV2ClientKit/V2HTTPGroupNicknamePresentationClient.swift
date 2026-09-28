import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

/// Memory-only page. Reading a snapshot after its monotonic deadline yields nil;
/// callers must also retain their account/page activation while rendering it.
public struct V2GroupNicknamePresentationPage: Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let deviceID: DeviceID
    public let userIDs: [UserID]
    public let nextCursor: UserID?
    public let unavailable: Set<UserID>
    public let retryable: Set<UserID>
    private let snapshots: [UserID: V2ProfilePresentationSnapshot]

    init(roomID: RoomID, actorUserID: UserID, deviceID: DeviceID, userIDs: [UserID], nextCursor: UserID?,
         unavailable: Set<UserID>, retryable: Set<UserID>, snapshots: [UserID: V2ProfilePresentationSnapshot]) {
        self.roomID = roomID; self.actorUserID = actorUserID; self.deviceID = deviceID
        self.userIDs = userIDs; self.nextCursor = nextCursor
        self.unavailable = unavailable; self.retryable = retryable; self.snapshots = snapshots
    }

    public func snapshot(for userID: UserID) -> V2ProfilePresentationSnapshot? {
        guard let value = snapshots[userID], value.deadline > .now else { return nil }
        return value
    }
}

/// A directory page is optional UI work, not a prerequisite for receiving a
/// message. Chat author rows continue to use the bounded explicit-key batch API.
public struct V2HTTPGroupNicknamePresentationClient: Sendable {
    private let groupsEndpoint: URL
    private let actorUserID: UserID
    private let credentials: any V2ClientMediaEdgeCredentialProvider
    private let transport: any V2ClientMediaEdgeHTTPTransport

    public init(groupsEndpoint: URL, actorUserID: UserID, credentials: any V2ClientMediaEdgeCredentialProvider,
                transport: any V2ClientMediaEdgeHTTPTransport) throws {
        guard groupsEndpoint.scheme == "https", groupsEndpoint.host?.isEmpty == false,
              groupsEndpoint.user == nil, groupsEndpoint.password == nil,
              groupsEndpoint.query == nil, groupsEndpoint.fragment == nil, actorUserID.uuidValue != nil
        else { throw V2ClientMediaTransferError.invalidMediaEdgeEndpoint }
        self.groupsEndpoint = groupsEndpoint; self.actorUserID = actorUserID
        self.credentials = credentials; self.transport = transport
    }

    public func read(roomID: RoomID, afterUserID: UserID? = nil, limit: Int = 100) async throws -> V2GroupNicknamePresentationPage {
        try Task.checkCancellation()
        guard roomID.uuidValue != nil, afterUserID == nil || afterUserID?.uuidValue != nil,
              (1...V2ProfileViewLookupLimits.maximumKeys).contains(limit)
        else { throw V2ProfilePresentationError.invalidResponse }
        let started = ContinuousClock.now
        let identity = try await credentials.mediaEdgeCredentials()
        guard !identity.accessToken.isEmpty, identity.deviceID.uuidValue != nil,
              !identity.accessToken.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
        else { throw V2ClientMediaTransferError.authorizationUnavailable }
        let endpoint = groupsEndpoint.appendingPathComponent(roomID.rawValue).appendingPathComponent("nicknames")
        guard var url = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw V2ClientMediaTransferError.invalidMediaEdgeEndpoint
        }
        url.queryItems = [.init(name: "limit", value: String(limit))]
        if let afterUserID { url.queryItems?.append(.init(name: "cursor", value: afterUserID.rawValue)) }
        guard let target = url.url else { throw V2ClientMediaTransferError.invalidMediaEdgeEndpoint }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer " + identity.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue(identity.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        V2HTTPRequestDeadline.attach(identity.requestDeadline, to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        switch response.statusCode {
        case 200: break
        case 401, 403: throw V2ClientMediaTransferError.authorizationUnavailable
        case 429:
            let delay = V2RetryAfter.delay(from: response.value(forHTTPHeaderField: "Retry-After"))
            throw V2ProfilePresentationError.throttled(retryAfter: delay)
        default: throw V2ClientMediaTransferError.invalidMediaEdgeResponse
        }
        guard V2HTTPContract.isJSON(response), data.count <= 256 * 1_024 else { throw V2ProfilePresentationError.invalidResponse }
        let page: V2GroupNicknamePresentationPageResponse
        do { page = try JSONDecoder().decode(V2GroupNicknamePresentationPageResponse.self, from: data) }
        catch { throw V2ProfilePresentationError.invalidResponse }
        guard page.roomID == roomID, page.batch.results.count <= limit,
              page.nextCursor == nil || page.batch.results.count == limit,
              page.batch.results.allSatisfy({ afterUserID == nil || $0.key.userID.rawValue > afterUserID!.rawValue })
        else { throw V2ProfilePresentationError.invalidResponse }
        var snapshots: [UserID: V2ProfilePresentationSnapshot] = [:]
        var unavailable = Set<UserID>(), retryable = Set<UserID>()
        for result in page.batch.results {
            switch result {
            case .presentation(let value, _):
                guard value.lease.actorUserID == actorUserID, value.lease.deviceID == identity.deviceID else {
                    throw V2ProfilePresentationError.invalidResponse
                }
                let deadline = started + .milliseconds(value.lease.validUntilUnixMilliseconds - page.batch.serverNowUnixMilliseconds)
                if deadline > .now {
                    snapshots[value.view.userID] = .init(presentation: value, deadline: deadline, avatar: nil, avatarDeadline: nil)
                } else { retryable.insert(value.view.userID) }
            case .unavailable(let key): unavailable.insert(key.userID)
            case .retryable(let key): retryable.insert(key.userID)
            }
        }
        return .init(roomID: roomID, actorUserID: actorUserID, deviceID: identity.deviceID,
            userIDs: page.batch.results.map { $0.key.userID }, nextCursor: page.nextCursor,
            unavailable: unavailable, retryable: retryable, snapshots: snapshots)
    }
}

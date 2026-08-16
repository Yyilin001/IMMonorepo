import Foundation
import IMV2Core
import IMV2Server
import Vapor

public struct V2DeviceSessionHTTPResponse: Content, Sendable {
    public let deviceID: String
    public let deviceName: String
    public let platform: String
    public let createdAtMilliseconds: Int64
    public let lastActiveAtMilliseconds: Int64
    public let isCurrentDevice: Bool
}

public struct V2DeviceSessionPageHTTPResponse: Content, Sendable {
    public let sessions: [V2DeviceSessionHTTPResponse]
    public let nextCursor: String?
}

private struct V2DeviceSessionPageHTTPQuery: Content {
    let cursor: String?
    let pageSize: Int?

    enum CodingKeys: String, CodingKey {
        case cursor
        case pageSize = "page_size"
    }
}

public struct V2DeviceSessionMutationHTTPRequest: Content, Sendable {
    public let deviceID: String?
    public let operationID: UUID
    public init(deviceID: String? = nil, operationID: UUID) { self.deviceID = deviceID; self.operationID = operationID }
}

/// Authenticated account-session APIs. All responses are no-store because a
/// session inventory is security-sensitive account metadata.
public struct V2VaporDeviceSessionRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let sessions: any V2DeviceSessionManaging

    public init(authenticator: any V2GatewayAuthenticator, sessions: any V2DeviceSessionManaging) {
        self.authenticator = authenticator
        self.sessions = sessions
    }

    public func register(on routes: RoutesBuilder) {
        routes.get("v2", "devices") { request async throws -> Response in
            let identity = try await authenticate(request)
            let query: V2DeviceSessionPageHTTPQuery
            do { query = try request.query.decode(V2DeviceSessionPageHTTPQuery.self) }
            catch { throw Abort(.badRequest) }
            let pageSize = query.pageSize ?? 50
            guard (1 ... 100).contains(pageSize) else { throw Abort(.badRequest) }
            do {
                let page = try await sessions.sessions(for: identity.userID, cursor: query.cursor, pageSize: pageSize)
                let values = try page.sessions.map { value in
                    try V2DeviceSessionHTTPResponse(
                        deviceID: value.deviceID.rawValue,
                        deviceName: value.displayName,
                        platform: value.platform,
                        createdAtMilliseconds: milliseconds(value.createdAt),
                        lastActiveAtMilliseconds: milliseconds(value.lastActiveAt),
                        isCurrentDevice: value.deviceID == identity.deviceID
                    )
                }
                return try noStoreJSON(.init(sessions: values, nextCursor: page.nextCursor))
            } catch V2DeviceSessionServiceError.invalidRequest {
                throw Abort(.badRequest)
            } catch {
                throw Abort(.serviceUnavailable)
            }
        }

        routes.post("v2", "devices", "revoke") { request async throws -> Response in
            let identity = try await authenticate(request)
            let input = try request.content.decode(V2DeviceSessionMutationHTTPRequest.self)
            guard let rawDeviceID = input.deviceID, let target = try? DeviceID(rawDeviceID) else { throw Abort(.badRequest) }
            let result: V2DeviceSessionMutationOutcome
            do { result = try await sessions.revokeDevice(actorUserID: identity.userID, currentDeviceID: identity.deviceID, targetDeviceID: target, operationID: input.operationID) }
            catch { throw Abort(.serviceUnavailable) }
            guard result != .targetUnavailable else { throw Abort(.notFound) }
            return noStoreNoContent()
        }

        routes.post("v2", "devices", "revoke-others") { request async throws -> Response in
            let identity = try await authenticate(request)
            let input = try request.content.decode(V2DeviceSessionMutationHTTPRequest.self)
            guard input.deviceID == nil else { throw Abort(.badRequest) }
            let result: V2DeviceSessionMutationOutcome
            do { result = try await sessions.revokeOtherDevices(actorUserID: identity.userID, currentDeviceID: identity.deviceID, operationID: input.operationID) }
            catch { throw Abort(.serviceUnavailable) }
            guard result != .targetUnavailable else { throw Abort(.unauthorized) }
            return noStoreNoContent()
        }
    }

    private func authenticate(_ request: Request) async throws -> V2AuthenticatedConnection {
        guard let accessToken = request.headers.bearerAuthorization?.token,
              let rawDeviceID = request.headers.first(name: "X-IM-Device-ID"),
              let deviceID = try? DeviceID(rawDeviceID)
        else { throw Abort(.unauthorized) }
        do {
            let userID = try await authenticator.authenticateSession(accessToken: accessToken, deviceID: deviceID).userID
            return .init(userID: userID, deviceID: deviceID, capabilityProfile: "account-edge")
        } catch { throw Abort(.unauthorized) }
    }

    private func milliseconds(_ date: Date) throws -> Int64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite, value >= Double(Int64.min), value <= Double(Int64.max) else { throw V2DeviceSessionServiceError.malformedPersistence }
        return Int64(value.rounded(.towardZero))
    }

    private func noStoreJSON(_ body: V2DeviceSessionPageHTTPResponse) throws -> Response {
        let data = try JSONEncoder().encode(body)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json")
        headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        headers.replaceOrAdd(name: "Pragma", value: "no-cache")
        return .init(status: .ok, headers: headers, body: .init(data: data))
    }

    private func noStoreNoContent() -> Response {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        headers.replaceOrAdd(name: "Pragma", value: "no-cache")
        return .init(status: .noContent, headers: headers)
    }
}

import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core
import Vapor
import HTTPTypes

/// 设备会话管理响应模型（会话清单接口）。
public struct V2DeviceSessionHTTPResponse: Content, Sendable {
    /// 设备 ID。
    public let deviceID: String
    /// 设备显示名。
    public let deviceName: String
    /// 设备平台。
    public let platform: String
    /// 创建时间（毫秒）。
    public let createdAtMilliseconds: Int64
    /// 最近活跃时间（毫秒）。
    public let lastActiveAtMilliseconds: Int64
    /// 当前请求是否为当前会话设备。
    public let isCurrentDevice: Bool
}

/// 设备会话分页响应。
public struct V2DeviceSessionPageHTTPResponse: Content, Sendable {
    /// 会话列表。
    public let sessions: [V2DeviceSessionHTTPResponse]
    /// 翻页游标。
    public let nextCursor: String?
}

/// 设备会话变更请求模型。
/// - deviceID: 指定目标设备；`revoke-current`/`revoke-others` 不应提供 deviceID。
private struct V2DeviceSessionPageHTTPQuery: Content {
    let cursor: String?
    let pageSize: Int?

    enum CodingKeys: String, CodingKey {
        case cursor
        case pageSize = "page_size"
    }
}

/// 设备会话变更请求体。
/// 可用于撤销单一设备、撤销当前设备、或批量撤销其他设备。
public struct V2DeviceSessionMutationHTTPRequest: Content, Sendable {
    /// 目标设备 ID，`revoke-current`/`revoke-others` 约定为空。
    public let deviceID: String?
    /// 幂等 ID。
    public let operationID: UUID
    public init(deviceID: String? = nil, operationID: UUID) { self.deviceID = deviceID; self.operationID = operationID }
}

/// 已鉴权账号会话管理路由。
///
/// 读写会话列表与会话撤销操作，响应均加 `no-store` 以避免缓存账号级敏感元数据。
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
            catch { throw Abort(.badRequest, headers: noStoreHeaders()) }
            let pageSize = query.pageSize ?? 50
            guard (1 ... 100).contains(pageSize) else { throw Abort(.badRequest, headers: noStoreHeaders()) }
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
                throw Abort(.badRequest, headers: noStoreHeaders())
            } catch {
                throw Abort(.serviceUnavailable, headers: noStoreHeaders())
            }
        }



        routes.get("v2","devices","revocation-baseline") { request async throws -> Response in
            let identity=try await authenticate(request)
            do { return try remoteJSON(await sessions.remoteRevocationBaseline(actorUserID:identity.userID,currentDeviceID:identity.deviceID)) }
            catch V2DeviceSessionServiceError.authorizationDenied { throw Abort(.forbidden,headers:noStoreHeaders()) }
            catch { throw Abort(.serviceUnavailable,headers:noStoreHeaders()) }
        }
        routes.on(.post,"v2","devices","remote-revocations","submit",maxBodySize:"32kb") { request async throws -> Response in
            let identity=try await authenticate(request)
            let command:V2RemoteDeviceRevocationCommand=try await decodeRemote(request)
            try authorizeRemote(command,identity:identity)
            do { return try remoteJSON(await sessions.submitRemoteRevocation(command)) }
            catch { throw Abort(.serviceUnavailable,headers:noStoreHeaders()) }
        }
        routes.on(.post,"v2","devices","remote-revocations","operations","recover",maxBodySize:"32kb") { request async throws -> Response in
            let identity=try await authenticate(request)
            let input:V2RemoteDeviceRevocationRecoveryRequest=try await decodeRemote(request)
            try authorizeRemote(input.command,identity:identity)
            do { return try remoteJSON(await sessions.recoverRemoteRevocation(input)) }
            catch { throw Abort(.serviceUnavailable,headers:noStoreHeaders()) }
        }

        routes.post("v2", "devices", "revoke-current") { request async throws -> Response in
            let identity = try await authenticate(request)
            let input = try await request.content.decode(V2DeviceSessionMutationHTTPRequest.self)
            guard input.deviceID == nil else { throw Abort(.badRequest) }
            let result: V2DeviceSessionMutationOutcome
            do { result = try await sessions.revokeCurrentDevice(actorUserID: identity.userID, currentDeviceID: identity.deviceID, operationID: input.operationID) }
            catch { throw Abort(.serviceUnavailable, headers: noStoreHeaders()) }
            guard result != .targetUnavailable else { throw Abort(.unauthorized) }
            return noStoreNoContent()
        }


    }

    private func decodeRemote<T:Decodable>(_ request:Request) async throws -> T {
        do {return try await request.content.decode(T.self,using:JSONDecoder())} catch {throw Abort(.badRequest,headers:noStoreHeaders())}
    }
    private func authorizeRemote(_ command:V2RemoteDeviceRevocationCommand,identity:V2AuthenticatedConnection) throws {
        guard command.baseline.actorUserID==identity.userID,command.baseline.currentDeviceID==identity.deviceID else {throw Abort(.forbidden,headers:noStoreHeaders())}
    }
    private func remoteJSON<T:Encodable>(_ value:T) throws -> Response {
        Response(status:.ok,headers:[.cacheControl:"no-store",.contentType:"application/json"],body:.init(data:try JSONEncoder().encode(value)))
    }

    /// 鉴权解析。
    private func authenticate(_ request: Request) async throws -> V2AuthenticatedConnection {
        try await request.v2AuthenticatedAccountIdentity(using: authenticator)
    }

    /// 将 `Date` 转为整数毫秒时间戳。
    private func milliseconds(_ date: Date) throws -> Int64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard let milliseconds = Int64(exactly: value.rounded(.towardZero)) else { throw V2DeviceSessionServiceError.malformedPersistence }
        return milliseconds
    }

    /// JSON no-store 响应。
    private func noStoreJSON(_ body: V2DeviceSessionPageHTTPResponse) throws -> Response {
        let data = try JSONEncoder().encode(body)
        var headers = noStoreHeaders()
        headers[.contentType] = "application/json"
        return .init(status: .ok, headers: headers, body: .init(data: data))
    }

    /// no-content with no-store 响应。
    private func noStoreNoContent() -> Response {
        .init(status: .noContent, headers: noStoreHeaders())
    }

    /// no-store 公共头。
    private func noStoreHeaders() -> HTTPFields {
        var headers = HTTPFields()
        headers[.cacheControl] = "no-store"
        headers[.v2Pragma] = "no-cache"
        return headers
    }
}

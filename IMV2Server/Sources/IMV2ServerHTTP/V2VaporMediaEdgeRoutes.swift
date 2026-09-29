import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core
import Vapor
import HTTPTypes

/// 媒体边缘下载查询适配器。
///
/// 该端点仅负责协议层适配，媒体访问权限最终由 `V2MediaEdgeHTTPHandler` 决定。
/// 不存在或无权限统一返回 404，避免区分“未找到”和“无权访问”。
public struct V2VaporMediaEdgeRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let handler: V2MediaEdgeHTTPHandler

    /// 初始化路由。
    ///
    /// - Parameters:
    ///   - authenticator: 鉴权来源。
    ///   - handler: 媒体边缘业务处理器。
    public init(authenticator: any V2GatewayAuthenticator, handler: V2MediaEdgeHTTPHandler) {
        self.authenticator = authenticator
        self.handler = handler
    }

    /// 挂载 `GET /v2/media/{mediaID}`。
    /// 该端点通常部署在独立 media-edge 监听器上。
    public func register(on routes: RoutesBuilder) {
        routes.get("v2", "media", ":mediaID") { request async throws -> Response in
            let identity = try await authenticate(request)
            guard let rawMediaID = request.parameters.get("mediaID") else {
                throw Abort(.badRequest)
            }
            let target: V2MediaDownloadTargetEnvelope
            do {
                target = try await handler.downloadTarget(
                    actorUserID: identity.userID,
                    deviceID: identity.deviceID,
                    rawMediaID: rawMediaID,
                    rawRoomID: request.query[String.self, at: "room_id"],
                    rawMessageID: request.query[String.self, at: "message_id"]
                )
            } catch let error as V2MediaEdgeHTTPHandlerError {
                switch error {
                case .invalidMediaID, .invalidMessageLocation:
                    throw Abort(.badRequest)
                case .invalidProviderTarget, .messageOwnerUnavailable:
                    throw Abort(.serviceUnavailable)
                }
            } catch is V2MediaStoreError {
                // 不要区分对象不存在与已认证调用方不再有权访问该对象。
                throw Abort(.notFound)
            } catch is V2MediaDownloadSessionStoreError {
                throw Abort(.notFound)
            } catch is V2MediaProviderSessionError {
                throw Abort(.serviceUnavailable)
            } catch {
                // 服务商和数据库实现故障，不得向客户端暴露详情或对象标识。
                throw Abort(.serviceUnavailable)
            }
            return try makeNoStoreJSONResponse(target)
        }
    }

    /// 鉴权上下文解析。
    private func authenticate(_ request: Request) async throws -> V2AuthenticatedConnection {
        try await request.v2AuthenticatedAccountIdentity(using: authenticator)
    }

    /// no-store JSON 响应，返回 `V2MediaDownloadTargetEnvelope`。
    private func makeNoStoreJSONResponse(_ target: V2MediaDownloadTargetEnvelope) throws -> Response {
        let data = try JSONEncoder().encode(target)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.cacheControl] = "no-store"
        headers[.v2Pragma] = "no-cache"
        return .init(status: .ok, headers: headers, body: .init(data: data))
    }
}

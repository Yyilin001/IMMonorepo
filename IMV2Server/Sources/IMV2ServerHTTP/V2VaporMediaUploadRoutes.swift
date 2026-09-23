import Foundation
import IMV2Core
import IMV2Server
import Vapor
import HTTPTypes

/// 媒体上传目标请求体。
///
/// - Parameters:
///   - operationID: 上传会话 ID。
///   - mediaID: 客户端声明的媒体 ID。
///   - contentType: 内容类型。
///   - byteCount: 期望字节数。
public struct V2MediaUploadTargetHTTPRequest: Content, Sendable {
    public let operationID: String
    public let mediaID: String
    public let contentType: String
    public let byteCount: Int64

    public init(operationID: String, mediaID: String, contentType: String, byteCount: Int64) {
        self.operationID = operationID
        self.mediaID = mediaID
        self.contentType = contentType
        self.byteCount = byteCount
    }
}

/// 媒体上传适配器。
///
/// 该路由只对已鉴权会话开放，运行在专用的 media-edge 监听器上，
/// 不接受客户端提供的对象存储地址，仅返回服务端分配的上传目标。
///
/// 响应固定返回 `no-store`，用于避免上传目标、状态等在中间层被缓存。
public struct V2VaporMediaUploadRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let handler: V2MediaEdgeUploadHTTPHandler

    /// 初始化。
    ///
    /// - Parameters:
    ///   - authenticator: 鉴权适配器。
    ///   - handler: 媒体上传处理器。
    public init(authenticator: any V2GatewayAuthenticator, handler: V2MediaEdgeUploadHTTPHandler) {
        self.authenticator = authenticator
        self.handler = handler
    }

    /// 挂载以下端点：
    /// - `POST /v2/media/uploads`：申请上传目标。
    /// - `POST /v2/media/{mediaID}/complete`：提交上传完成。
    /// - `GET /v2/media/{mediaID}/upload-status`：查询上传状态。
    public func register(on routes: RoutesBuilder) {
        routes.post("v2", "media", "uploads") { request async throws -> Response in
            let identity = try await authenticate(request)
            let input = try await request.content.decode(V2MediaUploadTargetHTTPRequest.self)
            let target: V2MediaUploadTargetEnvelope
            do {
                target = try await handler.uploadTarget(
                    actorUserID: identity.userID,
                    deviceID: identity.deviceID,
                    rawOperationID: input.operationID,
                    rawMediaID: input.mediaID,
                    contentType: input.contentType,
                    byteCount: input.byteCount
                )
            } catch let error as V2MediaEdgeUploadHTTPHandlerError {
                switch error {
                case .invalidIdentifier: throw Abort(.badRequest)
                case .invalidProviderTarget: throw Abort(.serviceUnavailable)
                }
            } catch is V2MediaValidationError {
                throw Abort(.badRequest)
            } catch V2MediaStoreError.idempotencyConflict {
                throw Abort(.conflict)
            } catch is V2MediaStoreError {
                throw Abort(.forbidden)
            } catch is V2MediaUploadSessionStoreError {
                throw Abort(.conflict)
            } catch is V2MediaUploadProviderSessionError {
                throw Abort(.serviceUnavailable)
            } catch {
                throw Abort(.serviceUnavailable)
            }
            return try noStoreJSONResponse(target)
        }

        routes.post("v2", "media", ":mediaID", "complete") { request async throws -> Response in
            let identity = try await authenticate(request)
            guard let rawMediaID = request.parameters.get("mediaID") else { throw Abort(.badRequest) }
            do {
                try await handler.uploadCompleted(
                    actorUserID: identity.userID,
                    deviceID: identity.deviceID,
                    rawMediaID: rawMediaID
                )
            } catch let error as V2MediaEdgeUploadHTTPHandlerError {
                switch error {
                case .invalidIdentifier: throw Abort(.badRequest)
                case .invalidProviderTarget: throw Abort(.serviceUnavailable)
                }
            } catch is V2MediaStoreError {
                // Do not reveal whether the caller named a real object or a
                // session belonging to a different account/device.
                throw Abort(.notFound)
            } catch {
                throw Abort(.serviceUnavailable)
            }
            var headers = HTTPFields()
            headers[.cacheControl] = "no-store"
            headers[.v2Pragma] = "no-cache"
            return .init(status: .noContent, headers: headers)
        }

        routes.get("v2", "media", ":mediaID", "upload-status") { request async throws -> Response in
            let identity = try await authenticate(request)
            guard let rawMediaID = request.parameters.get("mediaID") else { throw Abort(.badRequest) }
            let status: V2MediaUploadStatusEnvelope
            do {
                status = try await handler.uploadStatus(
                    actorUserID: identity.userID,
                    deviceID: identity.deviceID,
                    rawMediaID: rawMediaID
                )
            } catch V2MediaEdgeUploadHTTPHandlerError.invalidIdentifier {
                throw Abort(.badRequest)
            } catch is V2MediaStoreError {
                throw Abort(.notFound)
            } catch {
                throw Abort(.serviceUnavailable)
            }
            return try noStoreJSONResponse(status)
        }
    }

    /// 读取请求对应的鉴权身份。
    private func authenticate(_ request: Request) async throws -> V2AuthenticatedConnection {
        try await request.v2AuthenticatedAccountIdentity(using: authenticator)
    }

    /// 构造 no-store JSON 响应。
    private func noStoreJSONResponse<Payload: Encodable>(_ payload: Payload) throws -> Response {
        let data = try JSONEncoder().encode(payload)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.cacheControl] = "no-store"
        headers[.v2Pragma] = "no-cache"
        return .init(status: .ok, headers: headers, body: .init(data: data))
    }
}

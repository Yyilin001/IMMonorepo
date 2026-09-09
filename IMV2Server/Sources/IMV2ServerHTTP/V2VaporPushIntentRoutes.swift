import Foundation
import IMV2Core
import IMV2Server
import Vapor

/// 仅返回版本元信息，边缘不回传供应商提供方内部素材。
public struct V2PushIntentEpochHTTPResponse: Content, Sendable {
    public let epoch: UInt64
}

/// 推送会话 claim 请求体。
/// - expectedEpoch: 预期 epoch，用于并发保护。
public struct V2PushIntentClaimHTTPRequest: Content, Sendable {
    public let requestID: UUID
    /// 期望的版本号，用于并发保护。
    public let expectedEpoch: UInt64
}

/// 推送意图上报请求体。
///
/// - epoch: 目标 epoch。
/// - revision: 修订号。
/// - enabled: 是否启用。
/// - provider: 推送厂商。
/// - environment: 推送环境。
/// - token: 推送 token。
public struct V2PushIntentHTTPRequest: Content, Sendable {
    /// 目标版本。
    public let epoch: UInt64
    /// 修订号。
    public let revision: UInt64
    /// 是否启用推送能力。
    public let enabled: Bool
    /// 启用时的推送提供方。
    public let provider: V2PushEndpointProvider?
    /// 推送环境（如生产/沙盒）。
    public let environment: V2PushEndpointEnvironment?
    /// 平台推送 token，启用时必填。
    public let token: String?
}

/// 推送意图入库路由（仅存储当前会话设备的推送意图快照）。
/// 不支持写入历史回放，不提供降级到遗留存储。
public struct V2VaporPushIntentRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let store: any V2PushEndpointIntentStoring
    private let now: @Sendable () -> Date

    /// 初始化。
    public init(authenticator: any V2GatewayAuthenticator, store: any V2PushEndpointIntentStoring, now: @escaping @Sendable () -> Date = Date.init) {
        self.authenticator = authenticator
        self.store = store
        self.now = now
    }

    /// 注册 `GET/POST /v2/push-endpoint/session` 和 `PUT /v2/push-endpoint/intent`。
    ///
    /// - GET：读取当前推送意图 epoch。
    /// - POST：声明会话级 claim，推动 epoch 变更。
    /// - PUT：提交当前意图（启用/禁用、版本校验、幂等）。
    public func register(on routes: RoutesBuilder) {
        routes.get("v2", "push-endpoint", "session") { request async -> Response in
            await respond {
                let identity = try await request.v2AuthenticatedAccountIdentity(using: authenticator)
                let epoch = try await store.intentEpoch(actorUserID: identity.userID, deviceID: identity.deviceID)
                return try epochResponse(epoch)
            }
        }
        routes.post("v2", "push-endpoint", "session") { request async -> Response in
            await respond {
                let identity = try await request.v2AuthenticatedAccountIdentity(using: authenticator)
                let body = try request.content.decode(V2PushIntentClaimHTTPRequest.self)
                let claim = try V2PushIntentSessionClaim(requestID: body.requestID, expectedEpoch: body.expectedEpoch)
                let epoch = try await store.claimIntentSession(actorUserID: identity.userID, deviceID: identity.deviceID, claim: claim, now: now())
                return try epochResponse(epoch)
            }
        }
        routes.put("v2", "push-endpoint", "intent") { request async -> Response in
            await respond {
                let identity = try await request.v2AuthenticatedAccountIdentity(using: authenticator)
                let body = try request.content.decode(V2PushIntentHTTPRequest.self)
                let version = try V2PushIntentVersion(epoch: body.epoch, revision: body.revision)
                let intent: V2PushEndpointIntent
                if body.enabled {
                    guard let provider = body.provider, let environment = body.environment, let token = body.token else { throw V2PushDeviceEndpointError.invalidRegistration }
                    intent = .enabled(try .init(provider: provider, environment: environment, token: token))
                } else {
                    guard body.provider == nil, body.environment == nil, body.token == nil else { throw V2PushDeviceEndpointError.invalidRegistration }
                    intent = .disabled
                }
                try await store.publishIntent(actorUserID: identity.userID, deviceID: identity.deviceID, version: version, intent: intent, now: now())
                return Response(status: .noContent)
            }
        }
    }

    /// 构造 epoch 响应。
    private func epochResponse(_ epoch: UInt64) throws -> Response {
        let response = Response(status: .ok)
        try response.content.encode(V2PushIntentEpochHTTPResponse(epoch: epoch))
        return response
    }

    /// 统一错误转换包装，保证最终都带 no-store 头。
    private func respond(_ operation: () async throws -> Response) async -> Response {
        let response: Response
        do { response = try await operation() }
        catch { response = v2PushIntentErrorResponse(error) }
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        response.headers.replaceOrAdd(name: "Pragma", value: "no-cache")
        return response
    }
}

/// 按错误类型映射固定诊断码，避免返回内部异常信息与请求内容。
func v2PushIntentErrorResponse(_ error: any Error) -> Response {
    // 按错误类型映射为固定错误码。
    let status: HTTPResponseStatus
    let code: String
    switch error {
    case V2PushDeviceEndpointError.staleIntent: status = .conflict; code = "stale_intent"
    case V2PushDeviceEndpointError.intentConflict: status = .conflict; code = "intent_conflict"
    case V2PushDeviceEndpointError.intentVersionRequired: status = .preconditionRequired; code = "intent_version_required"
    case V2PushDeviceEndpointError.invalidRegistration, is V2PushIntentVersionError, is DecodingError:
        status = .badRequest; code = "invalid_request"
    case V2PushDeviceEndpointError.deviceUnavailable: status = .forbidden; code = "device_unavailable"
    case let abort as any AbortError where [400, 401, 403, 413, 415].contains(abort.status.code):
        status = abort.status; code = "request_rejected"
    default: status = .serviceUnavailable; code = "unavailable"
    }
    return Response(status: status, headers: ["Content-Type": "application/json", "Cache-Control": "no-store", "Pragma": "no-cache"], body: .init(string: "{\"code\":\"\(code)\"}"))
}

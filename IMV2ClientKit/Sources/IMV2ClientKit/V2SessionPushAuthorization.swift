import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension V2HTTPPushEndpointClient {
    /// 创建绑定特定账户代际的推送端点客户端，同时约束凭证读取和 HTTP 结果。
    ///
    /// - Parameters:
    ///   - endpoint: 推送管理端点，由基础客户端初始化器校验。
    ///   - session: 认证会话所有者。
    ///   - epoch: 本客户端允许使用的账户代际。
    ///   - transport: 执行推送 HTTP 请求的底层传输。
    /// - Throws: 基础客户端的端点校验错误。
    ///
    /// 退出清理应使用其清理代际创建独立客户端，不能继续复用已失效的前台所有者。
    public init(endpoint: URL, session: V2AuthSession, epoch: V2AuthSessionEpoch,
                transport: any V2ClientPushEndpointHTTPTransport = V2URLSessionPushEndpointHTTPTransport()) throws {
        let authorization = V2SessionHTTPAuthorization(
            session: session, epoch: epoch, transport: V2PushAuthorizationTransport(base: transport)
        )
        try self.init(endpoint: endpoint, credentials: authorization, transport: authorization)
    }
}

/// 将推送 HTTP 传输适配为通用认证传输，不改变响应或错误。
private struct V2PushAuthorizationTransport: V2AuthHTTPTransport {
    /// 注入的推送端点 HTTP 传输。
    let base: any V2ClientPushEndpointHTTPTransport
    /// 将请求原样转交底层传输并返回其结果；账户代际校验由外层授权适配器负责。
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await base.data(for: request)
    }
}

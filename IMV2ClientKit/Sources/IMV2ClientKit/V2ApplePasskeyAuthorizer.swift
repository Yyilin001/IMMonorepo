import Foundation

#if canImport(AuthenticationServices)
import AuthenticationServices

/// WebAuthn 断言流程的 Apple 平台桥接。
///
/// 它只对外暴露原始断言产物：应用既不会接触私钥，也不会自行把 Face ID 或 Touch ID 的
/// 成功结果直接换算成服务端凭据。
@MainActor
public final class V2ApplePasskeyAuthorizer: NSObject, V2PasskeyAuthorizing {
    private var controller: ASAuthorizationController?
    private var continuation: CheckedContinuation<V2PasskeyAssertionResult, Error>?

    /// 组合空实现；无需额外依赖。
    public override init() {}

    /// 发起一次通行密钥断言。
    ///
    /// 同一实例同时只允许一次在途请求。
    ///
    /// - Parameter request: 断言请求，包含依赖方标识、挑战与允许的凭据列表。
    /// - Returns: 原始断言产物。
    /// - Throws: 已有在途请求时抛出
    ///   ``V2PasskeyAccountAssertionError/unavailable``；用户取消时抛出
    ///   `CancellationError`。
    public func authorize(_ request: V2PasskeyAssertionRequest) async throws -> V2PasskeyAssertionResult {
        guard continuation == nil else { throw V2PasskeyAccountAssertionError.unavailable }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: request.relyingPartyID)
        let credentialRequest = provider.createCredentialAssertionRequest(challenge: request.challenge)
        credentialRequest.allowedCredentials = request.allowedCredentialIDs.map {
            ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
        }
        let controller = ASAuthorizationController(authorizationRequests: [credentialRequest])
        self.controller = controller
        controller.delegate = self
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    /// 结束当前断言并恢复等待方。
    ///
    /// - Parameter result: 断言结果或错误。
    private func finish(_ result: Result<V2PasskeyAssertionResult, Error>) {
        let continuation = continuation
        self.continuation = nil
        controller = nil
        continuation?.resume(with: result)
    }
}

extension V2ApplePasskeyAuthorizer: ASAuthorizationControllerDelegate {
    /// 系统完成授权后把凭据转换为断言产物。
    ///
    /// - Parameters:
    ///   - controller: 触发回调的授权控制器。
    ///   - authorization: 系统返回的授权结果。
    public nonisolated func authorizationController(controller _: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let assertion = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            Task { @MainActor [weak self] in self?.finish(.failure(V2PasskeyAccountAssertionError.invalidResult)) }
            return
        }
        let result = Result {
            try V2PasskeyAssertionResult(
                credentialID: assertion.credentialID,
                clientDataJSON: assertion.rawClientDataJSON,
                authenticatorData: assertion.rawAuthenticatorData,
                signature: assertion.signature,
                userHandle: assertion.userID
            )
        }
        Task { @MainActor [weak self] in self?.finish(result) }
    }

    /// 系统授权失败时映射为平台无关错误。
    ///
    /// - Parameters:
    ///   - controller: 触发回调的授权控制器。
    ///   - error: 系统错误；用户取消会映射为 `CancellationError`。
    public nonisolated func authorizationController(controller _: ASAuthorizationController, didCompleteWithError error: Error) {
        let mapped: Error
        if let authorizationError = error as? ASAuthorizationError, authorizationError.code == .canceled {
            mapped = CancellationError()
        } else {
            mapped = V2PasskeyAccountAssertionError.unavailable
        }
        Task { @MainActor [weak self] in self?.finish(.failure(mapped)) }
    }
}
#else
/// 跨平台测试目标可用的占位实现。
///
/// 它刻意按失败关闭处理，而不是尝试模拟平台通行密钥认证器。
public struct V2ApplePasskeyAuthorizer: V2PasskeyAuthorizing {
    /// 创建占位实现。
    public init() {}

    /// 始终以不可用失败。
    ///
    /// - Parameter request: 断言请求（本实现忽略）。
    /// - Throws: 始终抛出 ``V2PasskeyAccountAssertionError/unavailable``。
    public func authorize(_: V2PasskeyAssertionRequest) async throws -> V2PasskeyAssertionResult {
        throw V2PasskeyAccountAssertionError.unavailable
    }
}
#endif

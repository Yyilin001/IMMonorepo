import Foundation

#if canImport(AuthenticationServices)
import AuthenticationServices

/// Apple-platform bridge for the WebAuthn assertion ceremony. It intentionally
/// exposes only raw assertion artifacts; the app never sees a private key or
/// converts Face ID / Touch ID success into a server credential by itself.
@MainActor
public final class V2ApplePasskeyAuthorizer: NSObject, V2PasskeyAuthorizing {
    private var controller: ASAuthorizationController?
    private var continuation: CheckedContinuation<V2PasskeyAssertionResult, Error>?

    public override init() {}

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

    private func finish(_ result: Result<V2PasskeyAssertionResult, Error>) {
        let continuation = continuation
        self.continuation = nil
        controller = nil
        continuation?.resume(with: result)
    }
}

extension V2ApplePasskeyAuthorizer: ASAuthorizationControllerDelegate {
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
/// Kept available to cross-platform test targets but deliberately fails closed
/// rather than attempting to emulate a platform passkey authenticator.
public struct V2ApplePasskeyAuthorizer: V2PasskeyAuthorizing {
    public init() {}
    public func authorize(_: V2PasskeyAssertionRequest) async throws -> V2PasskeyAssertionResult {
        throw V2PasskeyAccountAssertionError.unavailable
    }
}
#endif

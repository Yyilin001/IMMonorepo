import Foundation

@MainActor
struct AuthenticationFacade {
    let sessionStore: AppSessionStore
    private let loginAction: (String, String) async -> Void
    private let registerAction: (String, String) async -> Void
    private let resendEmailVerificationAction: (String) async -> Void
    private let confirmEmailVerificationAction: (String, String) async -> Void
    private let requestPasswordResetAction: (String) async -> Void
    private let confirmPasswordResetAction: (String, String, String) async -> Void

    var state: AuthOperationState {
        sessionStore.authOperationState
    }

    var notice: AuthNotice? {
        sessionStore.authNotice
    }

    init(
        sessionStore: AppSessionStore,
        login: @escaping (String, String) async -> Void,
        register: @escaping (String, String) async -> Void,
        resendEmailVerification: @escaping (String) async -> Void,
        confirmEmailVerification: @escaping (String, String) async -> Void,
        requestPasswordReset: @escaping (String) async -> Void,
        confirmPasswordReset: @escaping (String, String, String) async -> Void
    ) {
        self.sessionStore = sessionStore
        self.loginAction = login
        self.registerAction = register
        self.resendEmailVerificationAction = resendEmailVerification
        self.confirmEmailVerificationAction = confirmEmailVerification
        self.requestPasswordResetAction = requestPasswordReset
        self.confirmPasswordResetAction = confirmPasswordReset
    }

    func login(email: String, password: String) async {
        await loginAction(email, password)
    }

    func register(email: String, password: String) async {
        await registerAction(email, password)
    }

    func resendEmailVerification(email: String) async {
        await resendEmailVerificationAction(email)
    }

    func confirmEmailVerification(email: String, code: String) async {
        await confirmEmailVerificationAction(email, code)
    }

    func requestPasswordReset(email: String) async {
        await requestPasswordResetAction(email)
    }

    func confirmPasswordReset(email: String, code: String, newPassword: String) async {
        await confirmPasswordResetAction(email, code, newPassword)
    }
}

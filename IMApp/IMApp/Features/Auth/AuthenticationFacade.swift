import Foundation

@MainActor
struct AuthenticationFacade {
    let sessionStore: AppSessionStore
    private let loginAction: (String, String) async -> Void
    private let registerAction: (String, String) async -> Void

    var state: AuthOperationState {
        sessionStore.authOperationState
    }

    var notice: AuthNotice? {
        sessionStore.authNotice
    }

    init(
        sessionStore: AppSessionStore,
        login: @escaping (String, String) async -> Void,
        register: @escaping (String, String) async -> Void
    ) {
        self.sessionStore = sessionStore
        self.loginAction = login
        self.registerAction = register
    }

    func login(email: String, password: String) async {
        await loginAction(email, password)
    }

    func register(email: String, password: String) async {
        await registerAction(email, password)
    }
}

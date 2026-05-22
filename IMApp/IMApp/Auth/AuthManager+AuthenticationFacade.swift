import Foundation

@MainActor
extension AuthManager {
    var authenticationFacade: AuthenticationFacade {
        AuthenticationFacade(
            sessionStore: sessionStore,
            login: { [weak self] email, password in
                await self?.login(email: email, password: password)
            },
            register: { [weak self] email, password in
                await self?.register(email: email, password: password)
            }
        )
    }
}

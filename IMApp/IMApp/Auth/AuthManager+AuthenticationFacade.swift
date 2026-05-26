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
            },
            resendEmailVerification: { [weak self] email in
                await self?.resendEmailVerification(email: email)
            },
            confirmEmailVerification: { [weak self] email, code in
                await self?.confirmEmailVerification(email: email, code: code)
            },
            requestPasswordReset: { [weak self] email in
                await self?.requestPasswordReset(email: email)
            },
            confirmPasswordReset: { [weak self] email, code, newPassword in
                await self?.confirmPasswordReset(email: email, code: code, newPassword: newPassword)
            }
        )
    }
}

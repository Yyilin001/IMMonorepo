import Foundation
import IMClientKit

@MainActor
struct SessionRuntimeContext {
    let sessionFacade: SessionFacade
    let sessionStore: AppSessionStore
    let currentUserProvider: () -> AuthUser?
    let disconnectIMConnection: () async -> Void
    let resetForSignedOut: (_ signedOutUserID: UUID?) async -> Void
    let startSignedInFeatures: (AuthUser) -> Void
    let shouldPreserveSession: (Error) async -> Bool
    let markServerUnavailableIfNeeded: (Error) async -> Void
    let markServerOnline: () -> Void
    let markServerOfflineMessage: (String) -> Void
    let deviceMetadataProvider: () -> DeviceMetadataPayload
}

@MainActor
final class SessionRuntimeController {
    private let context: SessionRuntimeContext
    private var restoreTask: Task<Void, Never>?
    private var restoreGeneration: UInt64 = 0

    init(context: SessionRuntimeContext) {
        self.context = context
    }

    func login(email: String, password: String) async {
        invalidateRestoreSession()
        await context.disconnectIMConnection()
        await authenticate(
            action: .login,
            email: email,
            password: password
        )
    }

    func register(email: String, password: String) async {
        invalidateRestoreSession()
        await context.disconnectIMConnection()
        await authenticate(
            action: .register,
            email: email,
            password: password
        )
    }

    func resendEmailVerification(email: String) async {
        guard !context.sessionStore.authOperationState.isBusy else {
            return
        }

        context.sessionStore.setOperation(.verifyingEmail)
        defer { context.sessionStore.setOperation(.idle) }

        do {
            let response = try await context.sessionFacade.resendEmailVerification(email: email)
            context.markServerOnline()
            context.sessionStore.setSignedOut(notice: AuthNotice(
                code: .emailVerificationRequired,
                message: response.message,
                severity: .info,
                isRecoverable: true
            ))
        } catch {
            let notice = AuthClientErrorMapper.notice(for: error)
            if await context.shouldPreserveSession(error) {
                await context.markServerUnavailableIfNeeded(error)
            }
            context.sessionStore.setSignedOut(notice: notice)
        }
    }

    func confirmEmailVerification(email: String, code: String) async {
        guard !context.sessionStore.authOperationState.isBusy else {
            return
        }

        context.sessionStore.setOperation(.verifyingEmail)
        defer { context.sessionStore.setOperation(.idle) }

        do {
            let response = try await context.sessionFacade.confirmEmailVerification(email: email, code: code)
            context.markServerOnline()
            context.sessionStore.setSignedOut(notice: AuthNotice(
                code: .emailVerificationRequired,
                message: response.message,
                severity: .info,
                isRecoverable: true
            ))
        } catch {
            let notice = AuthClientErrorMapper.notice(for: error)
            if await context.shouldPreserveSession(error) {
                await context.markServerUnavailableIfNeeded(error)
            }
            context.sessionStore.setSignedOut(notice: notice)
        }
    }

    func requestPasswordReset(email: String) async {
        guard !context.sessionStore.authOperationState.isBusy else {
            return
        }

        context.sessionStore.setOperation(.resettingPassword)
        defer { context.sessionStore.setOperation(.idle) }

        do {
            let response = try await context.sessionFacade.requestPasswordReset(email: email)
            context.markServerOnline()
            context.sessionStore.setSignedOut(notice: AuthNotice(
                code: .unknown,
                message: response.message,
                severity: .info,
                isRecoverable: true
            ))
        } catch {
            let notice = AuthClientErrorMapper.notice(for: error)
            if await context.shouldPreserveSession(error) {
                await context.markServerUnavailableIfNeeded(error)
            }
            context.sessionStore.setSignedOut(notice: notice)
        }
    }

    func confirmPasswordReset(email: String, code: String, newPassword: String) async {
        guard !context.sessionStore.authOperationState.isBusy else {
            return
        }

        context.sessionStore.setOperation(.resettingPassword)
        defer { context.sessionStore.setOperation(.idle) }

        do {
            let response = try await context.sessionFacade.confirmPasswordReset(
                email: email,
                code: code,
                newPassword: newPassword
            )
            context.markServerOnline()
            await context.sessionFacade.clearSession()
            context.sessionStore.setSignedOut(notice: AuthNotice(
                code: .passwordResetCompleted,
                message: response.message,
                severity: .info,
                isRecoverable: true
            ))
        } catch {
            let notice = AuthClientErrorMapper.notice(for: error)
            if await context.shouldPreserveSession(error) {
                await context.markServerUnavailableIfNeeded(error)
            }
            context.sessionStore.setSignedOut(notice: notice)
        }
    }

    func logout() async {
        invalidateRestoreSession()
        context.sessionStore.setOperation(.signingOut)
        defer { context.sessionStore.setOperation(.idle) }

        await context.sessionFacade.logoutCurrentIgnoringFailure()
        await clearSession(notice: nil)
    }

    func logoutAllSessions() async {
        invalidateRestoreSession()
        context.sessionStore.setOperation(.signingOut)
        defer { context.sessionStore.setOperation(.idle) }

        do {
            let result = try await context.sessionFacade.logoutAll()
            await clearSession(notice: AuthNotice(
                code: .sessionRevoked,
                message: "已退出 \(result.revokedSessions) 台设备。",
                severity: .info,
                isRecoverable: false
            ))
        } catch {
            let notice = AuthClientErrorMapper.notice(for: error)
            if await context.shouldPreserveSession(error) {
                await context.markServerUnavailableIfNeeded(error)
            } else {
                await clearSession(notice: notice)
            }
        }
    }

    func reloadProfile() async {
        invalidateRestoreSession()
        context.sessionStore.setOperation(.updatingProfile)
        defer { context.sessionStore.setOperation(.idle) }

        do {
            let user = try await context.sessionFacade.fetchProfile()
            context.markServerOnline()
            replaceSignedInUser(user)
            context.sessionStore.profileMessage = nil
        } catch {
            let notice = AuthClientErrorMapper.notice(for: error)
            context.sessionStore.profileMessage = notice.message
            if await context.shouldPreserveSession(error) {
                await context.markServerUnavailableIfNeeded(error)
            } else {
                await clearSession(notice: notice)
            }
        }
    }

    @discardableResult
    func updateProfile(
        displayName: String? = nil,
        avatarPreset: UserAvatarPreset? = nil
    ) async -> Bool {
        invalidateRestoreSession()
        context.sessionStore.setOperation(.updatingProfile)
        defer { context.sessionStore.setOperation(.idle) }

        do {
            let user = try await context.sessionFacade.updateProfile(
                displayName: displayName,
                avatarPreset: avatarPreset
            )
            context.markServerOnline()
            replaceSignedInUser(user)
            context.sessionStore.profileMessage = "资料已更新。"
            return true
        } catch {
            let notice = AuthClientErrorMapper.notice(for: error)
            context.sessionStore.profileMessage = notice.message
            if await context.shouldPreserveSession(error) {
                await context.markServerUnavailableIfNeeded(error)
            } else {
                await clearSession(notice: notice)
            }
            return false
        }
    }

    func loadSessions() async {
        invalidateRestoreSession()
        guard context.sessionStore.currentUser != nil else {
            context.sessionStore.sessions = []
            return
        }

        context.sessionStore.setOperation(.loadingSessions)
        defer { context.sessionStore.setOperation(.idle) }

        do {
            let response = try await context.sessionFacade.fetchSessions()
            context.markServerOnline()
            context.sessionStore.sessions = response
            context.sessionStore.sessionsMessage = nil
        } catch {
            let notice = AuthClientErrorMapper.notice(for: error)
            context.sessionStore.sessionsMessage = notice.message
            if await context.shouldPreserveSession(error) {
                await context.markServerUnavailableIfNeeded(error)
            } else {
                await clearSession(notice: notice)
            }
        }
    }

    func signOutCurrentDevice() async {
        invalidateRestoreSession()
        guard !context.sessionStore.authOperationState.isBusy else {
            return
        }

        context.sessionStore.setOperation(.signingOut)
        defer { context.sessionStore.setOperation(.idle) }

        do {
            try await context.sessionFacade.logoutCurrent()
            await clearSession(notice: nil)
        } catch {
            if await context.shouldPreserveSession(error) {
                await context.markServerUnavailableIfNeeded(error)
            }
            context.sessionStore.sessionsMessage = AuthClientErrorMapper.notice(for: error).message
        }
    }

    func signOut(sessionID: UUID, isCurrent: Bool) async {
        invalidateRestoreSession()
        guard !context.sessionStore.authOperationState.isBusy else {
            return
        }

        context.sessionStore.setOperation(.signingOut)
        defer { context.sessionStore.setOperation(.idle) }

        do {
            try await context.sessionFacade.logout(sessionID: sessionID)
            context.markServerOnline()
            if isCurrent {
                await clearSession(notice: nil)
            } else {
                context.sessionStore.sessions.removeAll { $0.id == sessionID }
                context.sessionStore.sessionsMessage = "已退出指定设备。"
            }
        } catch {
            let notice = AuthClientErrorMapper.notice(for: error)
            context.sessionStore.sessionsMessage = notice.message
            if await context.shouldPreserveSession(error) {
                await context.markServerUnavailableIfNeeded(error)
            } else {
                await clearSession(notice: notice)
            }
        }
    }

    func restoreSession() async {
        context.sessionStore.setOperation(.restoring)
        defer { context.sessionStore.setOperation(.idle) }

        await applyRestoreResult(await context.sessionFacade.restoreSession())
    }

    func scheduleRestoreSession() {
        let generation = restoreGeneration
        context.sessionStore.setOperation(.restoring)
        restoreTask = Task { [weak self] in
            guard let self else {
                return
            }

            let result = await self.context.sessionFacade.restoreSession()
            await self.applyRestoreResult(result, generation: generation)
        }
    }

    func invalidateRestoreSession() {
        restoreGeneration &+= 1
        restoreTask?.cancel()
        restoreTask = nil
        if context.sessionStore.authOperationState == .restoring {
            context.sessionStore.setOperation(.idle)
        }
    }

    func authenticate(action: SessionFacade.Action, email: String, password: String) async {
        guard !context.sessionStore.authOperationState.isBusy else {
            return
        }

        context.sessionStore.setOperation(.authenticating(action.authSubmissionKind))
        defer { context.sessionStore.setOperation(.idle) }

        do {
            let user = try await context.sessionFacade.authenticate(
                action: action,
                email: email,
                password: password,
                device: context.deviceMetadataProvider()
            )

            context.markServerOnline()
            context.sessionStore.sessionsMessage = nil
            applySignedInState(user)
        } catch {
            let notice = AuthClientErrorMapper.notice(for: error)
            if await context.shouldPreserveSession(error) {
                await context.markServerUnavailableIfNeeded(error)
            }
            context.sessionStore.setSignedOut(notice: notice)
        }
    }

    func clearSession(message: String?) async {
        await clearSession(notice: AuthClientErrorMapper.notice(forMessage: message))
    }

    func clearSession(notice: AuthNotice?) async {
        let signedOutUserID = context.currentUserProvider()?.id
        await context.resetForSignedOut(signedOutUserID)
        context.sessionStore.setSignedOut(notice: notice)
    }

    func applySignedInState(_ user: AuthUser) {
        context.sessionStore.profileMessage = nil
        replaceSignedInUser(user, availability: .online)
        context.startSignedInFeatures(user)
    }

    func replaceSignedInUser(_ user: AuthUser) {
        replaceSignedInUser(user, availability: .online)
    }

    func replaceSignedInUser(_ user: AuthUser, availability: AuthAvailability) {
        context.sessionStore.setSignedIn(user, availability: availability)
    }

    private func applyRestoreResult(_ result: SessionClient.RestoreResult) async {
        switch result {
        case .signedOut:
            context.sessionStore.setSignedOut(notice: nil)
        case .signedIn(let user):
            context.markServerOnline()
            context.sessionStore.sessionsMessage = nil
            applySignedInState(user)
        case .signedInOffline(let user, let message):
            context.sessionStore.profileMessage = nil
            replaceSignedInUser(user, availability: .offline(message: message))
            context.startSignedInFeatures(user)
            context.markServerOfflineMessage(message)
        }
    }

    private func applyRestoreResult(
        _ result: SessionClient.RestoreResult,
        generation: UInt64
    ) async {
        guard generation == restoreGeneration, !Task.isCancelled else {
            if context.sessionStore.authOperationState == .restoring {
                context.sessionStore.setOperation(.idle)
            }
            return
        }

        restoreTask = nil
        await applyRestoreResult(result)
        if context.sessionStore.authOperationState == .restoring {
            context.sessionStore.setOperation(.idle)
        }
    }
}

private extension SessionFacade.Action {
    var authSubmissionKind: AuthSubmissionKind {
        switch self {
        case .login:
            return .login
        case .register:
            return .register
        }
    }
}

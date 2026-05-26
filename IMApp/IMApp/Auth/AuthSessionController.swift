import Foundation
import IMClientKit

@MainActor
final class AuthSessionController {
    enum Action {
        case login
        case register
    }

    private let sessionClient: SessionClient

    init(sessionClient: SessionClient) {
        self.sessionClient = sessionClient
    }

    func authenticate(
        action: Action,
        email: String,
        password: String,
        device: DeviceMetadataPayload?
    ) async throws -> AuthUser {
        switch action {
        case .login:
            return try await sessionClient.login(email: email, password: password, device: device)
        case .register:
            return try await sessionClient.register(email: email, password: password, device: device)
        }
    }

    func restoreSession() async -> SessionClient.RestoreResult {
        await sessionClient.restoreSession()
    }

    func resendEmailVerification(email: String) async throws -> AuthChallengeResponseBody {
        try await sessionClient.resendEmailVerification(email: email)
    }

    func confirmEmailVerification(email: String, code: String) async throws -> AuthGenericResponseBody {
        try await sessionClient.confirmEmailVerification(email: email, code: code)
    }

    func requestPasswordReset(email: String) async throws -> AuthChallengeResponseBody {
        try await sessionClient.requestPasswordReset(email: email)
    }

    func confirmPasswordReset(email: String, code: String, newPassword: String) async throws -> AuthGenericResponseBody {
        try await sessionClient.confirmPasswordReset(email: email, code: code, newPassword: newPassword)
    }

    func fetchProfile() async throws -> AuthUser {
        try await sessionClient.fetchMe()
    }

    func updateProfile(
        displayName: String? = nil,
        avatarPreset: UserAvatarPreset? = nil
    ) async throws -> AuthUser {
        try await sessionClient.updateMyProfile(
            displayName: displayName,
            avatarPreset: avatarPreset
        )
    }

    func fetchSessions() async throws -> [SessionSnapshot] {
        try await sessionClient.fetchSessions()
    }

    func logoutCurrent() async throws {
        _ = try await sessionClient.logoutCurrent()
    }

    func logoutCurrentIgnoringFailure() async {
        do {
            _ = try await sessionClient.logoutCurrent()
        } catch {
            // Ignore remote logout failures and let the caller clear local state.
        }
    }

    func logoutAll() async throws -> LogoutAllResponseBody {
        try await sessionClient.logoutAll()
    }

    func logout(sessionID: UUID) async throws {
        _ = try await sessionClient.logout(sessionID: sessionID)
    }

    func clearSession() async {
        await sessionClient.clearSession()
    }

    func shouldPreserveSession(for error: Error) async -> Bool {
        await sessionClient.shouldPreserveSession(for: error)
    }

    func shouldMarkServerOffline(for error: Error) async -> Bool {
        await sessionClient.shouldMarkServerOffline(for: error)
    }
}

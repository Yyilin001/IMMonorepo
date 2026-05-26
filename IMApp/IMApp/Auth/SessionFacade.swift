import Foundation
import IMClientKit

@MainActor
final class SessionFacade {
    enum Action {
        case login
        case register
    }

    private let authSessionController: AuthSessionController
    private let contactsController: any ContactRuntimeControlling

    init(
        authSessionController: AuthSessionController,
        contactsController: any ContactRuntimeControlling
    ) {
        self.authSessionController = authSessionController
        self.contactsController = contactsController
    }

    func authenticate(
        action: Action,
        email: String,
        password: String,
        device: DeviceMetadataPayload?
    ) async throws -> AuthUser {
        let authAction: AuthSessionController.Action
        switch action {
        case .login:
            authAction = .login
        case .register:
            authAction = .register
        }

        return try await authSessionController.authenticate(
            action: authAction,
            email: email,
            password: password,
            device: device
        )
    }

    func restoreSession() async -> SessionClient.RestoreResult {
        await authSessionController.restoreSession()
    }

    func resendEmailVerification(email: String) async throws -> AuthChallengeResponseBody {
        try await authSessionController.resendEmailVerification(email: email)
    }

    func confirmEmailVerification(email: String, code: String) async throws -> AuthGenericResponseBody {
        try await authSessionController.confirmEmailVerification(email: email, code: code)
    }

    func requestPasswordReset(email: String) async throws -> AuthChallengeResponseBody {
        try await authSessionController.requestPasswordReset(email: email)
    }

    func confirmPasswordReset(email: String, code: String, newPassword: String) async throws -> AuthGenericResponseBody {
        try await authSessionController.confirmPasswordReset(email: email, code: code, newPassword: newPassword)
    }

    func fetchProfile() async throws -> AuthUser {
        try await authSessionController.fetchProfile()
    }

    func updateProfile(
        displayName: String? = nil,
        avatarPreset: UserAvatarPreset? = nil
    ) async throws -> AuthUser {
        try await authSessionController.updateProfile(
            displayName: displayName,
            avatarPreset: avatarPreset
        )
    }

    func fetchSessions() async throws -> [SessionSnapshot] {
        try await authSessionController.fetchSessions()
    }

    func logoutCurrent() async throws {
        try await authSessionController.logoutCurrent()
    }

    func logoutCurrentIgnoringFailure() async {
        await authSessionController.logoutCurrentIgnoringFailure()
    }

    func logoutAll() async throws -> LogoutAllResponseBody {
        try await authSessionController.logoutAll()
    }

    func logout(sessionID: UUID) async throws {
        try await authSessionController.logout(sessionID: sessionID)
    }

    func clearSession() async {
        await authSessionController.clearSession()
    }

    func shouldPreserveSession(for error: Error) async -> Bool {
        await authSessionController.shouldPreserveSession(for: error)
    }

    func shouldMarkServerOffline(for error: Error) async -> Bool {
        await authSessionController.shouldMarkServerOffline(for: error)
    }

    func fetchContacts() async throws -> ContactsSnapshot {
        try await contactsController.fetchContacts()
    }

    func fetchContactRequests() async throws -> ContactRequestsSnapshot {
        try await contactsController.fetchContactRequests()
    }

    func sendContactRequest(
        email: String,
        message: String?,
        remark: String?
    ) async throws -> ContactRequestResponseBody {
        try await contactsController.sendContactRequest(
            email: email,
            message: message,
            remark: remark
        )
    }

    func acceptContactRequest(id requestID: UUID, remark: String?) async throws -> ContactResponseBody {
        try await contactsController.acceptContactRequest(id: requestID, remark: remark)
    }

    func declineContactRequest(id requestID: UUID) async throws -> ContactRequestResponseBody {
        try await contactsController.declineContactRequest(id: requestID)
    }

    func cancelContactRequest(id requestID: UUID) async throws -> ContactRequestResponseBody {
        try await contactsController.cancelContactRequest(id: requestID)
    }

    func updateContact(contactUserID: UUID, remark: String?) async throws -> ContactResponseBody {
        try await contactsController.updateContact(contactUserID: contactUserID, remark: remark)
    }

    func deleteContact(contactUserID: UUID) async throws {
        try await contactsController.deleteContact(contactUserID: contactUserID)
    }

    func loadContactStateCacheSnapshot(for ownerUserID: UUID) async throws -> ContactStateCacheSnapshot {
        try await contactsController.loadCacheSnapshot(for: ownerUserID)
    }

    func saveContactStateCacheSnapshot(
        _ snapshot: ContactStateCacheSnapshot,
        for ownerUserID: UUID
    ) async throws {
        try await contactsController.saveCacheSnapshot(snapshot, for: ownerUserID)
    }

    func clearContactStateCacheSnapshot(for ownerUserID: UUID) async throws {
        try await contactsController.clearSnapshot(for: ownerUserID)
    }

    func clearAllContactStateCacheSnapshots() async throws {
        try await contactsController.clearAllSnapshots()
    }

    func isRequestRelevant(_ request: ContactRequestResponseBody, to currentUserID: UUID) -> Bool {
        contactsController.isRequestRelevant(request, to: currentUserID)
    }

    func normalizeRequests(
        _ requests: [ContactRequestResponseBody],
        currentUserID: UUID
    ) -> [ContactRequestResponseBody] {
        contactsController.normalizeRequests(requests, currentUserID: currentUserID)
    }

    func sortPendingNewestFirst(
        _ lhs: ContactRequestResponseBody,
        _ rhs: ContactRequestResponseBody
    ) -> Bool {
        contactsController.sortPendingNewestFirst(lhs, rhs)
    }

    func sortResolvedNewestFirst(
        _ lhs: ContactRequestResponseBody,
        _ rhs: ContactRequestResponseBody
    ) -> Bool {
        contactsController.sortResolvedNewestFirst(lhs, rhs)
    }

    func normalizedRemark(_ remark: String?) -> String? {
        contactsController.normalizedRemark(remark)
    }

    func normalizedRequestMessage(_ message: String?) -> String? {
        contactsController.normalizedRequestMessage(message)
    }
}

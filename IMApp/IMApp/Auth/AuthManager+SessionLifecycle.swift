import Foundation
import IMClientKit
import SwiftUI
import UIKit

@MainActor
extension AuthManager {
    func login(email: String, password: String) async {
        await sessionRuntimeController.login(email: email, password: password)
    }

    func register(email: String, password: String) async {
        await sessionRuntimeController.register(email: email, password: password)
    }

    func resendEmailVerification(email: String) async {
        await sessionRuntimeController.resendEmailVerification(email: email)
    }

    func confirmEmailVerification(email: String, code: String) async {
        await sessionRuntimeController.confirmEmailVerification(email: email, code: code)
    }

    func requestPasswordReset(email: String) async {
        await sessionRuntimeController.requestPasswordReset(email: email)
    }

    func confirmPasswordReset(email: String, code: String, newPassword: String) async {
        await sessionRuntimeController.confirmPasswordReset(email: email, code: code, newPassword: newPassword)
    }

    func logout() async {
        await sessionRuntimeController.logout()
    }

    func logoutAllSessions() async {
        await sessionRuntimeController.logoutAllSessions()
    }

    func reloadProfile() async {
        await sessionRuntimeController.reloadProfile()
    }

    @discardableResult
    func updateProfile(
        displayName: String? = nil,
        avatarPreset: UserAvatarPreset? = nil
    ) async -> Bool {
        await sessionRuntimeController.updateProfile(
            displayName: displayName,
            avatarPreset: avatarPreset
        )
    }

    func loadSessions() async {
        await sessionRuntimeController.loadSessions()
    }

    func reloadContacts() async {
        await contactRuntimeController.reloadContacts()
    }

    func reloadContactRequests() async {
        await contactRuntimeController.reloadContactRequests()
    }

    func sendContactRequestResult(email: String, message: String? = nil, remark: String? = nil) async -> ContactOperationResult {
        await contactRuntimeController.sendContactRequestResult(email: email, message: message, remark: remark)
    }

    func acceptContactRequestResult(id requestID: UUID, remark: String? = nil) async -> ContactOperationResult {
        await contactRuntimeController.acceptContactRequestResult(id: requestID, remark: remark)
    }

    func declineContactRequestResult(id requestID: UUID) async -> ContactOperationResult {
        await contactRuntimeController.declineContactRequestResult(id: requestID)
    }

    func cancelContactRequestResult(id requestID: UUID) async -> ContactOperationResult {
        await contactRuntimeController.cancelContactRequestResult(id: requestID)
    }

    func updateContactRemarkResult(contactUserID: UUID, remark: String) async -> ContactOperationResult {
        await contactRuntimeController.updateContactRemarkResult(contactUserID: contactUserID, remark: remark)
    }

    func deleteContactResult(_ contactUserID: UUID) async -> ContactOperationResult {
        await contactRuntimeController.deleteContactResult(contactUserID)
    }

    func signOutCurrentDevice() async {
        await sessionRuntimeController.signOutCurrentDevice()
    }

    func signOut(sessionID: UUID, isCurrent: Bool) async {
        await sessionRuntimeController.signOut(sessionID: sessionID, isCurrent: isCurrent)
    }

    func restoreSession() async {
        await sessionRuntimeController.restoreSession()
    }

    func scheduleRestoreSession() {
        sessionRuntimeController.scheduleRestoreSession()
    }

    func invalidateRestoreSession() {
        sessionRuntimeController.invalidateRestoreSession()
    }

    static var preview: AuthManager {
        let manager = AuthManager(
            network: AppNetworkConfiguration.preview.makeNetworkEnvironment(),
            imConnectionConfiguration: AppNetworkConfiguration.preview.makeIMTCPConfiguration(),
            shouldRestoreSession: false
        )
        manager.sessionStore.setSignedOut(notice: AuthNotice(
            code: .unknown,
            message: "Preview mode",
            severity: .info,
            isRecoverable: false
        ))
        return manager
    }
}

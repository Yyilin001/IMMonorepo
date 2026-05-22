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

    func addContact(email: String, remark: String? = nil) async -> Bool {
        await sendContactRequest(email: email, message: nil, remark: remark)
    }

    func reloadContactRequests() async {
        await contactRuntimeController.reloadContactRequests()
    }

    func sendContactRequest(email: String, message: String? = nil, remark: String? = nil) async -> Bool {
        await contactRuntimeController.sendContactRequest(email: email, message: message, remark: remark)
    }

    func acceptContactRequest(id requestID: UUID, remark: String? = nil) async -> Bool {
        await contactRuntimeController.acceptContactRequest(id: requestID, remark: remark)
    }

    func declineContactRequest(id requestID: UUID) async -> Bool {
        await contactRuntimeController.declineContactRequest(id: requestID)
    }

    func cancelContactRequest(id requestID: UUID) async -> Bool {
        await contactRuntimeController.cancelContactRequest(id: requestID)
    }

    func updateContactRemark(contactUserID: UUID, remark: String) async -> Bool {
        await contactRuntimeController.updateContactRemark(contactUserID: contactUserID, remark: remark)
    }

    func deleteContact(_ contactUserID: UUID) async -> Bool {
        await contactRuntimeController.deleteContact(contactUserID)
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

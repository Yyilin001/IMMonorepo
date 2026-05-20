import Combine
import Foundation
import IMClientKit
import SwiftUI
import UIKit

@MainActor
extension AuthManager {
    func login(email: String, password: String) async {
        invalidateRestoreSession()
        await disconnectIMConnection()
        await authenticate(
            action: .login,
            email: email,
            password: password
        )
    }

    func register(email: String, password: String) async {
        invalidateRestoreSession()
        await disconnectIMConnection()
        await authenticate(
            action: .register,
            email: email,
            password: password
        )
    }

    func logout() async {
        invalidateRestoreSession()
        await sessionFacade.logoutCurrentIgnoringFailure()
        await clearSession(message: nil)
    }

    func logoutAllSessions() async {
        invalidateRestoreSession()
        do {
            let result = try await sessionFacade.logoutAll()
            await clearSession(message: "已退出 \(result.revokedSessions) 台设备。")
        } catch {
            if await shouldPreserveSession(for: error) {
                await markServerUnavailableIfNeeded(for: error)
            } else {
                await clearSession(message: error.localizedDescription)
            }
        }
    }

    func reloadProfile() async {
        invalidateRestoreSession()
        do {
            let user = try await sessionFacade.fetchProfile()
            markServerOnline()
            replaceSignedInUser(user)
            profileMessage = nil
        } catch {
            profileMessage = error.localizedDescription
            if await shouldPreserveSession(for: error) {
                await markServerUnavailableIfNeeded(for: error)
            } else {
                await clearSession(message: error.localizedDescription)
            }
        }
    }

    @discardableResult
    func updateProfile(
        displayName: String? = nil,
        avatarPreset: UserAvatarPreset? = nil
    ) async -> Bool {
        invalidateRestoreSession()
        isUpdatingProfile = true
        defer { isUpdatingProfile = false }

        do {
            let user = try await sessionFacade.updateProfile(
                displayName: displayName,
                avatarPreset: avatarPreset
            )
            markServerOnline()
            replaceSignedInUser(user)
            profileMessage = "资料已更新。"
            return true
        } catch {
            profileMessage = error.localizedDescription
            if await shouldPreserveSession(for: error) {
                await markServerUnavailableIfNeeded(for: error)
            } else {
                await clearSession(message: error.localizedDescription)
            }
            return false
        }
    }

    func loadSessions() async {
        invalidateRestoreSession()
        guard case .signedIn = phase else {
            sessions = []
            return
        }

        isLoadingSessions = true
        defer { isLoadingSessions = false }

        do {
            let response = try await sessionFacade.fetchSessions()
            markServerOnline()
            sessions = response
            sessionsMessage = nil
        } catch {
            sessionsMessage = error.localizedDescription
            if await shouldPreserveSession(for: error) {
                await markServerUnavailableIfNeeded(for: error)
            } else {
                await clearSession(message: error.localizedDescription)
            }
        }
    }

    func reloadContacts() async {
        guard let user = currentUser else {
            contacts = []
            return
        }

        isLoadingContacts = true
        defer { isLoadingContacts = false }

        do {
            let snapshot = try await sessionFacade.fetchContacts()
            guard currentUser?.id == user.id else {
                return
            }

            markServerOnline()
            contacts = snapshot.contacts
            contactsMessage = nil
            lastContactStateRefreshAt = snapshot.lastRefreshAt
            scheduleContactStateCachePersist()
        } catch {
            await handleContactRequestError(error)
        }
    }

    func addContact(email: String, remark: String? = nil) async -> Bool {
        await sendContactRequest(email: email, message: nil, remark: remark)
    }

    func reloadContactRequests() async {
        guard let user = currentUser else {
            contactRequests = []
            unseenIncomingContactRequestCount = 0
            return
        }

        isLoadingContactRequests = true
        defer { isLoadingContactRequests = false }

        do {
            let snapshot = try await sessionFacade.fetchContactRequests()
            guard currentUser?.id == user.id else {
                return
            }

            markServerOnline()
            replaceContactRequests(snapshot.requests, currentUserID: user.id)
            contactRequestsLoadMessage = nil
            lastContactStateRefreshAt = snapshot.lastRefreshAt
            scheduleContactStateCachePersist()
        } catch {
            await handleContactRequestsLoadError(error)
        }
    }

    func sendContactRequest(email: String, message: String? = nil, remark: String? = nil) async -> Bool {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedMessage = sessionFacade.normalizedRequestMessage(message)
        let normalizedRemark = sessionFacade.normalizedRemark(remark)
        guard !normalizedEmail.isEmpty else {
            contactRequestActionMessage = "好友邮箱不能为空。"
            return false
        }

        contactRequestActionMessage = nil
        do {
            let request = try await sessionFacade.sendContactRequest(
                email: normalizedEmail,
                message: normalizedMessage,
                remark: normalizedRemark
            )
            markServerOnline()
            upsertContactRequest(request)
            contactRequestActionMessage = "好友申请已发送。"
            scheduleContactStateCachePersist()
            return true
        } catch {
            await handleContactRequestsActionError(error)
            return false
        }
    }

    func acceptContactRequest(id requestID: UUID, remark: String? = nil) async -> Bool {
        guard !acceptingRequestIDs.contains(requestID) else {
            return false
        }

        acceptingRequestIDs.insert(requestID)
        contactRequestActionMessage = nil
        defer { acceptingRequestIDs.remove(requestID) }

        do {
            let contact = try await sessionFacade.acceptContactRequest(
                id: requestID,
                remark: sessionFacade.normalizedRemark(remark)
            )
            markServerOnline()
            upsertContact(contact)
            updateContactRequestStatus(
                id: requestID,
                status: .accepted,
                respondedAt: Date()
            )
            contactRequestActionMessage = "已添加好友。"
            scheduleContactStateCachePersist()
            await reloadContacts()
            return true
        } catch {
            await handleContactRequestsActionError(error)
            return false
        }
    }

    func declineContactRequest(id requestID: UUID) async -> Bool {
        guard !decliningRequestIDs.contains(requestID) else {
            return false
        }

        decliningRequestIDs.insert(requestID)
        contactRequestActionMessage = nil
        defer { decliningRequestIDs.remove(requestID) }

        do {
            _ = try await sessionFacade.declineContactRequest(id: requestID)
            markServerOnline()
            updateContactRequestStatus(
                id: requestID,
                status: .declined,
                respondedAt: Date()
            )
            contactRequestActionMessage = "已拒绝好友申请。"
            scheduleContactStateCachePersist()
            return true
        } catch {
            await handleContactRequestsActionError(error)
            return false
        }
    }

    func cancelContactRequest(id requestID: UUID) async -> Bool {
        guard !cancellingRequestIDs.contains(requestID) else {
            return false
        }

        cancellingRequestIDs.insert(requestID)
        contactRequestActionMessage = nil
        defer { cancellingRequestIDs.remove(requestID) }

        do {
            _ = try await sessionFacade.cancelContactRequest(id: requestID)
            markServerOnline()
            updateContactRequestStatus(
                id: requestID,
                status: .cancelled,
                respondedAt: Date()
            )
            contactRequestActionMessage = "好友申请已取消。"
            scheduleContactStateCachePersist()
            return true
        } catch {
            await handleContactRequestsActionError(error)
            return false
        }
    }

    func updateContactRemark(contactUserID: UUID, remark: String) async -> Bool {
        do {
            let contact = try await sessionFacade.updateContact(
                contactUserID: contactUserID,
                remark: sessionFacade.normalizedRemark(remark)
            )
            markServerOnline()
            upsertContact(contact)
            contactsMessage = "联系人备注已更新。"
            scheduleContactStateCachePersist()
            return true
        } catch {
            await handleContactRequestError(error)
            return false
        }
    }

    func deleteContact(_ contactUserID: UUID) async -> Bool {
        do {
            try await sessionFacade.deleteContact(contactUserID: contactUserID)
            markServerOnline()
            contacts.removeAll { $0.id == contactUserID }
            contactsMessage = "已删除联系人。"
            scheduleContactStateCachePersist()
            return true
        } catch {
            await handleContactRequestError(error)
            return false
        }
    }

    func signOutCurrentDevice() async {
        invalidateRestoreSession()
        guard !isBusy else {
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            try await sessionFacade.logoutCurrent()
            await clearSession(message: nil)
        } catch {
            if await shouldPreserveSession(for: error) {
                await markServerUnavailableIfNeeded(for: error)
            }
            sessionsMessage = error.localizedDescription
        }
    }

    func signOut(sessionID: UUID, isCurrent: Bool) async {
        invalidateRestoreSession()
        guard !isBusy else {
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            try await sessionFacade.logout(sessionID: sessionID)
            markServerOnline()
            if isCurrent {
                await clearSession(message: nil)
            } else {
                sessions.removeAll { $0.id == sessionID }
                sessionsMessage = "已退出指定设备。"
            }
        } catch {
            sessionsMessage = error.localizedDescription
            if await shouldPreserveSession(for: error) {
                await markServerUnavailableIfNeeded(for: error)
            } else {
                await clearSession(message: error.localizedDescription)
            }
        }
    }

    func restoreSession() async {
        switch await sessionFacade.restoreSession() {
        case .signedOut:
            phase = .signedOut(message: nil)
        case .signedIn(let user):
            markServerOnline()
            sessionsMessage = nil
            applySignedInState(user)
        case .signedInOffline(let user, let message):
            applySignedInState(user)
            markServerOfflineMessage(message)
        }
    }

    func scheduleRestoreSession() {
        let generation = restoreGeneration
        restoreTask = Task { [weak self] in
            guard let self else {
                return
            }

            let result = await self.sessionFacade.restoreSession()
            await self.applyRestoreResult(result, generation: generation)
        }
    }

    func invalidateRestoreSession() {
        restoreGeneration &+= 1
        restoreTask?.cancel()
        restoreTask = nil
    }

    func applyRestoreResult(
        _ result: SessionClient.RestoreResult,
        generation: UInt64
    ) async {
        guard generation == restoreGeneration, !Task.isCancelled else {
            return
        }

        restoreTask = nil

        switch result {
        case .signedOut:
            phase = .signedOut(message: nil)
        case .signedIn(let user):
            markServerOnline()
            sessionsMessage = nil
            applySignedInState(user)
        case .signedInOffline(let user, let message):
            applySignedInState(user)
            markServerOfflineMessage(message)
        }
    }

    static var preview: AuthManager {
        let manager = AuthManager(
            network: AppNetworkConfiguration.preview.makeNetworkEnvironment(),
            imConnectionConfiguration: AppNetworkConfiguration.preview.makeIMTCPConfiguration(),
            shouldRestoreSession: false
        )
        manager.phase = .signedOut(message: "Preview mode")
        return manager
    }
}

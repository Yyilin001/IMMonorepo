//
//  ContentView.swift
//  IMApp
//
//  Created by yy on 2026/3/25.
//

import SwiftUI
import IMClientKit

struct ContentView: View {
    let authManager: AuthManager

    var body: some View {
        Group {
            switch authManager.sessionStore.authRouteState {
            case .launching:
                ProgressView("正在恢复登录状态…")
                    .progressViewStyle(.circular)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .signedOut:
                LoginView(authentication: authManager.authenticationFacade)

            case .signedIn(let user, _):
                SignedInTabView(
                    user: user,
                    sessionStore: authManager.sessionStore,
                    contactStore: authManager.contactStore,
                    conversationStore: authManager.imConversationStore,
                    conversationPresentationStore: authManager.conversationPresentationStore,
                    conversationRuntimeStore: authManager.conversationRuntimeStore,
                    probeManager: authManager.probeManager,
                    fileTransferManager: authManager.fileTransferManager,
                    imConnectionStatus: authManager.imConnectionStatus,
                    reloadProfile: {
                        await authManager.reloadProfile()
                    },
                    updateProfile: { displayName, avatarPreset in
                        await authManager.updateProfile(
                            displayName: displayName,
                            avatarPreset: avatarPreset
                        )
                    },
                    reconnectIMConnection: {
                        await authManager.reconnectIMConnection()
                    },
                    logout: {
                        await authManager.logout()
                    },
                    loadSessions: {
                        await authManager.loadSessions()
                    },
                    signOutCurrentDevice: {
                        await authManager.signOutCurrentDevice()
                    },
                    logoutAllSessions: {
                        await authManager.logoutAllSessions()
                    },
                    signOut: { sessionID, isCurrent in
                        await authManager.signOut(
                            sessionID: sessionID,
                            isCurrent: isCurrent
                        )
                    },
                    reloadContacts: {
                        await authManager.reloadContacts()
                    },
                    reloadContactRequests: {
                        await authManager.reloadContactRequests()
                    },
                    loadBlockedUsers: {
                        await authManager.loadBlockedUsers()
                    },
                    markIncomingContactRequestsSeen: {
                        authManager.markIncomingContactRequestsSeen()
                    },
                    sendContactRequest: { email, message, remark in
                        await authManager.sendContactRequestResult(
                            email: email,
                            message: message,
                            remark: remark
                        )
                    },
                    acceptContactRequest: { requestID, remark in
                        await authManager.acceptContactRequestResult(
                            id: requestID,
                            remark: remark
                        )
                    },
                    declineContactRequest: { requestID in
                        await authManager.declineContactRequestResult(id: requestID)
                    },
                    cancelContactRequest: { requestID in
                        await authManager.cancelContactRequestResult(id: requestID)
                    },
                    updateContactRemark: { contactID, remark in
                        await authManager.updateContactRemarkResult(
                            contactUserID: contactID,
                            remark: remark
                        )
                    },
                    deleteContact: { contactID in
                        await authManager.deleteContactResult(contactID)
                    },
                    blockUser: { userID in
                        await authManager.blockUserResult(userID)
                    },
                    unblockUser: { userID in
                        await authManager.unblockUserResult(userID)
                    },
                    reportUser: { userID, reason, detail in
                        await authManager.createReportResult(
                            targetType: "user",
                            targetID: userID.uuidString,
                            reason: reason,
                            detail: detail
                        )
                    },
                    createDirectConversation: { memberEmail in
                        await authManager.createDirectIMConversation(memberEmail: memberEmail)
                    }
                )
                .id(user.id)
            }
        }
        .background(Color(.systemGroupedBackground))
    }
}

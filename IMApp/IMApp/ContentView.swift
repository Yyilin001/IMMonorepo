//
//  ContentView.swift
//  IMApp
//
//  Created by yy on 2026/3/25.
//

import SwiftUI

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
                        await authManager.sendContactRequest(
                            email: email,
                            message: message,
                            remark: remark
                        )
                    },
                    acceptContactRequest: { requestID, remark in
                        await authManager.acceptContactRequest(
                            id: requestID,
                            remark: remark
                        )
                    },
                    declineContactRequest: { requestID in
                        await authManager.declineContactRequest(id: requestID)
                    },
                    cancelContactRequest: { requestID in
                        await authManager.cancelContactRequest(id: requestID)
                    },
                    updateContactRemark: { contactID, remark in
                        await authManager.updateContactRemark(
                            contactUserID: contactID,
                            remark: remark
                        )
                    },
                    deleteContact: { contactID in
                        await authManager.deleteContact(contactID)
                    },
                    blockUser: { userID in
                        await authManager.blockUser(userID)
                    },
                    unblockUser: { userID in
                        await authManager.unblockUser(userID)
                    },
                    createDirectConversation: { memberEmail in
                        await authManager.createDirectIMConversation(memberEmail: memberEmail)
                    }
                )
            }
        }
        .background(Color(.systemGroupedBackground))
    }
}

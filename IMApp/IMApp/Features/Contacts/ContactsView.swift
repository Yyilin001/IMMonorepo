import SwiftUI
import IMClientKit

struct ContactsView: View {
    let contactStore: ContactStore
    let currentUserID: UUID?
    let reloadContacts: () async -> Void
    let reloadContactRequests: () async -> Void
    let loadBlockedUsers: () async -> Void
    let markIncomingContactRequestsSeen: () -> Void
    let sendContactRequest: (String, String, String) async -> Bool
    let acceptContactRequest: (UUID, String) async -> Bool
    let declineContactRequest: (UUID) async -> Bool
    let cancelContactRequest: (UUID) async -> Bool
    let updateContactRemark: (UUID, String) async -> Bool
    let deleteContact: (UUID) async -> Bool
    let blockUser: (UUID) async -> Bool
    let unblockUser: (UUID) async -> Bool
    let createDirectConversation: (String) async -> String?

    let onOpenConversation: (String) -> Void

    @State private var isPresentingAddContact = false
    @State private var isPresentingNewContactRequests = false
    @State private var pendingConversationContactID: UUID?
    @State private var searchText = ""
    @State private var editingContact: ContactResponseBody?
    @State private var isPresentingBlockedUsers = false

    var body: some View {
        List {
            if let message = contactStore.contactsMessage, !message.isEmpty {
                Section {
                    ContactsInlineStatusBanner(message: message)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                }
            }

            if let message = contactStore.contactRequestsLoadMessage, !message.isEmpty {
                Section {
                    ContactsInlineStatusBanner(message: message)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                }
            }

            Section {
                Button {
                    isPresentingNewContactRequests = true
                } label: {
                    NewContactRequestsEntryRow(
                        pendingCount: totalPendingContactRequestCount,
                        unseenCount: contactStore.unseenIncomingContactRequestCount,
                        isLoading: contactStore.isLoadingContactRequests
                    )
                }
                .buttonStyle(.plain)
            } footer: {
                Text("新的朋友会集中展示收到和发出的好友申请，进入后只清除红点，不会移除待处理申请。")
            }

            Section {
                if contactStore.contacts.isEmpty {
                    ContactsEmptyState {
                        isPresentingAddContact = true
                    }
                    .listRowInsets(EdgeInsets(top: 20, leading: 16, bottom: 20, trailing: 16))
                    .listRowBackground(Color.clear)
                } else if filteredContacts.isEmpty {
                    ContactsNoSearchResultState(searchText: searchText)
                        .listRowInsets(EdgeInsets(top: 20, leading: 16, bottom: 20, trailing: 16))
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(filteredContacts) { contact in
                        ContactRow(
                            contact: contact,
                            isStartingConversation: pendingConversationContactID == contact.id,
                            onStartConversation: {
                                startConversation(with: contact)
                            },
                            onEdit: {
                                editingContact = contact
                            },
                            onDelete: {
                                delete(contact)
                            },
                            onBlock: {
                                block(contact)
                            }
                        )
                    }
                }
            } header: {
                HStack {
                    Text("联系人")

                    Spacer()

                    if contactStore.isLoadingContacts || contactStore.isLoadingContactRequests {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            } footer: {
                Text("通讯录只展示已通过验证的好友，可以编辑备注、删除好友或发起私聊。")
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "搜索邮箱或备注")
        .navigationTitle("通讯录")
        .background(Color(.systemGroupedBackground))
        .task {
            if contactStore.contacts.isEmpty {
                await reloadContacts()
            }
            if contactStore.contactRequests.isEmpty {
                await reloadContactRequests()
            }
            if contactStore.blockedUsers.isEmpty {
                await loadBlockedUsers()
            }
        }
        .refreshable {
            await reloadContacts()
            await reloadContactRequests()
            await loadBlockedUsers()
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task {
                        await reloadContacts()
                        await reloadContactRequests()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(contactStore.isLoadingContacts || contactStore.isLoadingContactRequests)

                Button {
                    isPresentingBlockedUsers = true
                } label: {
                    Image(systemName: "hand.raised.fill")
                }

                Button {
                    isPresentingAddContact = true
                } label: {
                    Image(systemName: "person.badge.plus")
                }
            }
        }
        .sheet(isPresented: $isPresentingAddContact) {
            NavigationStack {
                SendContactRequestSheet(
                    contactStore: contactStore,
                    sendContactRequest: sendContactRequest
                )
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $isPresentingNewContactRequests) {
            NavigationStack {
                NewContactRequestsView(
                    contactStore: contactStore,
                    currentUserID: currentUserID,
                    markIncomingContactRequestsSeen: markIncomingContactRequestsSeen,
                    reloadContactRequests: reloadContactRequests,
                    acceptContactRequest: acceptContactRequest,
                    declineContactRequest: declineContactRequest,
                    cancelContactRequest: cancelContactRequest,
                    createDirectConversation: createDirectConversation,
                    onOpenConversation: onOpenConversation
                )
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $isPresentingBlockedUsers) {
            NavigationStack {
                BlockedUsersSheet(
                    contactStore: contactStore,
                    loadBlockedUsers: loadBlockedUsers,
                    unblockUser: unblockUser
                )
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $editingContact) { contact in
            NavigationStack {
                EditContactRemarkSheet(
                    contactStore: contactStore,
                    contact: contact,
                    updateContactRemark: updateContactRemark
                )
            }
            .presentationDetents([.medium])
        }
    }

    private var filteredContacts: [ContactResponseBody] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return contactStore.contacts
        }

        return contactStore.contacts.filter { contact in
            contact.email.localizedCaseInsensitiveContains(query)
                || contact.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    private var totalPendingContactRequestCount: Int {
        incomingPendingContactRequests.count + outgoingPendingContactRequests.count
    }

    private var incomingPendingContactRequests: [ContactRequestResponseBody] {
        contactStore.incomingPendingContactRequests(
            currentUserID: currentUserID,
            sort: sortContactRequestsNewestFirst
        )
    }

    private var outgoingPendingContactRequests: [ContactRequestResponseBody] {
        contactStore.outgoingPendingContactRequests(
            currentUserID: currentUserID,
            sort: sortContactRequestsNewestFirst
        )
    }

    private func sortContactRequestsNewestFirst(
        _ lhs: ContactRequestResponseBody,
        _ rhs: ContactRequestResponseBody
    ) -> Bool {
        let leftDate = lhs.updatedAt ?? lhs.createdAt ?? .distantPast
        let rightDate = rhs.updatedAt ?? rhs.createdAt ?? .distantPast
        if leftDate == rightDate {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return leftDate > rightDate
    }

    private func startConversation(with contact: ContactResponseBody) {
        pendingConversationContactID = contact.id
        Task {
            let conversationID = await createDirectConversation(contact.email)
            pendingConversationContactID = nil
            if let conversationID {
                onOpenConversation(conversationID)
            }
        }
    }

    private func delete(_ contact: ContactResponseBody) {
        Task {
            _ = await deleteContact(contact.id)
        }
    }

    private func block(_ contact: ContactResponseBody) {
        Task {
            _ = await blockUser(contact.id)
        }
    }
}

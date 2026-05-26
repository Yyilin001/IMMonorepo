import SwiftUI
import IMClientKit

struct ContactsView: View {
    let contactStore: ContactStore
    let currentUserID: UUID?
    let currentUserEmail: String?
    let reloadContacts: () async -> Void
    let reloadContactRequests: () async -> Void
    let markIncomingContactRequestsSeen: () -> Void
    let sendContactRequest: (String, String, String) async -> ContactOperationResult

    let onOpenRequests: () -> Void
    let onOpenBlockedUsers: () -> Void
    let onOpenContact: (UUID) -> Void

    @State private var isPresentingAddContact = false
    @State private var searchText = ""
    @State private var taskBag = ContactTaskBag()
    @State private var requestClock = ContactRequestClock()

    var body: some View {
        List {
            if let notice = contactStore.notice(for: .contactsHome), !notice.message.isEmpty {
                Section {
                    AppStatusBanner(message: notice.message, tone: notice.tone.appStatusTone)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("contacts.status")
                }
            }

            if let notice = contactStore.notice(for: .requests), !notice.message.isEmpty {
                Section {
                    AppStatusBanner(message: notice.message, tone: notice.tone.appStatusTone)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("contacts.requestsStatus")
                }
            }

            Section {
                Button {
                    onOpenRequests()
                } label: {
                    NewContactRequestsEntryRow(
                        pendingCount: totalPendingContactRequestCount,
                        outgoingPendingCount: outgoingPendingContactRequestCount,
                        expiredCount: expiredContactRequestCount,
                        unseenCount: contactStore.unseenIncomingContactRequestCount,
                        isLoading: contactStore.isLoadingContactRequests
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("contacts.newFriends.row")

                Button {
                    onOpenBlockedUsers()
                } label: {
                    AppListActionRow(
                        title: "黑名单",
                        subtitle: blockedUsersSubtitle,
                        systemImage: "hand.raised.fill",
                        tint: .red
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("contacts.blockedUsers.row")
            }

            Section {
                if contactStore.contacts.isEmpty {
                    ContactsEmptyState {
                        isPresentingAddContact = true
                    }
                    .listRowInsets(EdgeInsets(top: 20, leading: 16, bottom: 20, trailing: 16))
                    .listRowBackground(Color.clear)
                } else if filteredContacts.isEmpty {
                    ContactsNoSearchResultState(
                        searchText: searchText,
                        onClear: {
                            searchText = ""
                        }
                    )
                        .listRowInsets(EdgeInsets(top: 20, leading: 16, bottom: 20, trailing: 16))
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(filteredContacts) { contact in
                        Button {
                            onOpenContact(contact.id)
                        } label: {
                            ContactRow(contact: contact)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("contacts.row.\(contact.id.uuidString)")
                    }
                }
            } header: {
                AppSectionHeader(
                    title: "联系人",
                    detail: contactStore.isLoadingContacts || contactStore.isLoadingContactRequests ? "同步中" : contactCountText
                )
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "搜索昵称、邮箱或备注")
        .navigationTitle("通讯录")
        .background(AppSurface.groupedBackground)
        .task {
            contactStore.clearNotice(scope: .contactsHome)
            await refreshIfNeeded()
        }
        .task {
            requestClock.update()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(ContactRequestClock.refreshInterval * 1_000_000_000))
                guard !Task.isCancelled else {
                    return
                }
                requestClock.update()
            }
        }
        .onDisappear {
            taskBag.cancelAll()
        }
        .refreshable {
            await reloadContacts()
            await reloadContactRequests()
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    guard runTask(.refresh("contacts-toolbar"), operation: {
                        await reloadContacts()
                        guard !Task.isCancelled else {
                            return
                        }
                        await reloadContactRequests()
                    }) else { return }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(contactStore.isLoadingContacts || contactStore.isLoadingContactRequests)
                .accessibilityIdentifier("contacts.refreshButton")

                Button {
                    isPresentingAddContact = true
                } label: {
                    Image(systemName: "person.badge.plus")
                }
                .accessibilityIdentifier("contacts.addButton")
            }
        }
        .sheet(isPresented: $isPresentingAddContact) {
            NavigationStack {
                SendContactRequestSheet(
                    contactStore: contactStore,
                    currentUserID: currentUserID,
                    currentUserEmail: currentUserEmail,
                    sendContactRequest: sendContactRequest,
                    refreshContactState: {
                        await reloadContacts()
                        guard !Task.isCancelled else {
                            return
                        }
                        await reloadContactRequests()
                    }
                )
            }
            .presentationDetents([.medium])
        }
    }

    private var filteredContacts: [ContactResponseBody] {
        contactStore.filteredContacts(query: searchText)
    }

    private var contactCountText: String? {
        guard !filteredContacts.isEmpty else {
            return nil
        }
        return "\(filteredContacts.count) 位"
    }

    private var blockedUsersSubtitle: String {
        if contactStore.blockedUsers.isEmpty {
            return "管理已拉黑的用户"
        }
        return "\(contactStore.blockedUsers.count) 位用户"
    }

    private var totalPendingContactRequestCount: Int {
        contactStore.totalPendingCount(currentUserID: currentUserID, now: requestClock.now)
    }

    private var outgoingPendingContactRequestCount: Int {
        contactStore.pendingOutgoingCount(currentUserID: currentUserID, now: requestClock.now)
    }

    private var expiredContactRequestCount: Int {
        contactStore.expiredRequestCount(currentUserID: currentUserID, now: requestClock.now)
    }

    private func refreshIfNeeded() async {
        guard contactStore.contacts.isEmpty
            || contactStore.contactRequests.isEmpty
            || contactStore.shouldRefreshContactState()
        else {
            return
        }

        await reloadContacts()
        guard !Task.isCancelled else {
            return
        }
        await reloadContactRequests()
    }

    @discardableResult
    private func runTask(
        _ key: ContactViewTaskKey,
        operation: @escaping @MainActor () async -> Void
    ) -> Bool {
        taskBag.run(key, operation: operation)
    }
}

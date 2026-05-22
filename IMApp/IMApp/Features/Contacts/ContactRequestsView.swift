import SwiftUI
import IMClientKit

struct NewContactRequestsView: View {
    @Environment(\.dismiss) private var dismiss
    let contactStore: ContactStore
    let currentUserID: UUID?
    let markIncomingContactRequestsSeen: () -> Void
    let reloadContactRequests: () async -> Void
    let acceptContactRequest: (UUID, String) async -> Bool
    let declineContactRequest: (UUID) async -> Bool
    let cancelContactRequest: (UUID) async -> Bool
    let createDirectConversation: (String) async -> String?

    let onOpenConversation: (String) -> Void

    @State private var acceptingContactRequest: ContactRequestResponseBody?
    @State private var startingConversationRequestID: UUID?

    var body: some View {
        List {
            if let message = contactStore.contactRequestActionMessage, !message.isEmpty {
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
                if incomingPendingContactRequests.isEmpty {
                    NewContactRequestsEmptyState()
                        .listRowInsets(EdgeInsets(top: 20, leading: 16, bottom: 20, trailing: 16))
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(incomingPendingContactRequests) { request in
                        IncomingContactRequestRow(
                            request: request,
                            isAccepting: contactStore.acceptingRequestIDs.contains(request.id),
                            isDeclining: contactStore.decliningRequestIDs.contains(request.id),
                            onAccept: {
                                acceptingContactRequest = request
                            },
                            onDecline: {
                                decline(request)
                            }
                        )
                    }
                }
            } header: {
                HStack {
                    Text("收到的申请")
                    Spacer()
                    if incomingPendingContactRequests.count > 0 {
                        Text("\(incomingPendingContactRequests.count)")
                    }
                }
            } footer: {
                Text("接受后双方才会出现在通讯录。")
            }

            if !outgoingPendingContactRequests.isEmpty {
                Section {
                    ForEach(outgoingPendingContactRequests) { request in
                        OutgoingContactRequestRow(
                            request: request,
                            isCancelling: contactStore.cancellingRequestIDs.contains(request.id),
                            onCancel: {
                                cancel(request)
                            }
                        )
                    }
                } header: {
                    Text("发出的申请")
                } footer: {
                    Text("等待对方验证期间不会加入联系人列表。")
                }
            }

            if !recentResolvedContactRequests.isEmpty {
                Section {
                    ForEach(recentResolvedContactRequests) { request in
                        ResolvedContactRequestRow(
                            request: request,
                            currentUserID: currentUserID,
                            isStartingConversation: startingConversationRequestID == request.id,
                            onStartConversation: request.status == .accepted ? {
                                startConversation(with: request)
                            } : nil
                        )
                    }
                } header: {
                    Text("最近记录")
                } footer: {
                    Text("这里只保留最近处理过的好友申请记录。")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("新的朋友")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            markIncomingContactRequestsSeen()
        }
        .refreshable {
            await reloadContactRequests()
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                if contactStore.isLoadingContactRequests {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .sheet(item: $acceptingContactRequest) { request in
            NavigationStack {
                AcceptContactRequestSheet(
                    contactStore: contactStore,
                    request: request,
                    acceptContactRequest: acceptContactRequest
                )
            }
            .presentationDetents([.medium])
        }
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

    private var recentResolvedContactRequests: [ContactRequestResponseBody] {
        contactStore.recentResolvedContactRequests(sort: sortContactRequestsNewestFirst)
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

    private func decline(_ request: ContactRequestResponseBody) {
        Task {
            _ = await declineContactRequest(request.id)
        }
    }

    private func cancel(_ request: ContactRequestResponseBody) {
        Task {
            _ = await cancelContactRequest(request.id)
        }
    }

    private func startConversation(with request: ContactRequestResponseBody) {
        guard let currentUserID else {
            return
        }

        let peerEmail: String
        if request.requester.id == currentUserID {
            peerEmail = request.addressee.email
        } else {
            peerEmail = request.requester.email
        }

        startingConversationRequestID = request.id
        Task {
            let conversationID = await createDirectConversation(peerEmail)
            startingConversationRequestID = nil

            guard let conversationID else {
                return
            }

            dismiss()
            onOpenConversation(conversationID)
        }
    }
}

import SwiftUI
import IMClientKit

struct NewContactRequestsView: View {
    @Environment(\.dismiss) private var dismiss
    let contactStore: ContactStore
    let currentUserID: UUID?
    var showsCloseButton = true
    let markIncomingContactRequestsSeen: () -> Void
    let reloadContactRequests: () async -> Void
    let sendContactRequest: (String, String, String) async -> ContactOperationResult
    let acceptContactRequest: (UUID, String) async -> ContactOperationResult
    let declineContactRequest: (UUID) async -> ContactOperationResult
    let cancelContactRequest: (UUID) async -> ContactOperationResult
    let createDirectConversation: (String) async -> String?

    let onOpenConversation: (String) -> Void

    @State private var acceptingContactRequest: ContactRequestResponseBody?
    @State private var startingConversationRequestID: UUID?
    @State private var resendingRequestID: UUID?
    @State private var resendRecoveryState: ContactRequestResendRecoveryState = .idle
    @State private var pendingRequestAction: ContactRequestConfirmationAction?
    @State private var taskBag = ContactTaskBag()
    @State private var requestClock = ContactRequestClock()

    var body: some View {
        List {
            if let notice = contactStore.notice(for: .requests), !notice.message.isEmpty {
                Section {
                    AppStatusBanner(message: notice.message, tone: notice.tone.appStatusTone)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("contacts.requests.actionStatus")
                }
            }

            if let resendRecoveryDraft {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        AppStatusBanner(
                            message: "旧申请已取消，但重新发送失败。可以重试发送给 \(resendRecoveryDraft.email)。",
                            tone: .warning
                        )

                        Button {
                            retryRecoveredResend(resendRecoveryDraft)
                        } label: {
                            if isRetryingRecoveredResend {
                                HStack {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("正在重试")
                                }
                            } else {
                                Label("重试发送", systemImage: "paperplane")
                            }
                        }
                        .disabled(isRetryingRecoveredResend)
                        .accessibilityIdentifier("contacts.request.resendRetry")
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                }
            }

            Section {
                if incomingRequestPresentations.isEmpty {
                    NewContactRequestsEmptyState()
                        .listRowInsets(EdgeInsets(top: 20, leading: 16, bottom: 20, trailing: 16))
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(incomingRequestPresentations) { presentation in
                        IncomingContactRequestRow(
                            presentation: presentation,
                            isAccepting: contactStore.acceptingRequestIDs.contains(presentation.id),
                            isDeclining: contactStore.decliningRequestIDs.contains(presentation.id),
                            onAccept: {
                                acceptingContactRequest = presentation.request
                            },
                            onDecline: {
                                pendingRequestAction = .decline(presentation.request)
                            }
                        )
                    }
                }
            } header: {
                AppSectionHeader(
                    title: "收到的申请",
                    detail: incomingRequestPresentations.isEmpty ? nil : "\(incomingRequestPresentations.count)"
                )
            }

            if !outgoingRequestPresentations.isEmpty {
                Section {
                    ForEach(outgoingRequestPresentations) { presentation in
                        OutgoingContactRequestRow(
                            presentation: presentation,
                            isCancelling: contactStore.cancellingRequestIDs.contains(presentation.id),
                            isResending: resendingRequestID == presentation.id,
                            onCancel: {
                                pendingRequestAction = .cancel(presentation.request)
                            },
                            onResend: {
                                resend(presentation)
                            }
                        )
                    }
                } header: {
                    AppSectionHeader(title: "发出的申请")
                }
            }

            if !recentResolvedContactRequests.isEmpty {
                Section {
                    ForEach(recentResolvedContactRequests) { presentation in
                        ResolvedContactRequestRow(
                            presentation: presentation,
                            isStartingConversation: startingConversationRequestID == presentation.id,
                            onStartConversation: presentation.state == .accepted ? {
                                startConversation(with: presentation.request)
                            } : nil
                        )
                    }
                } header: {
                    AppSectionHeader(title: "最近记录")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("新的朋友")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            contactStore.clearNotice(scope: .requests)
            await reloadContactRequests()
            guard !Task.isCancelled else {
                return
            }
            markIncomingContactRequestsSeen()
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
        .onChange(of: latestIncomingRequestMarker) { _, _ in
            markIncomingContactRequestsSeen()
        }
        .onDisappear {
            taskBag.cancelAll()
        }
        .refreshable {
            await reloadContactRequests()
            guard !Task.isCancelled else {
                return
            }
            markIncomingContactRequestsSeen()
        }
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
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
        .confirmationDialog(
            pendingRequestAction?.message ?? "",
            isPresented: pendingRequestActionIsPresented,
            titleVisibility: .visible
        ) {
            if let pendingRequestAction {
                Button(pendingRequestAction.title, role: .destructive) {
                    let action = pendingRequestAction
                    self.pendingRequestAction = nil
                    perform(action)
                }
                .accessibilityIdentifier(pendingRequestAction.accessibilityIdentifier)
            }

            Button("取消", role: .cancel) {
                pendingRequestAction = nil
            }
        }
    }

    private var requestPresentations: [ContactRequestPresentation] {
        contactStore.contactRequestPresentations(currentUserID: currentUserID, now: requestClock.now)
    }

    private var incomingRequestPresentations: [ContactRequestPresentation] {
        requestPresentations.filter { $0.isIncoming && ($0.state == .incomingPending || $0.state == .expired) }
    }

    private var outgoingRequestPresentations: [ContactRequestPresentation] {
        requestPresentations.filter { $0.isOutgoing && ($0.state == .outgoingPending || $0.state == .expired) }
    }

    private var recentResolvedContactRequests: [ContactRequestPresentation] {
        requestPresentations.filter { !$0.state.isPendingActionable && $0.state != .expired }
    }

    private var latestIncomingRequestMarker: String {
        incomingRequestPresentations
            .compactMap { presentation in
                presentation.request.createdAt.map { "\(presentation.id.uuidString)-\($0.timeIntervalSince1970)" }
            }
            .max() ?? ""
    }

    private var pendingRequestActionIsPresented: Binding<Bool> {
        Binding(
            get: { pendingRequestAction != nil },
            set: { isPresented in
                if !isPresented {
                    pendingRequestAction = nil
                }
            }
        )
    }

    private var resendRecoveryDraft: ContactRequestResendDraft? {
        switch resendRecoveryState {
        case .idle:
            return nil
        case .waitingForRetry(let draft), .retrying(let draft):
            return draft
        }
    }

    private var isRetryingRecoveredResend: Bool {
        if case .retrying = resendRecoveryState {
            return true
        }
        return false
    }

    private func perform(_ action: ContactRequestConfirmationAction) {
        switch action {
        case .decline(let request):
            decline(request)
        case .cancel(let request):
            cancel(request)
        }
    }

    private func decline(_ request: ContactRequestResponseBody) {
        guard runTask(.decline(request.id), operation: {
            let result = await declineContactRequest(request.id)
            guard !Task.isCancelled else {
                return
            }
            setContactNotice(result, scope: .requests)
        }) else { return }
    }

    private func cancel(_ request: ContactRequestResponseBody) {
        guard runTask(.cancel(request.id), operation: {
            let result = await cancelContactRequest(request.id)
            guard !Task.isCancelled else {
                return
            }
            setContactNotice(result, scope: .requests)
        }) else { return }
    }

    private func resend(_ presentation: ContactRequestPresentation) {
        guard !taskBag.isRunning(.resend(presentation.id)) else {
            return
        }
        let draft = ContactRequestResendDraft(
            sourceRequestID: presentation.id,
            email: presentation.email,
            message: presentation.request.message ?? "",
            remark: presentation.request.requesterRemark ?? ""
        )
        guard runTask(.resend(presentation.id), operation: {
            resendingRequestID = presentation.id
            let cancelResult = await cancelContactRequest(presentation.id)
            guard !Task.isCancelled else {
                return
            }
            guard cancelResult.succeeded else {
                setContactNotice(cancelResult, scope: .requests)
                resendingRequestID = nil
                return
            }

            let sendResult = await sendContactRequest(
                draft.email,
                draft.message,
                draft.remark
            )
            guard !Task.isCancelled else {
                return
            }
            if sendResult.succeeded {
                resendRecoveryState = .idle
                setContactNotice(sendResult, scope: .requests)
                await reloadContactRequests()
            } else {
                resendRecoveryState = .waitingForRetry(draft)
                let message = sendResult.message.isEmpty
                    ? "旧申请已取消，但重新发送失败。请稍后重试。"
                    : "旧申请已取消，\(sendResult.message)"
                contactStore.setNotice(message, scope: .requests, tone: .warning)
            }
            resendingRequestID = nil
        }) else { return }
    }

    private func retryRecoveredResend(_ draft: ContactRequestResendDraft) {
        guard runTask(.resend(draft.sourceRequestID), operation: {
            resendRecoveryState = .retrying(draft)
            let sendResult = await sendContactRequest(draft.email, draft.message, draft.remark)
            guard !Task.isCancelled else {
                return
            }
            if sendResult.succeeded {
                resendRecoveryState = .idle
                setContactNotice(sendResult, scope: .requests)
                await reloadContactRequests()
            } else {
                resendRecoveryState = .waitingForRetry(draft)
                let message = sendResult.message.isEmpty ? "重新发送失败，请稍后重试。" : sendResult.message
                contactStore.setNotice(message, scope: .requests, tone: .warning)
            }
        }) else { return }
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

        guard runTask(.startConversation(request.id), operation: {
            startingConversationRequestID = request.id
            let conversationID = await createDirectConversation(peerEmail)
            guard !Task.isCancelled else {
                return
            }
            startingConversationRequestID = nil

            guard let conversationID else {
                return
            }

            dismiss()
            onOpenConversation(conversationID)
        }) else { return }
    }

    @discardableResult
    private func runTask(
        _ key: ContactViewTaskKey,
        operation: @escaping @MainActor () async -> Void
    ) -> Bool {
        taskBag.run(key, operation: operation)
    }

    private func setContactNotice(_ result: ContactOperationResult, scope: ContactNoticeScope) {
        guard !result.message.isEmpty else {
            return
        }
        contactStore.setNotice(result.message, scope: scope, tone: result.tone)
    }
}

private enum ContactRequestConfirmationAction: Identifiable, Equatable {
    case decline(ContactRequestResponseBody)
    case cancel(ContactRequestResponseBody)

    var id: UUID {
        switch self {
        case .decline(let request), .cancel(let request):
            return request.id
        }
    }

    var title: String {
        switch self {
        case .decline:
            return "拒绝申请"
        case .cancel:
            return "取消申请"
        }
    }

    var message: String {
        switch self {
        case .decline(let request):
            return "确认拒绝 \(request.requester.preferredDisplayName) 的好友申请？"
        case .cancel(let request):
            return "确认取消发给 \(request.addressee.preferredDisplayName) 的好友申请？"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .decline:
            return "contacts.request.confirmReject"
        case .cancel:
            return "contacts.request.confirmCancel"
        }
    }
}

import SwiftUI
import IMClientKit

struct ContactsView: View {
    @EnvironmentObject private var authManager: AuthManager

    let onOpenConversation: (String) -> Void

    @State private var isPresentingAddContact = false
    @State private var pendingConversationContactID: UUID?
    @State private var searchText = ""
    @State private var editingContact: ContactResponseBody?
    @State private var acceptingContactRequest: ContactRequestResponseBody?

    var body: some View {
        List {
            if let message = authManager.contactsMessage, !message.isEmpty {
                Section {
                    ContactsInlineStatusBanner(message: message)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                }
            }

            if let message = authManager.contactRequestsMessage, !message.isEmpty {
                Section {
                    ContactsInlineStatusBanner(message: message)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                }
            }

            if !authManager.incomingContactRequests.isEmpty {
                Section {
                    ForEach(authManager.incomingContactRequests) { request in
                        IncomingContactRequestRow(
                            request: request,
                            onAccept: {
                                acceptingContactRequest = request
                            },
                            onDecline: {
                                decline(request)
                            }
                        )
                    }
                } header: {
                    HStack {
                        Text("新的朋友")
                        Spacer()
                        Text("\(authManager.incomingContactRequests.count)")
                    }
                } footer: {
                    Text("接受后双方才会出现在通讯录。")
                }
            }

            if !authManager.outgoingContactRequests.isEmpty {
                Section {
                    ForEach(authManager.outgoingContactRequests) { request in
                        OutgoingContactRequestRow(
                            request: request,
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

            Section {
                if authManager.contacts.isEmpty {
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
                            }
                        )
                    }
                }
            } header: {
                HStack {
                    Text("联系人")

                    Spacer()

                    if authManager.isLoadingContacts || authManager.isLoadingContactRequests {
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
            if authManager.contacts.isEmpty {
                await authManager.reloadContacts()
            }
            if authManager.incomingContactRequests.isEmpty && authManager.outgoingContactRequests.isEmpty {
                await authManager.reloadContactRequests()
            }
        }
        .refreshable {
            await authManager.reloadContacts()
            await authManager.reloadContactRequests()
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task {
                        await authManager.reloadContacts()
                        await authManager.reloadContactRequests()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(authManager.isLoadingContacts || authManager.isLoadingContactRequests)

                Button {
                    isPresentingAddContact = true
                } label: {
                    Image(systemName: "person.badge.plus")
                }
            }
        }
        .sheet(isPresented: $isPresentingAddContact) {
            NavigationStack {
                SendContactRequestSheet()
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $acceptingContactRequest) { request in
            NavigationStack {
                AcceptContactRequestSheet(request: request)
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $editingContact) { contact in
            NavigationStack {
                EditContactRemarkSheet(contact: contact)
            }
            .presentationDetents([.medium])
        }
    }

    private var filteredContacts: [ContactResponseBody] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return authManager.contacts
        }

        return authManager.contacts.filter { contact in
            contact.email.localizedCaseInsensitiveContains(query)
                || contact.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    private func startConversation(with contact: ContactResponseBody) {
        pendingConversationContactID = contact.id
        Task {
            let conversationID = await authManager.createDirectIMConversation(memberEmail: contact.email)
            pendingConversationContactID = nil
            if let conversationID {
                onOpenConversation(conversationID)
            }
        }
    }

    private func delete(_ contact: ContactResponseBody) {
        Task {
            _ = await authManager.deleteContact(contact.id)
        }
    }

    private func decline(_ request: ContactRequestResponseBody) {
        Task {
            _ = await authManager.declineContactRequest(id: request.id)
        }
    }

    private func cancel(_ request: ContactRequestResponseBody) {
        Task {
            _ = await authManager.cancelContactRequest(id: request.id)
        }
    }
}

private struct ContactsInlineStatusBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "info.circle.fill")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ContactRow: View {
    let contact: ContactResponseBody
    let isStartingConversation: Bool
    let onStartConversation: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.teal.opacity(0.85), Color.blue.opacity(0.8)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 42, height: 42)
                .overlay {
                    Text(initial)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(contact.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                onStartConversation()
            } label: {
                if isStartingConversation {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "message.fill")
                        .font(.body.weight(.semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isStartingConversation)
        }
        .padding(.vertical, 6)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("删除", systemImage: "trash")
            }

            Button {
                onEdit()
            } label: {
                Label("备注", systemImage: "pencil")
            }
            .tint(.blue)
        }
    }

    private var initial: String {
        contact.displayName.first.map { String($0).uppercased() } ?? "#"
    }

    private var subtitle: String {
        contact.displayName == contact.email ? "联系人 ID \(contact.id.uuidString.prefix(8))" : contact.email
    }
}

private struct IncomingContactRequestRow: View {
    let request: ContactRequestResponseBody
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            requestAvatar(systemImage: "person.crop.circle.badge.plus", color: .orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(request.requester.email)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(request.message?.isEmpty == false ? request.message ?? "" : "请求添加你为好友")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            HStack(spacing: 8) {
                Button("拒绝") {
                    onDecline()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("接受") {
                    onAccept()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct OutgoingContactRequestRow: View {
    let request: ContactRequestResponseBody
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            requestAvatar(systemImage: "paperplane.fill", color: .blue)

            VStack(alignment: .leading, spacing: 4) {
                Text(request.addressee.email)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("等待验证")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("取消") {
                onCancel()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 6)
    }
}

private func requestAvatar(systemImage: String, color: Color) -> some View {
    Circle()
        .fill(color.opacity(0.14))
        .frame(width: 42, height: 42)
        .overlay {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
        }
}

private struct ContactsEmptyState: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.2.crop.square.stack")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.teal)

            VStack(spacing: 6) {
                Text("还没有联系人")
                    .font(.headline)

                Text("发送好友申请并通过验证后，可以从通讯录直接发起私聊。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                onAdd()
            } label: {
                Label("发送好友申请", systemImage: "person.badge.plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

private struct ContactsNoSearchResultState: View {
    let searchText: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("没有找到匹配联系人")
                .font(.headline)

            Text("当前搜索：\(searchText)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

private struct SendContactRequestSheet: View {
    @EnvironmentObject private var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var message = ""
    @State private var remark = ""
    @State private var isSubmitting = false

    var body: some View {
        Form {
            Section {
                TextField("联系人邮箱", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()

                TextField("验证消息（可选）", text: $message, axis: .vertical)
                    .lineLimit(2...4)

                TextField("给对方的备注（可选）", text: $remark)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("对方接受后才会成为好友，备注仅自己可见。")
            }

            if let message = authManager.contactRequestsMessage, !message.isEmpty {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("发送好友申请")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
                .disabled(isSubmitting)
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("发送") {
                    submit()
                }
                .disabled(isSubmitting || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func submit() {
        isSubmitting = true
        Task {
            let didSend = await authManager.sendContactRequest(
                email: email,
                message: message,
                remark: remark
            )
            isSubmitting = false
            if didSend {
                dismiss()
            }
        }
    }
}

private struct AcceptContactRequestSheet: View {
    @EnvironmentObject private var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss

    let request: ContactRequestResponseBody

    @State private var remark = ""
    @State private var isSubmitting = false

    var body: some View {
        Form {
            Section {
                LabeledContent("申请人", value: request.requester.email)

                if let message = request.message, !message.isEmpty {
                    LabeledContent("验证消息", value: message)
                }

                TextField("给对方的备注（可选）", text: $remark)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("接受后会建立双向好友关系，双方都能在通讯录看到对方。")
            }

            if let message = authManager.contactRequestsMessage, !message.isEmpty {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("接受申请")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
                .disabled(isSubmitting)
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("接受") {
                    submit()
                }
                .disabled(isSubmitting)
            }
        }
    }

    private func submit() {
        isSubmitting = true
        Task {
            let didAccept = await authManager.acceptContactRequest(
                id: request.id,
                remark: remark
            )
            isSubmitting = false
            if didAccept {
                dismiss()
            }
        }
    }
}

private struct EditContactRemarkSheet: View {
    @EnvironmentObject private var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss

    let contact: ContactResponseBody

    @State private var remark: String
    @State private var isSubmitting = false

    init(contact: ContactResponseBody) {
        self.contact = contact
        _remark = State(initialValue: contact.remark ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("备注", text: $remark)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                LabeledContent("邮箱", value: contact.email)
            } footer: {
                Text("清空备注后，通讯录会直接显示邮箱。")
            }

            if let message = authManager.contactsMessage, !message.isEmpty {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("编辑备注")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
                .disabled(isSubmitting)
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    submit()
                }
                .disabled(isSubmitting)
            }
        }
    }

    private func submit() {
        isSubmitting = true
        Task {
            let didUpdate = await authManager.updateContactRemark(
                contactUserID: contact.id,
                remark: remark
            )
            isSubmitting = false
            if didUpdate {
                dismiss()
            }
        }
    }
}

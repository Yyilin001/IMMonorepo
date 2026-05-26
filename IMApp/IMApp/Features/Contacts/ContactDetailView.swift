import SwiftUI
import IMClientKit

struct ContactDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let contactStore: ContactStore
    let contactID: UUID
    let updateContactRemark: (UUID, String) async -> ContactOperationResult
    let deleteContact: (UUID) async -> ContactOperationResult
    let blockUser: (UUID) async -> ContactOperationResult
    let reportUser: (UUID, String, String?) async -> ContactOperationResult
    let createDirectConversation: (String) async -> String?
    let onOpenConversation: (String) -> Void

    @State private var isEditingRemark = false
    @State private var isPresentingReport = false
    @State private var isStartingConversation = false
    @State private var isDeleting = false
    @State private var isBlocking = false
    @State private var pendingDestructiveAction: ContactDestructiveAction?
    @State private var taskBag = ContactTaskBag()

    var body: some View {
        Group {
            if let contact {
                contactList(contact)
            } else {
                ContentUnavailableView("联系人不可用", systemImage: "person.crop.circle.badge.exclamationmark")
                    .accessibilityIdentifier("contacts.detail.unavailable")
            }
        }
        .navigationTitle("联系人详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isEditingRemark) {
            if let contact {
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
        .sheet(isPresented: $isPresentingReport) {
            if let contact {
                NavigationStack {
                    ContactReportSheet(
                        contact: contact,
                        reportUser: reportUser,
                        onSuccess: { result in
                            if !result.message.isEmpty {
                                contactStore.setNotice(result.message, scope: .detail, tone: result.tone)
                            }
                        }
                    )
                }
                .presentationDetents([.medium])
            }
        }
        .onAppear {
            contactStore.clearNotice(scope: .detail)
        }
        .onDisappear {
            taskBag.cancelAll()
        }
        .confirmationDialog(
            pendingDestructiveAction?.message ?? "",
            isPresented: pendingActionIsPresented,
            titleVisibility: .visible
        ) {
            if let pendingDestructiveAction {
                Button(pendingDestructiveAction.title, role: .destructive) {
                    let action = pendingDestructiveAction
                    self.pendingDestructiveAction = nil
                    perform(action)
                }
                .accessibilityIdentifier(pendingDestructiveAction.confirmationIdentifier)
            }

            Button("取消", role: .cancel) {
                pendingDestructiveAction = nil
            }
        }
    }

    private var contact: ContactResponseBody? {
        contactStore.contacts.first { $0.id == contactID }
    }

    private var pendingActionIsPresented: Binding<Bool> {
        Binding(
            get: { pendingDestructiveAction != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDestructiveAction = nil
                }
            }
        )
    }

    private func contactList(_ contact: ContactResponseBody) -> some View {
        List {
            Section {
                VStack(spacing: 14) {
                    UserAvatarView(
                        displayName: contact.displayName,
                        email: contact.email,
                        avatarPreset: contact.avatarPreset,
                        size: 76
                    )

                    VStack(spacing: 4) {
                        Text(contact.displayName)
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)

                        Text(contact.email)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }

            Section("资料") {
                infoRow(title: "邮箱", value: contact.email)
                infoRow(title: "备注", value: normalizedRemark(for: contact) ?? "未设置")
                if let profileDisplayName = normalizedProfileDisplayName(for: contact) {
                    infoRow(title: "昵称", value: profileDisplayName)
                }
                if let createdAt = contact.createdAt {
                    infoRow(title: "添加时间", value: createdAt.formatted(date: .abbreviated, time: .shortened))
                }
            }

            if let notice = contactStore.notice(for: .detail), !notice.message.isEmpty {
                Section {
                    AppStatusBanner(message: notice.message, tone: notice.tone.appStatusTone)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                }
            }

            Section("操作") {
                Button {
                    startConversation(contact)
                } label: {
                    if isStartingConversation {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在打开会话")
                        }
                    } else {
                        Label("发消息", systemImage: "message.fill")
                    }
                }
                .disabled(isStartingConversation || isDeleting || isBlocking)
                .accessibilityIdentifier("contacts.detail.message")

                Button {
                    isEditingRemark = true
                } label: {
                    Label("编辑备注", systemImage: "pencil")
                }
                .disabled(isDeleting || isBlocking)
                .accessibilityIdentifier("contacts.detail.remark")

                Button {
                    isPresentingReport = true
                } label: {
                    Label("举报用户", systemImage: "exclamationmark.bubble")
                }
                .disabled(isStartingConversation || isDeleting || isBlocking)
                .accessibilityIdentifier("contacts.detail.report")
            }

            Section {
                Button(role: .destructive) {
                    pendingDestructiveAction = .delete
                } label: {
                    if isDeleting {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在删除")
                        }
                    } else {
                        Label("删除联系人", systemImage: "trash")
                    }
                }
                .disabled(isStartingConversation || isDeleting || isBlocking)
                .accessibilityIdentifier("contacts.detail.delete")

                Button(role: .destructive) {
                    pendingDestructiveAction = .block
                } label: {
                    if isBlocking {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在拉黑")
                        }
                    } else {
                        Label("拉入黑名单", systemImage: "hand.raised.fill")
                    }
                }
                .disabled(isStartingConversation || isDeleting || isBlocking)
                .accessibilityIdentifier("contacts.detail.block")
            }
        }
    }

    private func normalizedRemark(for contact: ContactResponseBody) -> String? {
        let value = contact.remark?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }

    private func normalizedProfileDisplayName(for contact: ContactResponseBody) -> String? {
        let value = contact.profileDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty, value != contact.displayName else {
            return nil
        }
        return value
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    private func startConversation(_ contact: ContactResponseBody) {
        contactStore.clearNotice(scope: .detail)
        guard runTask(.startConversation(contact.id), operation: {
            isStartingConversation = true
            let conversationID = await createDirectConversation(contact.email)
            guard !Task.isCancelled else {
                return
            }
            isStartingConversation = false
            if let conversationID {
                dismiss()
                onOpenConversation(conversationID)
            } else {
                contactStore.setNotice("打开会话失败，请稍后重试。", scope: .detail, tone: .error)
            }
        }) else { return }
    }

    private func perform(_ action: ContactDestructiveAction) {
        switch action {
        case .delete:
            deleteCurrentContact()
        case .block:
            blockCurrentContact()
        }
    }

    private func deleteCurrentContact() {
        contactStore.clearNotice(scope: .detail)
        guard runTask(.delete(contactID), operation: {
            isDeleting = true
            let result = await deleteContact(contactID)
            guard !Task.isCancelled else {
                return
            }
            isDeleting = false
            if result.succeeded {
                if !result.message.isEmpty {
                    contactStore.setNotice(result.message, scope: .contactsHome, tone: result.tone)
                }
                dismiss()
            } else if !result.message.isEmpty {
                contactStore.setNotice(result.message, scope: .detail, tone: result.tone)
            }
        }) else { return }
    }

    private func blockCurrentContact() {
        contactStore.clearNotice(scope: .detail)
        guard runTask(.block(contactID), operation: {
            isBlocking = true
            let result = await blockUser(contactID)
            guard !Task.isCancelled else {
                return
            }
            isBlocking = false
            if result.succeeded {
                if !result.message.isEmpty {
                    contactStore.setNotice(result.message, scope: .contactsHome, tone: result.tone)
                }
                dismiss()
            } else if !result.message.isEmpty {
                contactStore.setNotice(result.message, scope: .detail, tone: result.tone)
            }
        }) else { return }
    }

    @discardableResult
    private func runTask(
        _ key: ContactViewTaskKey,
        operation: @escaping @MainActor () async -> Void
    ) -> Bool {
        taskBag.run(key, operation: operation)
    }
}

private struct ContactReportSheet: View {
    @Environment(\.dismiss) private var dismiss

    let contact: ContactResponseBody
    let reportUser: (UUID, String, String?) async -> ContactOperationResult
    let onSuccess: (ContactOperationResult) -> Void

    @State private var form = ContactReportFormModel()
    @State private var isSubmitting = false
    @State private var isConfirmingSubmit = false
    @State private var actionMessage: String?
    @State private var taskBag = ContactTaskBag()

    var body: some View {
        Form {
            Section {
                LabeledContent("用户", value: contact.displayName)
                Picker("原因", selection: $form.reason) {
                    ForEach(ContactReportReason.allCases) { reason in
                        Text(reason.rawValue).tag(reason)
                    }
                }
                .accessibilityIdentifier("contacts.detail.report.reason")

                TextField("补充说明（可选）", text: $form.detail, axis: .vertical)
                    .lineLimit(3...6)
                    .accessibilityIdentifier("contacts.detail.report.detail")
            } footer: {
                Text("举报会提交给平台审核。补充说明最多 \(ContactReportFormModel.maxDetailLength) 个字符。")
            }

            if let validationMessage = form.validationMessage {
                Section {
                    AppStatusBanner(message: validationMessage, tone: .warning)
                }
            } else if let actionMessage {
                Section {
                    AppStatusBanner(message: actionMessage, tone: .error)
                }
            }
        }
        .navigationTitle("举报用户")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            taskBag.cancelAll()
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
                .disabled(isSubmitting)
            }

            ToolbarItem(placement: .confirmationAction) {
                Button {
                    isConfirmingSubmit = true
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("提交")
                    }
                }
                .disabled(isSubmitting || !form.canSubmit)
            }
        }
        .confirmationDialog(
            "确认提交举报？",
            isPresented: $isConfirmingSubmit,
            titleVisibility: .visible
        ) {
            Button("提交举报", role: .destructive) {
                submit()
            }
            .accessibilityIdentifier("contacts.detail.report.submit")

            Button("取消", role: .cancel) { }
        }
    }

    private func submit() {
        guard form.canSubmit else {
            return
        }

        actionMessage = nil
        guard runTask(.report(contact.id), operation: {
            isSubmitting = true
            let result = await reportUser(
                contact.id,
                form.reason.rawValue,
                form.normalizedDetail.isEmpty ? nil : form.normalizedDetail
            )
            guard !Task.isCancelled else {
                return
            }
            isSubmitting = false

            if result.succeeded {
                onSuccess(result)
                dismiss()
            } else if !result.message.isEmpty {
                actionMessage = result.message
            }
        }) else { return }
    }

    @discardableResult
    private func runTask(
        _ key: ContactViewTaskKey,
        operation: @escaping @MainActor () async -> Void
    ) -> Bool {
        taskBag.run(key, operation: operation)
    }
}

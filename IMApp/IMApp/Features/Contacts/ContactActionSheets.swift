import SwiftUI
import IMClientKit

struct SendContactRequestSheet: View {
    @Environment(\.dismiss) private var dismiss
    let contactStore: ContactStore
    let currentUserID: UUID?
    let currentUserEmail: String?
    let sendContactRequest: (String, String, String) async -> ContactOperationResult
    var refreshContactState: (() async -> Void)? = nil

    @State private var form = ContactRequestFormModel()
    @State private var isSubmitting = false
    @State private var validationMessage: String?
    @State private var taskBag = ContactTaskBag()

    var body: some View {
        Form {
            Section {
                TextField("联系人邮箱", text: $form.email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("contacts.add.email")

                TextField("验证消息（可选）", text: $form.message, axis: .vertical)
                    .lineLimit(2...4)
                    .accessibilityIdentifier("contacts.add.message")

                TextField("给对方的备注（可选）", text: $form.remark)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("contacts.add.remark")
            } footer: {
                Text("对方接受后才会成为好友，备注仅自己可见。验证消息最多 \(ContactRequestFormModel.maxMessageLength) 个字符。")
            }

            if let message = visibleValidationMessage, !message.isEmpty {
                Section {
                    AppStatusBanner(message: message, tone: .warning)
                }
            } else if let notice = contactStore.notice(for: .form) ?? contactStore.notice(for: .requests),
                      !notice.message.isEmpty {
                Section {
                    AppStatusBanner(message: notice.message, tone: notice.tone.appStatusTone)
                }
            }
        }
        .navigationTitle("发送好友申请")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            contactStore.clearNotice(scope: .form)
        }
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
                    submit()
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("发送")
                    }
                }
                .disabled(isSubmitting || !currentValidation.isValid)
                .accessibilityIdentifier("contacts.add.submit")
            }
        }
        .onChange(of: form) { _, _ in
            validationMessage = nil
        }
    }

    private var currentValidation: ContactRequestFormValidation {
        form.validation(
            currentUserEmail: currentUserEmail,
            currentUserID: currentUserID,
            contacts: contactStore.contacts,
            requests: contactStore.contactRequests
        )
    }

    private var visibleValidationMessage: String? {
        if let validationMessage {
            return validationMessage
        }
        guard !form.normalizedEmail.isEmpty else {
            return nil
        }
        return currentValidation.message
    }

    private func submit() {
        let validation = currentValidation
        guard validation.isValid else {
            validationMessage = validation.message
            return
        }

        guard runTask(.sendRequest, operation: {
            isSubmitting = true
            if contactStore.shouldRefreshContactState(), let refreshContactState {
                await refreshContactState()
                guard !Task.isCancelled else {
                    return
                }
                let refreshedValidation = currentValidation
                guard refreshedValidation.isValid else {
                    validationMessage = refreshedValidation.message
                    isSubmitting = false
                    return
                }
            }

            let result = await sendContactRequest(
                form.normalizedEmail,
                form.normalizedMessage,
                form.normalizedRemark
            )
            guard !Task.isCancelled else {
                return
            }
            isSubmitting = false
            setContactNotice(result, scope: result.succeeded ? .requests : .form)
            if result.succeeded {
                dismiss()
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

    private func setContactNotice(_ result: ContactOperationResult, scope: ContactNoticeScope) {
        guard !result.message.isEmpty else {
            return
        }
        contactStore.setNotice(result.message, scope: scope, tone: result.tone)
    }
}

struct AcceptContactRequestSheet: View {
    @Environment(\.dismiss) private var dismiss
    let contactStore: ContactStore

    let request: ContactRequestResponseBody
    let acceptContactRequest: (UUID, String) async -> ContactOperationResult

    @State private var form = ContactRemarkFormModel()
    @State private var isSubmitting = false
    @State private var taskBag = ContactTaskBag()

    var body: some View {
        Form {
            Section {
                LabeledContent("申请人", value: request.requester.email)

                if let message = request.message, !message.isEmpty {
                    LabeledContent("验证消息", value: message)
                }

                TextField("给对方的备注（可选）", text: $form.remark)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("contacts.accept.remark")
            } footer: {
                Text("接受后会建立双向好友关系，双方都能在通讯录看到对方。")
            }

            if let validationMessage = form.validationMessage {
                Section {
                    AppStatusBanner(message: validationMessage, tone: .warning)
                }
            } else if let notice = contactStore.notice(for: .form) ?? contactStore.notice(for: .requests),
                      !notice.message.isEmpty {
                Section {
                    AppStatusBanner(message: notice.message, tone: notice.tone.appStatusTone)
                }
            }
        }
        .navigationTitle("接受申请")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            contactStore.clearNotice(scope: .form)
        }
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
                Button("接受") {
                    submit()
                }
                .disabled(isSubmitting || !form.canSubmit)
                .accessibilityIdentifier("contacts.accept.submit")
            }
        }
    }

    private func submit() {
        guard form.canSubmit else {
            return
        }
        guard runTask(.accept(request.id), operation: {
            isSubmitting = true
            let result = await acceptContactRequest(request.id, form.normalizedRemark)
            guard !Task.isCancelled else {
                return
            }
            isSubmitting = false
            setContactNotice(result, scope: .requests)
            if result.succeeded {
                dismiss()
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

    private func setContactNotice(_ result: ContactOperationResult, scope: ContactNoticeScope) {
        guard !result.message.isEmpty else {
            return
        }
        contactStore.setNotice(result.message, scope: scope, tone: result.tone)
    }
}

struct EditContactRemarkSheet: View {
    @Environment(\.dismiss) private var dismiss
    let contactStore: ContactStore

    let contact: ContactResponseBody
    let updateContactRemark: (UUID, String) async -> ContactOperationResult

    @State private var form: ContactRemarkFormModel
    @State private var isSubmitting = false
    @State private var taskBag = ContactTaskBag()

    init(
        contactStore: ContactStore,
        contact: ContactResponseBody,
        updateContactRemark: @escaping (UUID, String) async -> ContactOperationResult
    ) {
        self.contactStore = contactStore
        self.contact = contact
        self.updateContactRemark = updateContactRemark
        _form = State(initialValue: ContactRemarkFormModel(remark: contact.remark ?? ""))
    }

    var body: some View {
        Form {
            Section {
                TextField("备注", text: $form.remark)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("contacts.remark.input")

                LabeledContent("邮箱", value: contact.email)
            } footer: {
                Text("清空备注后，通讯录会直接显示邮箱。")
            }

            if let validationMessage = form.validationMessage {
                Section {
                    AppStatusBanner(message: validationMessage, tone: .warning)
                }
            } else if let notice = contactStore.notice(for: .form) ?? contactStore.notice(for: .detail),
                      !notice.message.isEmpty {
                Section {
                    AppStatusBanner(message: notice.message, tone: notice.tone.appStatusTone)
                }
            }
        }
        .navigationTitle("编辑备注")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            contactStore.clearNotice(scope: .form)
        }
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
                Button("保存") {
                    submit()
                }
                .disabled(isSubmitting || !form.canSubmit)
                .accessibilityIdentifier("contacts.remark.save")
            }
        }
    }

    private func submit() {
        guard form.canSubmit else {
            return
        }
        guard runTask(.refresh("contact-remark-\(contact.id.uuidString)"), operation: {
            isSubmitting = true
            let result = await updateContactRemark(contact.id, form.normalizedRemark)
            guard !Task.isCancelled else {
                return
            }
            isSubmitting = false
            if result.succeeded {
                dismiss()
            } else if !result.message.isEmpty {
                contactStore.setNotice(result.message, scope: .form, tone: result.tone)
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

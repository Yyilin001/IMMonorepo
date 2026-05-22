import SwiftUI
import IMClientKit

struct SendContactRequestSheet: View {
    @Environment(\.dismiss) private var dismiss
    let contactStore: ContactStore
    let sendContactRequest: (String, String, String) async -> Bool

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

            if let message = contactStore.contactRequestActionMessage, !message.isEmpty {
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
            let didSend = await sendContactRequest(email, message, remark)
            isSubmitting = false
            if didSend {
                dismiss()
            }
        }
    }
}

struct AcceptContactRequestSheet: View {
    @Environment(\.dismiss) private var dismiss
    let contactStore: ContactStore

    let request: ContactRequestResponseBody
    let acceptContactRequest: (UUID, String) async -> Bool

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

            if let message = contactStore.contactRequestActionMessage, !message.isEmpty {
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
            let didAccept = await acceptContactRequest(request.id, remark)
            isSubmitting = false
            if didAccept {
                dismiss()
            }
        }
    }
}

struct EditContactRemarkSheet: View {
    @Environment(\.dismiss) private var dismiss
    let contactStore: ContactStore

    let contact: ContactResponseBody
    let updateContactRemark: (UUID, String) async -> Bool

    @State private var remark: String
    @State private var isSubmitting = false

    init(
        contactStore: ContactStore,
        contact: ContactResponseBody,
        updateContactRemark: @escaping (UUID, String) async -> Bool
    ) {
        self.contactStore = contactStore
        self.contact = contact
        self.updateContactRemark = updateContactRemark
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

            if let message = contactStore.contactsMessage, !message.isEmpty {
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
            let didUpdate = await updateContactRemark(contact.id, remark)
            isSubmitting = false
            if didUpdate {
                dismiss()
            }
        }
    }
}

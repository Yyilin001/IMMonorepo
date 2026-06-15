import IMClientKit
import SwiftUI

enum IMCreateConversationMode: String, CaseIterable, Identifiable {
    case direct
    case group

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct:
            return "私聊"
        case .group:
            return "群聊"
        }
    }
}

struct IMCreateConversationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let conversationStore: IMConversationStore
    let runtimeStore: IMConversationRuntimeStore

    @State private var mode: IMCreateConversationMode = .direct
    @State private var conversationTitle = ""
    @State private var memberEmails = ""
    @State private var isSubmitting = false
    @State private var statusSnapshot = IMConversationStatusSnapshot(message: nil)

    var body: some View {
        Form {
            Section {
                Picker("会话类型", selection: $mode) {
                    ForEach(IMCreateConversationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(mode == .direct ? "私聊只需要填写 1 个对方邮箱，创建时不会传会话标题。" : "群聊可以填写 1 个或多个成员；填写标题会创建为群聊。")
            }

            Section("会话信息") {
                if mode == .group {
                    TextField("群聊标题（可选）", text: $conversationTitle)
                }

                TextField(memberEmailPlaceholder, text: $memberEmails, axis: .vertical)
                    .lineLimit(3...6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if let message = statusSnapshot.message {
                Section {
                    IMInlineStatusBanner(message: message)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
        }
        .onAppear {
            refreshStatusSnapshot()
        }
        .onChange(of: conversationStore.statusMessage) { _, _ in
            refreshStatusSnapshot()
        }
        .navigationTitle("新建会话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                if isSubmitting {
                    ProgressView()
                } else {
                    Button("创建") {
                        Task {
                            isSubmitting = true
                            let didCreate = await runtimeStore.createConversation(
                                kind: conversationKind,
                                title: createConversationTitle,
                                memberEmails: parsedMemberEmails
                            )
                            isSubmitting = false

                            if didCreate {
                                dismiss()
                            }
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
        }
    }

    private var memberEmailPlaceholder: String {
        switch mode {
        case .direct:
            return "对方邮箱"
        case .group:
            return "成员邮箱，逗号或换行分隔"
        }
    }

    private var conversationKind: IMConversationKind {
        switch mode {
        case .direct:
            return .direct
        case .group:
            return .group
        }
    }

    private var createConversationTitle: String {
        switch mode {
        case .direct:
            return ""
        case .group:
            return conversationTitle
        }
    }

    private var canSubmit: Bool {
        switch mode {
        case .direct:
            return parsedMemberEmails.count == 1
        case .group:
            return !parsedMemberEmails.isEmpty
        }
    }

    private var parsedMemberEmails: [String] {
        memberEmails
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private func refreshStatusSnapshot() {
        statusSnapshot = IMConversationStatusSnapshot(message: conversationStore.statusMessage)
    }
}

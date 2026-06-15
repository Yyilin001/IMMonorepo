import IMClientKit
import SwiftUI

struct IMAddConversationMembersSheet: View {
    @Environment(\.dismiss) private var dismiss
    let conversationStore: IMConversationStore
    let runtimeStore: IMConversationRuntimeStore

    let conversationID: String

    @State private var memberEmails = ""
    @State private var isSubmitting = false
    @State private var statusSnapshot = IMConversationStatusSnapshot(message: nil)

    var body: some View {
        Form {
            Section("新增成员") {
                TextField("成员邮箱，逗号或换行分隔", text: $memberEmails, axis: .vertical)
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
        .navigationTitle("添加成员")
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
                    Button("添加") {
                        Task {
                            isSubmitting = true
                            let didAdd = await runtimeStore.addConversationMembers(
                                to: conversationID,
                                memberEmails: parsedMemberEmails
                            )
                            isSubmitting = false

                            if didAdd {
                                dismiss()
                            }
                        }
                    }
                    .disabled(parsedMemberEmails.isEmpty)
                }
            }
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

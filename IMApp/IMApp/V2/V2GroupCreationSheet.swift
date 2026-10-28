import SwiftUI

struct V2GroupCreationSheet: View {
    @Bindable var store: V2ConversationListStore
    @Binding var groupTitle: String
    @Binding var groupMemberUserIDs: String
    let created: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.v2UserInteractionContext) private var userContext
    @State private var awaitingOperationID: String?
    @State private var choosingGroupFriends = false
    @State private var groupSubmissionTask: Task<Void, Never>?
    @State private var groupCancellationTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section("群名称") {
                    TextField("群名称", text: $groupTitle)
                        .disabled(store.isCreatingGroupConversation)
                        .accessibilityIdentifier("v2.conversation.group-title")
                }
                Section("初始成员") {
                    if userContext != nil {
                        Button("从好友中选择", systemImage: "person.2") { choosingGroupFriends = true }
                            .sheet(isPresented: $choosingGroupFriends) {
                                if let context = userContext {
                                    V2FriendPickerView(store: context.contacts) { handles in
                                        let existing = groupMemberUserIDs.components(separatedBy: CharacterSet(charactersIn: ",\n"))
                                        groupMemberUserIDs = Array(Set(existing.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } + handles)).sorted().joined(separator: ", ")
                                    }
                                }
                            }
                    }
                    TextEditor(text: $groupMemberUserIDs)
                        .frame(minHeight: 110)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(store.isCreatingGroupConversation)
                        .accessibilityLabel("初始成员公开 ID")
                        .accessibilityHint("输入 @handle，用逗号或换行分隔；可留空创建仅自己的群聊")
                        .accessibilityIdentifier("v2.conversation.group-members")
                    Text("用逗号或换行分隔公开 ID，例如 @alice。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if store.groupCreationNeedsConfirmation {
                    Button("继续核对建群结果") {
                        awaitingOperationID = store.activeGroupCreationOperationID
                        Task { await store.resumePendingGroupCreation() }
                    }
                }
                if let feedback = store.groupConversationFeedback {
                    Text(feedback)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("v2.conversation.group-feedback")
                }
            }
            .v2GroupedPageSurface()
            .navigationTitle("新建群聊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        groupSubmissionTask?.cancel()
                        groupSubmissionTask = nil
                        guard store.pendingGroupConversationOperationID != nil else {
                            dismiss()
                            return
                        }
                        guard groupCancellationTask == nil else { return }
                        groupCancellationTask = Task {
                            await store.cancelPendingGroupConversationCreation()
                            guard !Task.isCancelled else { return }
                            groupCancellationTask = nil
                            dismiss()
                        }
                    }
                        .accessibilityIdentifier("v2.conversation.group-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        guard groupSubmissionTask == nil else { return }
                        let title = groupTitle
                        let members = groupMemberUserIDs
                        groupSubmissionTask = Task {
                            if let roomID = await store.createGroupConversation(title: title, memberHandlesText: members), !Task.isCancelled {
                                groupSubmissionTask = nil
                                groupTitle = ""
                                groupMemberUserIDs = ""
                                created(roomID)
                                dismiss()
                            } else if !Task.isCancelled {
                                groupSubmissionTask = nil
                                awaitingOperationID = store.activeGroupCreationOperationID
                                openCompletedCreationIfNeeded()
                            }
                        }
                    }
                    .disabled(
                        groupTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || store.isCreatingGroupConversation || store.activeGroupCreationOperationID != nil
                    )
                    .accessibilityIdentifier("v2.conversation.group-submit")
                }
            }
            .onAppear { awaitingOperationID = store.activeGroupCreationOperationID }
            .onChange(of: store.completedGroupCreation) { _, _ in openCompletedCreationIfNeeded() }
            .onDisappear {
                groupSubmissionTask?.cancel()
                groupSubmissionTask = nil
                groupCancellationTask?.cancel()
                groupCancellationTask = nil
            }
        }
    }

    private func openCompletedCreationIfNeeded() {
        guard let result = store.completedGroupCreation, result.operationID == awaitingOperationID else { return }
        awaitingOperationID = nil
        created(result.roomID)
        dismiss()
    }

}

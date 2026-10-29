import SwiftUI
import IMV2Core

struct V2GroupCreationSheet: View {
    @Bindable var store: V2ConversationListStore
    @Binding var groupTitle: String
    @Binding var groupMemberUserIDs: String
    let created: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.v2UserInteractionContext) private var userContext
    @State private var memberHandle = ""
    @State private var memberFeedback: String?
    @State private var didSubmit = false
    @State private var awaitingOperationID: String?
    @State private var choosingGroupFriends = false
    @State private var groupSubmissionTask: Task<Void, Never>?
    @State private var groupCancellationTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section("群名称") {
                    TextField("群名称", text: $groupTitle)
                        .disabled(store.isCreatingGroupConversation || store.activeGroupCreationOperationID != nil)
                        .accessibilityIdentifier("v2.conversation.group-title")
                }
                Section {
                    if userContext != nil {
                        Button("从好友中选择", systemImage: "person.badge.plus") { choosingGroupFriends = true }
                            .accessibilityIdentifier("v2.conversation.group.choose-friends")
                    }
                    ForEach(selectedHandles, id: \.self) { handle in
                        HStack(spacing: 12) {
                            if let friend = userContext?.contacts.friends.first(where: { $0.handle == handle }) {
                                V2ContactRow(item: friend)
                            } else {
                                Image(systemName: "person.crop.circle").font(.title2).foregroundStyle(.secondary)
                                Text(handle)
                            }
                            Spacer()
                            Button { remove(handle) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                                .buttonStyle(.borderless).accessibilityLabel("移除 \(handle)")
                        }
                    }
                    if selectedHandles.isEmpty { Text("尚未选择成员").foregroundStyle(.secondary) }
                } header: { Text("群成员（\(selectedHandles.count + 1)）") }
                  footer: { Text("你将自动加入群聊，也可以创建后再邀请好友。") }
                .disabled(store.isCreatingGroupConversation || store.activeGroupCreationOperationID != nil)
                Section {
                    DisclosureGroup("通过公开 ID 添加") {
                        TextField("@handle", text: $memberHandle)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("v2.conversation.group-members")
                        Button("添加成员") {
                            guard let handle = try? V2PublicHandle(memberHandle) else { memberFeedback = "请输入有效的公开 ID，例如 @alice。"; return }
                            append([handle.description]); memberHandle = ""; memberFeedback = nil
                        }
                            .disabled(memberHandle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if let memberFeedback { Text(memberFeedback).font(.footnote).foregroundStyle(.red) }
                    }
                }.disabled(store.isCreatingGroupConversation || store.activeGroupCreationOperationID != nil)
                if store.groupCreationNeedsConfirmation {
                    Button("继续核对建群结果") {
                        awaitingOperationID = store.activeGroupCreationOperationID
                        Task { await store.resumePendingGroupCreation() }
                    }
                }
                if (didSubmit || store.activeGroupCreationOperationID != nil), let feedback = store.groupConversationFeedback {
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
                        didSubmit = true
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
            .sheet(isPresented: $choosingGroupFriends) {
                if let context = userContext {
                    V2FriendPickerView(store: context.contacts) { append($0) }
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

    private var selectedHandles: [String] {
        groupMemberUserIDs.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    private func append(_ handles: [String]) {
        groupMemberUserIDs = Array(Set(selectedHandles + handles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted().joined(separator: ", ")
    }
    private func remove(_ handle: String) { groupMemberUserIDs = selectedHandles.filter { $0 != handle }.joined(separator: ", ") }

    private func openCompletedCreationIfNeeded() {
        guard let result = store.completedGroupCreation, result.operationID == awaitingOperationID else { return }
        awaitingOperationID = nil
        created(result.roomID)
        dismiss()
    }

}

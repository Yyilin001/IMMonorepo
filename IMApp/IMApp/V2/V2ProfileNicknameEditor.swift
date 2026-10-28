import SwiftUI

struct V2ProfileNicknameEditor: View {
    let store: V2PublicIdentitySettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var saveTask: Task<Void, Never>?
    @State private var attemptedSave = false
    @FocusState private var isFocused: Bool

    init(store: V2PublicIdentitySettingsStore) {
        self.store = store
        _name = State(initialValue: store.displayName)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("请输入昵称", text: $name)
                            .focused($isFocused).submitLabel(.done)
                            .accessibilityIdentifier("v2.identity.display-name.edit")
                            .onSubmit { save() }
                        if !name.isEmpty {
                            Button { name = ""; isFocused = true } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.plain).accessibilityLabel("清空昵称")
                                .accessibilityIdentifier("v2.identity.display-name.clear")
                        }
                    }
                } footer: {
                    Text(store.nicknameValidation(name) ?? "支持中文、英文和表情。")
                }
                if attemptedSave, let feedback = store.feedback {
                    Section { Text(feedback).foregroundStyle(.secondary) }
                }
            }
            .v2GroupedPageSurface()
            .navigationTitle("修改昵称").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(store.isSaving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(store.nicknameValidation(name) != nil || !store.canEdit)
                        .accessibilityIdentifier("v2.identity.save")
                }
            }
            .task { isFocused = true }
            .onDisappear { saveTask?.cancel() }
        }.interactiveDismissDisabled(store.isSaving)
    }
    private func save() {
        guard store.nicknameValidation(name) == nil, store.canEdit else { return }
        attemptedSave = true
        saveTask?.cancel()
        saveTask = Task {
            if await store.saveNickname(name), !Task.isCancelled { dismiss() }
        }
    }
}

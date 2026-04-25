import SwiftUI
import IMClientKit

struct EditProfileSheet: View {
    @Environment(\.dismiss) private var dismiss

    let initialEmail: String
    let initialDisplayName: String?
    let initialAvatarPreset: UserAvatarPreset?
    let isSubmitting: Bool
    let message: String?
    let onSubmit: (String?, UserAvatarPreset?) async -> Bool

    @State private var displayName = ""
    @State private var avatarPreset: UserAvatarPreset = .ocean

    var body: some View {
        NavigationStack {
            Form {
                Section("预览") {
                    HStack(spacing: 14) {
                        UserAvatarView(
                            displayName: resolvedPreviewName,
                            email: initialEmail,
                            avatarPreset: avatarPreset,
                            size: 56
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(resolvedPreviewName)
                                .font(.headline)

                            Text(initialEmail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    TextField("显示名称（可选）", text: $displayName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Picker("头像预设", selection: $avatarPreset) {
                        ForEach(UserAvatarPreset.allCases, id: \.self) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                } header: {
                    Text("资料")
                } footer: {
                    Text("显示名称留空时会退回邮箱展示；头像预设会同步到你的资料和直聊对端快照。")
                }

                if let message, !message.isEmpty {
                    Section {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("编辑资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }

                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("保存") {
                            submit()
                        }
                    }
                }
            }
            .task {
                displayName = initialDisplayName ?? ""
                avatarPreset = initialAvatarPreset ?? .ocean
            }
        }
    }

    private var resolvedPreviewName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let normalizedInitialDisplayName = initialDisplayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let normalizedInitialDisplayName, !normalizedInitialDisplayName.isEmpty {
                return normalizedInitialDisplayName
            }
            return initialEmail
        }
        return trimmed
    }

    private func submit() {
        Task {
            let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedDisplayName = trimmedDisplayName.isEmpty ? nil : trimmedDisplayName
            let didSave = await onSubmit(normalizedDisplayName, avatarPreset)
            if didSave {
                dismiss()
            }
        }
    }
}

private extension UserAvatarPreset {
    var displayName: String {
        switch self {
        case .sunrise:
            return "朝阳"
        case .ocean:
            return "海洋"
        case .forest:
            return "森林"
        case .graphite:
            return "石墨"
        case .rose:
            return "玫瑰"
        case .slate:
            return "石板"
        }
    }
}

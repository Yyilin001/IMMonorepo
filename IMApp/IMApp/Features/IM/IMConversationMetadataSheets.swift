import IMClientKit
import SwiftUI

struct IMRenameConversationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var submitter = IMAsyncSubmitter()

    let initialTitle: String
    let onSubmit: (String) async -> Bool

    @State private var title: String = ""

    var body: some View {
        Form {
            Section("群聊名称") {
                TextField("输入新的群聊名称", text: $title)
            }

            if let message = submitter.message, !message.isEmpty {
                Section {
                    IMInlineStatusBanner(message: message)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("修改群名")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if title.isEmpty {
                title = initialTitle
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                if submitter.isSubmitting {
                    ProgressView()
                } else {
                    Button("保存") {
                        Task {
                            await submitter.run(messageOnFailure: "修改群名失败。") {
                                await onSubmit(title.trimmingCharacters(in: .whitespacesAndNewlines))
                            }
                            if submitter.didSucceed {
                                dismiss()
                            }
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct IMEditConversationMetadataSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var submitter = IMAsyncSubmitter()

    let initialTitle: String
    let initialNotice: String
    let initialAvatarPreset: IMConversationAvatarPreset
    let initialMuteAll: Bool
    let onSubmit: (String?, String?, IMConversationAvatarPreset, Bool) async -> Bool

    @State private var title = ""
    @State private var notice = ""
    @State private var avatarPreset: IMConversationAvatarPreset = .ocean
    @State private var muteAll = false

    var body: some View {
        Form {
            Section("群资料") {
                TextField("群名称", text: $title)
                TextField("群公告", text: $notice, axis: .vertical)
                    .lineLimit(3, reservesSpace: true)
            }

            Section("群头像") {
                Picker("预设头像", selection: $avatarPreset) {
                    ForEach(IMConversationAvatarPreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("发言权限") {
                Toggle("全员禁言", isOn: $muteAll)
            }

            if let message = submitter.message, !message.isEmpty {
                Section {
                    IMInlineStatusBanner(message: message)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("编辑群资料")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if title.isEmpty && notice.isEmpty {
                title = initialTitle
                notice = initialNotice
                avatarPreset = initialAvatarPreset
                muteAll = initialMuteAll
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                if submitter.isSubmitting {
                    ProgressView()
                } else {
                    Button("保存") {
                        Task {
                            await submitter.run(messageOnFailure: "保存群资料失败。") {
                                await onSubmit(
                                    title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title.trimmingCharacters(in: .whitespacesAndNewlines),
                                    notice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notice.trimmingCharacters(in: .whitespacesAndNewlines),
                                    avatarPreset,
                                    muteAll
                                )
                            }
                            if submitter.didSucceed {
                                dismiss()
                            }
                        }
                    }
                }
            }
        }
    }
}

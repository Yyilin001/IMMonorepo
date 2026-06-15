import IMClientKit
import SwiftUI
#if canImport(UIKit)
import UIKit
import CoreImage
#endif

/// Invite row rendered by the group invite management sheet.
struct IMGroupInviteRowSnapshot: Identifiable, Equatable {
    let id: String
    let token: String
    let inviteURL: String
    let statusText: String
    let expirationSummaryText: String
    let canRevoke: Bool

    init(invite: IMGroupInviteResponseBody) {
        id = invite.token
        token = invite.token
        inviteURL = invite.inviteURL
        canRevoke = invite.revokedAt == nil
        statusText = canRevoke ? "可用邀请" : "已撤销"
        expirationSummaryText = "使用 \(invite.useCount) 次 · \(invite.expiresAt.formatted(date: .abbreviated, time: .shortened)) 过期"
    }
}

struct IMGroupInviteManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var submitter = IMAsyncSubmitter()

    let conversationID: String
    let loadInvites: () async -> [IMGroupInviteResponseBody]
    let createInvite: () async -> IMGroupInviteResponseBody?
    let revokeInvite: (String) async -> Bool

    @State private var invites: [IMGroupInviteRowSnapshot] = []
    @State private var isLoading = false

    var body: some View {
        List {
            Section {
                Button {
                    Task {
                        await submitter.run(messageOnFailure: "创建邀请链接失败。") {
                            if let invite = await createInvite() {
                                invites.insert(IMGroupInviteRowSnapshot(invite: invite), at: 0)
                                return true
                            }
                            return false
                        }
                    }
                } label: {
                    Label("创建邀请链接", systemImage: "link.badge.plus")
                }
            }

            Section("邀请链接") {
                if isLoading {
                    ProgressView()
                } else if invites.isEmpty {
                    Text("暂无邀请链接。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(invites) { invite in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 12) {
                                IMInviteQRCodeView(text: invite.inviteURL)
                                    .frame(width: 72, height: 72)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(invite.statusText)
                                        .font(.headline)
                                    Text(invite.inviteURL)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    Text(invite.expirationSummaryText)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            HStack {
                                Button {
#if canImport(UIKit)
                                    UIPasteboard.general.string = invite.inviteURL
#endif
                                    submitter.message = "已复制邀请链接。"
                                } label: {
                                    Label("复制", systemImage: "doc.on.doc")
                                }

                                if invite.canRevoke {
                                    Button(role: .destructive) {
                                        Task {
                                            await submitter.run(messageOnFailure: "撤销邀请失败。") {
                                                await revokeInvite(invite.token)
                                            }
                                            await reload()
                                        }
                                    } label: {
                                        Label("撤销", systemImage: "xmark.circle")
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }

            if let message = submitter.message, !message.isEmpty {
                Section {
                    IMInlineStatusBanner(message: message)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("邀请链接")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await reload()
        }
        .refreshable {
            await reload()
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") {
                    dismiss()
                }
            }
        }
    }

    @MainActor
    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        invites = await loadInvites().map(IMGroupInviteRowSnapshot.init)
    }
}

struct IMMemberNicknameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var submitter = IMAsyncSubmitter()

    let initialNickname: String
    let onSubmit: (String?) async -> Bool

    @State private var nickname = ""

    var body: some View {
        Form {
            Section("群昵称") {
                TextField("留空使用资料名", text: $nickname)
                    .textInputAutocapitalization(.never)
            }

            if let message = submitter.message, !message.isEmpty {
                Section {
                    IMInlineStatusBanner(message: message)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("我的群昵称")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if nickname.isEmpty {
                nickname = initialNickname
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
                            let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                            await submitter.run(messageOnFailure: "保存群昵称失败。") {
                                await onSubmit(trimmed.isEmpty ? nil : trimmed)
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

struct IMInviteQRCodeView: View {
    let text: String

    var body: some View {
#if canImport(UIKit)
        if let image = qrImage {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "qrcode")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
#else
        Image(systemName: "qrcode")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
#endif
    }

#if canImport(UIKit)
    private var qrImage: UIImage? {
        guard let data = text.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator")
        else {
            return nil
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else {
            return nil
        }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
#endif
}

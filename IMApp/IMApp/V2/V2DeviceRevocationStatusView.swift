import SwiftUI

/// No account identity, credential material or internal failure codes enter
/// this presentation state. It remains available after signing out.
enum V2DeviceRevocationPresentation: Equatable {
    case hidden, pending, paused, unavailable, retrying
}

struct V2DeviceRevocationStatusView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let state: V2DeviceRevocationPresentation
    let retry: @MainActor () async -> Void
    @State private var retryTask: Task<Void, Never>?

    var body: some View {
        if state != .hidden {
            VStack(alignment: .leading, spacing: 8) {
                if typeSize.isAccessibilitySize {
                    DisclosureGroup {
                        explanation
                    } label: {
                        heading
                    }
                    .accessibilityIdentifier("v2.revocation.details")
                } else {
                    heading
                    explanation
                }
                if state == .paused || state == .unavailable || state == .retrying {
                    Button {
                        guard retryTask == nil else { return }
                        retryTask = Task { await retry(); retryTask = nil }
                    } label: {
                        Text(retryTitle)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(state == .retrying)
                    .accessibilityIdentifier("v2.revocation.retry")
                    .accessibilityHint("重新尝试确认此前的设备退出，不会退出当前账号。")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.regularMaterial)
            .accessibilityElement(children: .contain)
            .onDisappear { retryTask?.cancel(); retryTask = nil }
        }
    }

    private var heading: some View {
        Text(title).font(.headline).accessibilityIdentifier("v2.revocation.status")
    }
    private var explanation: some View {
        Text(message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
    }

    private var retryTitle: LocalizedStringKey { state == .retrying ? "正在重试…" : "重试退出确认" }

    private var title: LocalizedStringKey {
        switch state {
        case .hidden, .pending: "退出等待确认"
        case .paused: "退出确认已暂停"
        case .unavailable: "暂时无法读取退出任务"
        case .retrying: "正在重试退出确认"
        }
    }
    private var message: LocalizedStringKey {
        switch state {
        case .hidden, .pending: "此前的设备退出尚未得到服务器确认。应用打开并联网时会自动重试。"
        case .paused: "此前的设备退出尚未得到服务器确认。请稍后重试。"
        case .unavailable: "请解锁设备后重试。已保存的退出任务会继续保留。"
        case .retrying: "正在恢复此前的退出任务。"
        }
    }
}

import Foundation
import IMV2ClientKit
import IMV2Core
import SwiftUI

struct V2SocialPendingStatusView:View {
    let pending:[V2SocialOperationPending]
    let resume:@MainActor (UUID) async -> Void
    var body:some View {
        if pending.contains(where:{ $0.work.execution != .committed }) { ScrollView { LazyVStack(alignment:.leading) {
            ForEach(pending.filter { $0.work.execution != .committed },id:\.work.id) { item in
                HStack {
                    Text(message(item)).font(.footnote)
                    if item.work.scheduling == .needsAttention {
                        Button("继续确认") { Task { await resume(item.work.id) } }
                    }
                }
            }
        }}.frame(maxHeight:180).padding(8).background(.regularMaterial)
        }
    }
    private func message(_ item:V2SocialOperationPending)->String {
        switch item.work.execution {
        case .conflicted:return "联系人状态已变化，请刷新后重新确认操作。"
        case .closed,.expiredUnsubmitted:return "原操作已结束，新的操作需要重新确认。"
        case .rejected:return "原联系人操作未获准。"
        default:return item.work.scheduling == .needsAttention ? "原操作结果尚未确认，同步已暂停。" : "联系人操作已保存，正在核对原操作结果。"
        }
    }
}

struct V2SocialConfirmationProposal {
    let snapshot:V2SocialOperationSnapshot
    let action:V2SocialOperationAction
    var proposalID:UUID?=nil
    let expiresAt=ContinuousClock.now.advanced(by:.seconds(30))
    var description:String {
        switch action {
        case .relationship(let action):return "目标：\(snapshot.targetUserID.rawValue)；当前关系：\(snapshot.relationshipState.rawValue)；操作：\(action.rawValue)。确认后固定当前版本，不会自动改用新版本。"
        case .userBlock(let action):return "目标：\(snapshot.targetUserID.rawValue)；当前屏蔽状态：\(snapshot.isBlocked ? "已屏蔽" : "未屏蔽")；操作：\(action.rawValue)。确认窗口为两分钟。"
        }
    }
}

struct V2AccountPreferencePendingView:View {
    let pending:[V2AccountPreferencePending]
    let resume:@MainActor (UUID) async -> Void
    var body:some View {
        if pending.contains(where:{ $0.work.execution != .committed }) {
            ScrollView { LazyVStack(alignment:.leading) {
                ForEach(pending.filter { $0.work.execution != .committed },id:\.work.id) { item in
                    HStack {
                        Text(message(item)).font(.footnote)
                        if item.work.scheduling == .needsAttention { Button("继续确认") { Task { await resume(item.work.id) } } }
                    }
                }
            }}.frame(maxHeight:180).padding(8).background(.regularMaterial)
        }
    }
    private func message(_ item:V2AccountPreferencePending)->String {
        switch item.work.execution {
        case .conflicted:return "设置版本已变化，请刷新后重新确认。"
        case .closed,.expiredUnsubmitted:return "原设置操作已结束，新的设置需要重新确认。"
        case .rejected:return "原设置操作未获准。"
        default:return item.work.scheduling == .needsAttention ? "原设置结果尚未确认，同步已暂停。" : "设置已保存，正在核对原操作结果。"
        }
    }
}

private extension Optional where Wrapped == Bool {
    var preferenceDescription:String { switch self { case .some(true):"允许";case .some(false):"不允许";case .none:"保留当前设置" } }
}
extension V2AccountPreferencePatch {
    var confirmationDescription:String {
        switch self {
        case .strangerMessage(let value):return value == .allow ? "允许陌生人消息" : "不允许陌生人消息"
        case .userAdd(let value):return value == .allow ? "允许被添加好友" : "不允许被添加好友"
        case .readReceipt(let direct,let group):return "私聊已读：\(direct.preferenceDescription)；群聊已读：\(group.preferenceDescription)"
        case .liveActivity(let online,let typing):return "在线状态：\(online.preferenceDescription)；输入状态：\(typing.preferenceDescription)"
        }
    }
}

struct V2SocialProposalList:View {
    let proposals:[V2SocialOperationProposal]
    let prepare:@MainActor (V2SocialOperationProposal) async -> Void
    let discard:@MainActor (UUID) async -> Void
    var body:some View {
        if !proposals.isEmpty { ScrollView { LazyVStack(alignment:.leading) {
            ForEach(proposals,id:\.id) { proposal in
                HStack {
                    Text("待确认联系人提案：\(proposal.targetUserID.rawValue)").font(.footnote)
                    Button("读取基线并确认") { Task { await prepare(proposal) } }
                    Button("取消提案") { Task { await discard(proposal.id) } }
                }
            }
        }}.frame(maxHeight:160) }
    }
}

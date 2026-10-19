import SwiftUI
import Observation
import IMV2ClientKit
import IMV2Core

protocol V2PersonalPreferenceManaging: Sendable {
    func preferenceUpdates(limit: Int) async -> AsyncThrowingStream<[V2PersonalPreferencePending], any Error>
    func desiredPreferenceTarget(_ fallback: V2PersonalPreferenceTarget) async throws -> V2PersonalPreferenceTarget
    func resumePreference(_ id: UUID) async throws
    func discardPreference(_ id: UUID) async throws
}

@MainActor @Observable
final class V2PreferenceActivityStore {
    private let manager: any V2PersonalPreferenceManaging
    private(set) var entries: [V2PersonalPreferencePending] = []
    private(set) var error: String?
    private(set) var changingID: UUID?
    private(set) var limit = 200
    init(manager: any V2PersonalPreferenceManaging) { self.manager = manager }
    func loadMore() { limit = min(2000, limit + 200) }
    func observe() async {
        do {
            for try await values in await manager.preferenceUpdates(limit: limit) {
                try Task.checkCancellation()
                entries = values
                error = nil
            }
        } catch is CancellationError { }
        catch { self.error = "无法读取已保存的设置，请重新打开此页。" }
    }
    func resume(_ id: UUID) async {
        guard changingID == nil, entries.contains(where: { $0.id == id && $0.canResume }) else { return }
        changingID = id
        defer { changingID = nil }
        do { try await manager.resumePreference(id); error = nil }
        catch { self.error = "无法继续确认原操作，请稍后重试。" }
    }
    func discard(_ id: UUID) async {
        guard changingID == nil, entries.contains(where: { $0.id == id && $0.canDiscard }) else { return }
        changingID = id
        defer { changingID = nil }
        do { try await manager.discardPreference(id); error = nil }
        catch { self.error = "操作状态已变化，不能移除此记录。请先确认结果。" }
    }
    static func title(_ entry: V2PersonalPreferencePending) -> String {
        switch entry.target {
        case .favorite(_, _, let value): return value ? "收藏消息" : "取消收藏"
        case .conversation(_, let pinned, let archived, let mute):
            return [pinned ? "置顶" : "不置顶", archived ? "归档" : "不归档", mute == nil ? "接收提醒" : "免打扰"].joined(separator: " · ")
        }
    }
    static func status(_ entry: V2PersonalPreferencePending) -> String {
        if entry.expiredUnsubmitted { return "未提交且已过期，请重新检查当前设置。" }
        switch entry.work?.execution {
        case .conflicted: return "设置已被更新。请刷新当前状态后重新设置。"
        case .rejected: return "服务器拒绝了此操作。"
        case .closed: return "服务器已确认此操作不会执行。"
        case .expiredUnsubmitted: return "未提交且已过期。"
        case .awaitingConfirmation, .processing: return entry.canResume ? "结果仍待确认，自动恢复已暂停。" : "正在确认原操作结果。"
        default: return entry.canResume ? "同步已暂停，原设置仍保留。" : "已保存在本机，等待同步。"
        }
    }
}

struct V2PreferenceActivityView: View {
    @State var store: V2PreferenceActivityStore
    let roomTitles: [String: String]
    let openTarget: (String, String?) -> Void
    var body: some View {
        NavigationStack {
            List {
                if let error = store.error { Text(error).foregroundStyle(.secondary) }
                if store.entries.isEmpty { Text("没有待处理的收藏或会话设置。") }
                ForEach(store.entries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            switch entry.target {
                            case .conversation(let room, _, _, _): openTarget(room.rawValue, nil)
                            case .favorite(let room, let message, _): openTarget(room.rawValue, message.rawValue)
                            }
                        } label: {
                            switch entry.target {
                            case .conversation(let room, _, _, _): Text(roomTitles[room.rawValue] ?? "打开对应会话")
                            case .favorite(let room, _, _): Text((roomTitles[room.rawValue] ?? "对应会话") + " · 查看消息")
                            }
                        }
                        Text(V2PreferenceActivityStore.title(entry)).font(.headline)
                        Text(V2PreferenceActivityStore.status(entry)).font(.footnote)
                        HStack {
                            if entry.canResume {
                                Button("继续确认") { Task { await store.resume(entry.id) } }
                            }
                            if entry.canDiscard {
                                Button(entry.work?.execution.isTerminal == true || entry.expiredUnsubmitted ? "移除记录" : "放弃未发送设置", role: .destructive) {
                                    Task { await store.discard(entry.id) }
                                }
                            }
                        }.disabled(store.changingID != nil)
                    }
                }
                if store.entries.count == store.limit && store.limit < 2000 {
                    Button("显示更多记录") { store.loadMore() }
                }
            }
            .navigationTitle("待同步设置")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: store.limit) { await store.observe() }
        }
    }
}

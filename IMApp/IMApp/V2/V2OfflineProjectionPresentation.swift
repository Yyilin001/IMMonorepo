import Foundation
import IMV2ClientKit
import IMV2Core
import Observation
import SwiftUI

/// Read-only UI dependency: no network, command, media or presentation lease ports.
@MainActor @Observable
final class V2OfflineProjectionPresentation {
    let userID: UserID
    private(set) var conversations: [V2ClientConversationListEntry] = []
    private(set) var messages: [V2ClientMessageProjection] = []
    private(set) var ownProfile: V2ProfileView?
    private(set) var localProfiles: V2LocalProfileDisplaySnapshot?
    private(set) var feedback: String?
    private(set) var isLoading = false
    private var conversationCursor: V2ClientConversationListCursor?
    private var timelineCursor: V2ClientTimelineCursor?
    private let store: GRDBV2LocalSyncStore
    private let validate: @Sendable () async throws -> Void
    private let onTrustFailure: @MainActor @Sendable (any Error) async -> Void
    private var closed = false
    private var generation: UInt64 = 0
    init(userID: UserID, store: GRDBV2LocalSyncStore, validate: @escaping @Sendable () async throws -> Void,
         onTrustFailure: @escaping @MainActor @Sendable (any Error) async -> Void) {
        self.userID = userID; self.store = store; self.validate = validate; self.onTrustFailure = onTrustFailure
    }
    private func requireTrust() async throws {
        do { try await validate() }
        catch {
            invalidate()
            await onTrustFailure(error)
            throw error
        }
    }
    var hasMoreConversations: Bool { conversationCursor != nil }
    var hasOlderMessages: Bool { timelineCursor != nil }
    func loadConversations(nextPage: Bool = false) async throws {
        guard !closed else { throw CancellationError() }
        let started = generation
        isLoading = true
        defer { if generation == started { isLoading = false } }
        try await requireTrust()
        let page = try await store.conversationListPage(isArchived: false, before: nextPage ? conversationCursor : nil, limit: 50)
        var allowed: [V2ClientConversationListEntry] = []
        for row in page.entries where try await store.roomAllowsLocalRead(roomID: row.roomID) { allowed.append(row) }
        let profile = try await store.ownProfileSnapshot(accountID: userID)
        let localProfiles = try await store.cachedLocalProfileDisplay(accountID: userID)
        try await requireTrust()
        try Task.checkCancellation()
        guard !closed, generation == started else { throw CancellationError() }
        // Reuse local display facts without introducing network/media ports.
        self.localProfiles = localProfiles
        conversations = allowed; conversationCursor = page.nextCursor; ownProfile = profile
    }
    func loadMessages(roomID: RoomID, older: Bool = false) async {
        guard !closed else { return }
        generation &+= 1
        let started = generation
        if !older { messages = []; timelineCursor = nil }
        isLoading = true; feedback = nil
        defer { if generation == started { isLoading = false } }
        do {
            try await requireTrust()
            guard try await store.roomAllowsLocalRead(roomID: roomID) else { throw V2OfflineReadBootstrapError.localStoreUnavailable }
            let page = try await store.conversationTimelinePage(in: roomID, before: older ? timelineCursor : nil, limit: 100)
            try await requireTrust()
            try Task.checkCancellation()
            guard !closed, generation == started else { return }
            messages = page.messages; timelineCursor = page.olderCursor
        } catch {
            guard !closed, generation == started else { return }
            messages = []; timelineCursor = nil; feedback = "无法读取此会话的本地内容。"
        }
    }
    func invalidate() {
        closed = true; generation &+= 1
        conversations = []; messages = []; ownProfile = nil; localProfiles = nil; feedback = nil; isLoading = false
    }
}

struct V2OfflineRootView: View {
    @Bindable var presentation: V2OfflineProjectionPresentation
    let retryOnline: () async -> Void
    let signOut: () async -> Void
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("当前仅显示本机已保存内容，联网验证后可继续操作。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("重新连接") { Task { await retryOnline() } }
                        .accessibilityIdentifier("v2.offline.retry")
                }
                if let identity = presentation.ownProfile?.publicIdentity {
                    Section("我的资料") { Text(identity.displayName) }
                }
                Section("本地会话") {
                    ForEach(presentation.conversations, id: \.roomID) { row in
                        NavigationLink {
                            V2OfflineMessagesView(presentation: presentation, roomID: row.roomID)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(row.roomProfile?.title ?? row.directIdentity.flatMap {
                                    presentation.localProfiles?.value(for: .init(userID: $0.publicIdentity.userID, context: .directConversation))?.name
                                } ?? "会话")
                                if let message = row.lastMessage {
                                    Text(message.isWithdrawn ? "消息已撤回" : message.text.isEmpty ? "附件（联网后查看）" : message.text)
                                        .lineLimit(1).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if presentation.conversations.isEmpty { Text("暂无允许离线显示的会话").foregroundStyle(.secondary) }
                    if presentation.hasMoreConversations {
                        Button("下一页") { Task { try? await presentation.loadConversations(nextPage: true) } }
                    }
                }
                Section { Button("退出登录", role: .destructive) { Task { await signOut() } } }
            }
            .navigationTitle("本地内容")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("v2.offline.root")
        }
    }
}
private struct V2OfflineMessagesView: View {
    @Bindable var presentation: V2OfflineProjectionPresentation
    let roomID: RoomID
    var body: some View {
        List {
            if presentation.hasOlderMessages {
                Button("查看更早消息") { Task { await presentation.loadMessages(roomID: roomID, older: true) } }
            }
            ForEach(presentation.messages, id: \.messageID) { message in
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.senderUserID == presentation.userID ? "你" : presentation.localProfiles?.value(for: .init(userID: message.senderUserID, context: .room(roomID)))?.name ?? "消息")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(message.isWithdrawn ? "消息已撤回" : message.text.isEmpty ? "附件（联网后查看）" : message.text)
                    Text(message.createdAt, style: .time).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let feedback = presentation.feedback { Text(feedback).foregroundStyle(.secondary) }
        }
        .navigationTitle("本地消息")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: roomID) { await presentation.loadMessages(roomID: roomID) }
    }
}

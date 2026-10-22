import Foundation
import IMV2ClientKit
import IMV2Core
import Observation
import SwiftUI

@MainActor @Observable
final class V2LocalDirectConversationStore {
    let operationID: UUID
    let service: V2DirectRoomOperationService
    private let conversations: V2ConversationListStore
    private(set) var detail: V2ConversationDetailStore?
    private(set) var publicIdentity: V2PublicIdentity?
    private(set) var request: V2DirectRoomPending?
    private(set) var messages: [V2LocalDirectMessage] = []
    private(set) var feedback: String?
    private(set) var isSaving = false
    private var hasLoadedMessages = false
    var draft = ""

    init(operationID: UUID, service: V2DirectRoomOperationService, conversations: V2ConversationListStore) {
        self.operationID = operationID
        self.service = service
        self.conversations = conversations
        publicIdentity = conversations.localDirectIdentity(for: operationID)
    }
    var roomID: String? {
        guard hasLoadedMessages, messages.isEmpty, case .opened(let room, _)? = request?.receipt?.outcome else { return nil }
        return room.rawValue
    }
    func run() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.observeRequest() }
            group.addTask { await self.observeMessages() }
            await group.waitForAll()
        }
    }
    private func observeRequest() async {
        do {
            for try await requests in await service.updates() {
                try Task.checkCancellation()
                request = requests.first { $0.work.id == operationID }
                if let identity = request?.publicIdentity { publicIdentity = identity }
                resolveDetailIfReady()
            }
        } catch is CancellationError { }
        catch { feedback = "会话已保存在本机，暂时无法读取连接状态。" }
    }
    private func observeMessages() async {
        do {
            for try await values in await service.messageUpdates() {
                try Task.checkCancellation()
                messages = values.filter { $0.workID == operationID }
                hasLoadedMessages = true
                resolveDetailIfReady()
            }
        } catch is CancellationError { }
        catch { feedback = "暂时无法读取本地待发送消息。" }
    }
    private func resolveDetailIfReady() {
        guard !isSaving, detail == nil, let roomID, let identity = publicIdentity else { return }
        conversations.registerLocalDirectRoom(roomID, identity: identity)
        detail = conversations.detailStore(for: roomID, initialDraft: draft)
        draft = ""
    }
    func send() async {
        guard !isSaving, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSaving = true
        defer {
            isSaving = false
            resolveDetailIfReady()
        }
        let text = draft
        do {
            try await service.enqueueLocalMessage(text: text, workID: operationID)
            if draft == text { draft = "" }
            feedback = nil
        } catch { feedback = "无法保存消息，输入内容已保留。" }
    }
}

struct V2LocalDirectConversationView: View {
    @State private var store: V2LocalDirectConversationStore
    let conversations: V2ConversationListStore
    let groupInvitations: V2GroupInvitationStore?
    @Environment(\.v2UserInteractionContext) private var context

    init(operationID: UUID, service: V2DirectRoomOperationService,
         conversations: V2ConversationListStore, groupInvitations: V2GroupInvitationStore?) {
        _store = State(initialValue: .init(operationID: operationID, service: service, conversations: conversations))
        self.conversations = conversations
        self.groupInvitations = groupInvitations
    }

    var body: some View {
        @Bindable var store = store
        Group {
            if let detail = store.detail {
                V2ConversationDetailView(store: detail,
                    groupInvitationStore: groupInvitations)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(store.messages) { message in
                                HStack {
                                    Spacer(minLength: 48)
                                    VStack(alignment: .trailing, spacing: 6) {
                                        Text(message.text).padding(14).foregroundStyle(.white)
                                            .background(V2VisualStyle.outgoing, in: RoundedRectangle(cornerRadius: 20))
                                        Text("等待会话连接后发送").font(.caption).foregroundStyle(.secondary)
                                    }
                                }.id(message.id)
                            }
                        }.padding(16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: store.messages.last?.id) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 8) {
                        if let feedback = store.feedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
                        HStack(alignment: .bottom, spacing: 8) {
                            V2ComposerTextInput(text: $store.draft, placeholder: "发送消息…",
                                accessibilityLabel: "消息内容", accessibilityHint: "连接前发送的消息会保存在本机")
                                .accessibilityIdentifier("v2.local-direct.draft")
                            Button { Task { await store.send() } } label: {
                                Image(systemName: "arrow.up").font(.body.weight(.semibold))
                                    .foregroundStyle(.white).frame(width: 36, height: 36)
                                    .background(V2VisualStyle.outgoing, in: Circle())
                            }
                            .disabled(store.isSaving || store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel("发送")
                            .accessibilityIdentifier("v2.local-direct.send")
                        }.padding(10)
                            .background(V2VisualStyle.surface, in: RoundedRectangle(cornerRadius: 26))
                            .overlay(RoundedRectangle(cornerRadius: 26).stroke(.quaternary))
                    }.padding(.horizontal, 16).padding(.vertical, 8).background(.background)
                }
                .navigationTitle(store.publicIdentity?.displayName ?? "聊天")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.publicIdentity?.displayName ?? "聊天").font(.headline)
                                Text(store.request.map { conversations.directConversationRequestStatus($0) } ?? "正在连接")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if store.request?.receipt != nil, !store.messages.isEmpty {
                            Button("重试发送") { Task { try? await store.service.prepareLocalMessages() } }
                        } else if let request = store.request, request.work.scheduling == .needsAttention {
                            Button("重试") { Task { await conversations.resumeDirectConversationRequest(request) } }
                        } else if let request = store.request, request.work.execution.isTerminal,
                                  let identity = request.publicIdentity {
                            Button("重试") {
                                Task {
                                    if let destination = await conversations.openLocalFirstDirectConversation(with: identity) {
                                        context?.navigation.showConversation(destination)
                                    }
                                }
                            }
                        }
                    }
                }
                .accessibilityIdentifier("v2.local-direct.chat")
            }
        }
        .task { await store.run() }
    }
}

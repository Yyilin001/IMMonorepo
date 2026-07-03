import SwiftUI
import IMClientKit

/// Favorite-message row rendered by the favorites sheet.
struct IMFavoriteMessageSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let conversationID: String
    let messageID: String
    let title: String
    let iconName: String
    let previewText: String
    let createdAtText: String

    init(message: IMConversationMessageResponseBody, title: String) {
        let messageID = message.id.uuidString
        self.init(
            id: messageID,
            conversationID: message.conversationID.uuidString,
            messageID: messageID,
            title: Self.normalizedTitle(title),
            iconName: Self.iconName(for: message.content),
            previewText: message.previewText,
            createdAtText: message.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? "时间未知"
        )
    }

    private init(
        id: String,
        conversationID: String,
        messageID: String,
        title: String,
        iconName: String,
        previewText: String,
        createdAtText: String
    ) {
        self.id = id
        self.conversationID = conversationID
        self.messageID = messageID
        self.title = title
        self.iconName = iconName
        self.previewText = previewText
        self.createdAtText = createdAtText
    }

    func replacingTitle(_ title: String) -> IMFavoriteMessageSnapshot {
        IMFavoriteMessageSnapshot(
            id: id,
            conversationID: conversationID,
            messageID: messageID,
            title: Self.normalizedTitle(title),
            iconName: iconName,
            previewText: previewText,
            createdAtText: createdAtText
        )
    }

    private static func normalizedTitle(_ title: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? "会话" : trimmedTitle
    }

    private static func iconName(for content: IMMessageContent) -> String {
        switch content {
        case .richText:
            return "text.bubble"
        case .reply:
            return "arrowshape.turn.up.left"
        case .image:
            return "photo"
        case .audio:
            return "waveform"
        case .file:
            return "doc"
        }
    }
}

/// Stable conversation title used by sheets that receive message-only data.
struct IMConversationTitleSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let title: String

    init(conversation: IMConversation) {
        id = conversation.id
        title = Self.projectedTitle(for: conversation)
    }

    static func projectedTitle(for conversation: IMConversation) -> String {
        let trimmedTitle = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? "会话" : trimmedTitle
    }
}

/// Builds a title lookup so sheets do not repeatedly read raw conversations in body.
struct IMConversationTitleSnapshotBuilder {
    func build(
        conversations: [IMConversation],
        including conversationIDs: Set<String>? = nil
    ) -> [String: String] {
        if conversationIDs?.isEmpty == true {
            return [:]
        }

        return Dictionary<String, String>(
            uniqueKeysWithValues: conversations.compactMap { conversation in
                if let conversationIDs,
                   !conversationIDs.contains(conversation.id) {
                    return nil
                }
                let snapshot = IMConversationTitleSnapshot(conversation: conversation)
                return (snapshot.id, snapshot.title)
            }
        )
    }
}

/// Lightweight dependency signature for title lookups in message-only sheets.
struct IMConversationTitleObservedState: Equatable, Sendable {
    let requestedConversationIDs: [String]
    let titleSignatures: [IMConversationTitleSignature]

    init(
        conversations: [IMConversation],
        including conversationIDs: Set<String>
    ) {
        self.requestedConversationIDs = conversationIDs.sorted()
        self.titleSignatures = conversations
            .filter { conversationIDs.contains($0.id) }
            .map(IMConversationTitleSignature.init)
            .sorted { $0.id < $1.id }
    }
}

struct IMConversationTitleSignature: Equatable, Sendable {
    let id: String
    let title: String

    init(conversation: IMConversation) {
        self.id = conversation.id
        self.title = IMConversationTitleSnapshot.projectedTitle(for: conversation)
    }
}

/// Forward-target row rendered by the message forward picker.
struct IMForwardConversationCandidateSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let previewText: String

    init(conversation: IMConversation) {
        id = conversation.id

        title = Self.projectedTitle(for: conversation)
        previewText = Self.projectedPreviewText(for: conversation)
    }

    static func projectedTitle(for conversation: IMConversation) -> String {
        let trimmedTitle = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? "会话" : trimmedTitle
    }

    static func projectedPreviewText(for conversation: IMConversation) -> String {
        let trimmedPreview = conversation.lastMessagePreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPreview.isEmpty ? "\(conversation.memberCount) 位成员" : trimmedPreview
    }
}

/// Lightweight dependency signature for the forward picker candidate list.
struct IMForwardConversationCandidateObservedState: Equatable, Sendable {
    let sourceConversationID: String
    let candidateSignatures: [IMForwardConversationCandidateSignature]

    init(
        conversations: [IMConversation],
        excluding sourceConversationID: String
    ) {
        self.sourceConversationID = sourceConversationID
        self.candidateSignatures = conversations
            .filter { $0.id != sourceConversationID }
            .map(IMForwardConversationCandidateSignature.init)
            .sorted { $0.id < $1.id }
    }
}

struct IMForwardConversationCandidateSignature: Equatable, Sendable {
    let id: String
    let title: String
    let previewText: String
    let updatedAt: Date

    init(conversation: IMConversation) {
        self.id = conversation.id
        self.title = IMForwardConversationCandidateSnapshot.projectedTitle(for: conversation)
        self.previewText = IMForwardConversationCandidateSnapshot.projectedPreviewText(for: conversation)
        self.updatedAt = conversation.updatedAt
    }
}

/// Builds sorted forward candidates at the sheet refresh boundary.
struct IMForwardConversationCandidateSnapshotBuilder {
    func build(
        conversations: [IMConversation],
        excluding sourceConversationID: String
    ) -> [IMForwardConversationCandidateSnapshot] {
        conversations
            .filter { $0.id != sourceConversationID }
            .sorted {
                if $0.updatedAt == $1.updatedAt {
                    return $0.id < $1.id
                }
                return $0.updatedAt > $1.updatedAt
            }
            .map(IMForwardConversationCandidateSnapshot.init)
    }
}

@MainActor
extension IMConversationStore {
    func forwardConversationCandidateSnapshots(
        excluding sourceConversationID: String
    ) -> [IMForwardConversationCandidateSnapshot] {
        IMForwardConversationCandidateSnapshotBuilder().build(
            conversations: conversations,
            excluding: sourceConversationID
        )
    }
}

struct IMFavoritesSheet: View {
    @Environment(\.dismiss) var dismiss

    let conversationStore: IMConversationStore
    let runtimeStore: IMConversationRuntimeStore

    let onSelect: (String, String) -> Void

    @State var messages: [IMFavoriteMessageSnapshot] = []
    @State var nextCursor: String?
    @State var hasMore = false
    @State var isLoading = false
    @State var statusMessage: String?
    @State var titleSnapshotByConversationID: [String: String] = [:]

    var body: some View {
        List {
            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if messages.isEmpty && !isLoading {
                ContentUnavailableView("暂无收藏", systemImage: "star", description: Text("收藏后的消息会出现在这里。"))
            } else {
                Section {
                    ForEach(messages) { message in
                        Button {
                            onSelect(message.conversationID, message.messageID)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Image(systemName: message.iconName)
                                        .foregroundStyle(.secondary)

                                    Text(message.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }

                                Text(message.previewText)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)

                                Text(message.createdAtText)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }

                    if hasMore {
                        Button {
                            Task {
                                await loadMore()
                            }
                        } label: {
                            Label(isLoading ? "加载中" : "加载更多", systemImage: "clock.arrow.circlepath")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(isLoading)
                    }
                }
            }
        }
        .navigationTitle("我的收藏")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") {
                    dismiss()
                }
            }
        }
        .task {
            refreshTitleSnapshots()
            if messages.isEmpty {
                await reload()
            }
        }
        .onChange(of: favoriteTitleObservedState) { _, _ in
            refreshTitleSnapshots()
        }
        .refreshable {
            await reload()
        }
    }

    var favoriteTitleObservedState: IMConversationTitleObservedState {
        IMConversationTitleObservedState(
            conversations: conversationStore.conversations,
            including: Set(messages.map(\.conversationID))
        )
    }

    func reload() async {
        messages = []
        nextCursor = nil
        hasMore = false
        await loadMore()
    }

    func loadMore() async {
        guard !isLoading else {
            return
        }

        isLoading = true
        defer { isLoading = false }

        guard let page = await runtimeStore.fetchFavorites(cursor: nextCursor, limit: 50) else {
            statusMessage = "收藏列表加载失败，请稍后重试。"
            return
        }

        statusMessage = nil
        let loadedConversationIDs = Set(messages.map(\.conversationID))
            .union(page.items.map { $0.conversationID.uuidString })
        refreshTitleSnapshots(conversationIDs: loadedConversationIDs)
        messages.append(
            contentsOf: page.items.map { message in
                IMFavoriteMessageSnapshot(
                    message: message,
                    title: title(forConversationID: message.conversationID.uuidString)
                )
            }
        )
        nextCursor = page.nextCursor
        hasMore = page.hasMore
    }

    func refreshTitleSnapshots(conversationIDs: Set<String>? = nil) {
        let ids = conversationIDs ?? Set(messages.map(\.conversationID))
        guard !ids.isEmpty else {
            titleSnapshotByConversationID = [:]
            return
        }

        titleSnapshotByConversationID = IMConversationTitleSnapshotBuilder().build(
            conversations: conversationStore.conversations,
            including: ids
        )
        messages = messages.map { message in
            message.replacingTitle(title(forConversationID: message.conversationID))
        }
    }

    func title(forConversationID conversationID: String) -> String {
        titleSnapshotByConversationID[conversationID] ?? "会话"
    }
}

struct IMForwardMessagePickerSheet: View {
    @Environment(\.dismiss) var dismiss

    let conversationStore: IMConversationStore

    let sourceConversationID: String
    let messageCount: Int
    let onForward: ([String]) async -> Bool

    @State var selectedConversationIDs: Set<String> = []
    @State var candidates: [IMForwardConversationCandidateSnapshot] = []
    @State var isForwarding = false
    @State var statusMessage: String?

    var body: some View {
        List {
            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if candidates.isEmpty {
                    ContentUnavailableView("暂无可转发会话", systemImage: "arrowshape.turn.up.right", description: Text("创建或加载更多会话后再转发。"))
                } else {
                    ForEach(candidates) { conversation in
                        Button {
                            toggle(conversation.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedConversationIDs.contains(conversation.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedConversationIDs.contains(conversation.id) ? Color.accentColor : .secondary)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(conversation.title.isEmpty ? "会话" : conversation.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    Text(conversation.previewText)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } footer: {
                Text("将 \(messageCount) 条消息转发到选中的会话。")
            }
        }
        .navigationTitle("选择转发会话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("取消") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(isForwarding ? "转发中" : "转发") {
                    Task {
                        await forward()
                    }
                }
                .disabled(selectedConversationIDs.isEmpty || isForwarding)
            }
        }
        .onAppear {
            refreshCandidates()
        }
        .onChange(of: forwardCandidateObservedState) { _, _ in
            refreshCandidates()
        }
    }

    var forwardCandidateObservedState: IMForwardConversationCandidateObservedState {
        IMForwardConversationCandidateObservedState(
            conversations: conversationStore.conversations,
            excluding: sourceConversationID
        )
    }

    func refreshCandidates() {
        candidates = conversationStore.forwardConversationCandidateSnapshots(excluding: sourceConversationID)
        let candidateIDs = Set(candidates.map(\.id))
        selectedConversationIDs.formIntersection(candidateIDs)
    }

    func toggle(_ conversationID: String) {
        if selectedConversationIDs.contains(conversationID) {
            selectedConversationIDs.remove(conversationID)
        } else {
            selectedConversationIDs.insert(conversationID)
        }
    }

    func forward() async {
        guard !selectedConversationIDs.isEmpty, !isForwarding else {
            return
        }

        isForwarding = true
        defer { isForwarding = false }

        let didForward = await onForward(Array(selectedConversationIDs))
        if didForward {
            dismiss()
        } else {
            statusMessage = "转发失败，请稍后重试。"
        }
    }
}

struct IMBatchMessageSendSheet: View {
    @Environment(\.dismiss) var dismiss

    let senderName: String
    let canSendMessages: Bool
    let onSendMessage: (String) async -> Bool

    @State var nextMessageNumber = 1
    @State var sentCount = 0
    @State var failedCount = 0
    @State var isSending = false
    @State var statusText = "待开始"
    @State var sendTask: Task<Void, Never>?

    let finalMessageNumber = 10_000
    let sendIntervalNanoseconds: UInt64 = 300_000_000

    var body: some View {
        Form {
            Section {
                LabeledContent("当前用户", value: senderName)
                LabeledContent("下一条序号", value: "\(nextMessageNumber)")
                LabeledContent("已发送", value: "\(sentCount)")
                LabeledContent("失败", value: "\(failedCount)")
            }

            Section {
                ProgressView(value: progressValue, total: Double(finalMessageNumber))
                    .progressViewStyle(.linear)

                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Section {
                HStack(spacing: 12) {
                    Button {
                        startSending()
                    } label: {
                        Label(isSending ? "发送中" : "开始", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStartSending)

                    Button(role: .destructive) {
                        stopSending()
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!isSending)
                }

                Button {
                    resetProgress()
                } label: {
                    Label("重置", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .disabled(isSending || (nextMessageNumber == 1 && sentCount == 0 && failedCount == 0))
            } footer: {
                Text("每 0.3 秒发送一条，内容为 \(senderName) + 序号，直到 10000。")
            }
        }
        .navigationTitle("批量发送")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") {
                    dismiss()
                }
            }
        }
        .onDisappear {
            stopSending()
        }
    }

    var canStartSending: Bool {
        canSendMessages && !isSending && nextMessageNumber <= finalMessageNumber
    }

    var progressValue: Double {
        Double(max(0, min(finalMessageNumber, nextMessageNumber - 1)))
    }

    func startSending() {
        guard canStartSending else {
            return
        }

        sendTask?.cancel()
        sendTask = Task { @MainActor in
            await runSendLoop()
        }
    }

    @MainActor
    func runSendLoop() async {
        isSending = true
        statusText = "正在发送..."
        defer {
            isSending = false
            sendTask = nil
        }

        while nextMessageNumber <= finalMessageNumber, !Task.isCancelled {
            let currentNumber = nextMessageNumber
            let messageText = "\(senderName) \(currentNumber)"
            let didSend = await onSendMessage(messageText)

            if didSend {
                sentCount += 1
                statusText = "已发送 \(currentNumber)"
            } else {
                failedCount += 1
                statusText = "发送失败 \(currentNumber)"
            }

            nextMessageNumber = currentNumber + 1

            guard nextMessageNumber <= finalMessageNumber, !Task.isCancelled else {
                break
            }

            do {
                try await Task.sleep(nanoseconds: sendIntervalNanoseconds)
            } catch {
                break
            }
        }

        if nextMessageNumber > finalMessageNumber {
            statusText = "已完成 10000 条"
        } else if Task.isCancelled {
            statusText = "已停止，下一条 \(nextMessageNumber)"
        }
    }

    func stopSending() {
        sendTask?.cancel()
        if isSending {
            statusText = "已停止，下一条 \(nextMessageNumber)"
        } else {
            sendTask = nil
        }
    }

    func resetProgress() {
        nextMessageNumber = 1
        sentCount = 0
        failedCount = 0
        statusText = "待开始"
    }
}

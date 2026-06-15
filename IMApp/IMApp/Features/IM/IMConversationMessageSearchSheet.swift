import IMClientKit
import SwiftUI

/// Search-result row rendered by the in-conversation message search sheet.
struct IMConversationMessageSearchResultSnapshot: Identifiable, Equatable {
    let id: String
    let snippet: String
    let previewText: String
    let createdAtText: String?

    init(
        id: String,
        snippet: String,
        previewText: String,
        createdAtText: String?
    ) {
        self.id = id
        self.snippet = snippet
        self.previewText = previewText
        self.createdAtText = createdAtText
    }

    init(hit: IMConversationMessageSearchHitResponseBody) {
        self.init(
            id: hit.messageID.uuidString,
            snippet: hit.snippet,
            previewText: hit.previewText,
            createdAtText: hit.createdAt?.formatted(date: .abbreviated, time: .shortened)
        )
    }
}

struct IMConversationMessageSearchSheet: View {
    @Environment(\.dismiss) private var dismiss

    let runtimeStore: IMConversationRuntimeStore
    let conversationID: String
    let onSelect: (String) -> Void

    @State private var query = ""
    @State private var results: [IMConversationMessageSearchResultSnapshot] = []
    @State private var nextCursor: String?
    @State private var isSearching = false
    @State private var statusMessage: String?

    var body: some View {
        List {
            if let statusMessage, !statusMessage.isEmpty {
                Section {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if results.isEmpty, !isSearching {
                Section {
                    ContentUnavailableView(
                        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "输入关键字开始搜索" : "没有找到匹配消息",
                        systemImage: "magnifyingglass",
                        description: Text("支持搜索文本消息、引用预览、系统消息文案和文件名。")
                    )
                }
            } else {
                Section("搜索结果") {
                    ForEach(results) { result in
                        Button {
                            dismiss()
                            onSelect(result.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(result.snippet)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                Text(result.previewText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                if let createdAtText = result.createdAtText {
                                    Text(createdAtText)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }

                    if isSearching {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else if nextCursor != nil {
                        Button("加载更多结果") {
                            Task {
                                await runSearch(reset: false)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
        .navigationTitle("搜索消息")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索消息内容、系统消息、文件名")
        .onSubmit(of: .search) {
            Task {
                await runSearch(reset: true)
            }
        }
        .onChange(of: query) { _, newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                results = []
                nextCursor = nil
                statusMessage = nil
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("搜索") {
                    Task {
                        await runSearch(reset: true)
                    }
                }
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
            }
        }
    }

    private func runSearch(reset: Bool) async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            results = []
            nextCursor = nil
            statusMessage = nil
            return
        }

        isSearching = true
        defer { isSearching = false }

        let cursor = reset ? nil : nextCursor
        guard let page = await runtimeStore.searchMessages(
            in: conversationID,
            query: trimmedQuery,
            cursor: cursor,
            limit: 20
        ) else {
            if reset {
                results = []
            }
            statusMessage = "搜索失败，请稍后重试。"
            return
        }

        if reset {
            results = page.items.map(IMConversationMessageSearchResultSnapshot.init)
        } else {
            results.append(contentsOf: page.items.map(IMConversationMessageSearchResultSnapshot.init))
        }
        nextCursor = page.nextCursor
        statusMessage = results.isEmpty ? "没有找到匹配消息。" : nil
    }
}

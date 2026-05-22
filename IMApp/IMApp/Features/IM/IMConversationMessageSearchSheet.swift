import IMClientKit
import SwiftUI

struct IMConversationMessageSearchSheet: View {
    @Environment(\.dismiss) private var dismiss

    let runtimeStore: IMConversationRuntimeStore
    let conversationID: String
    let onSelect: (String) -> Void

    @State private var query = ""
    @State private var results: [IMConversationMessageSearchHitResponseBody] = []
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
                    ForEach(results, id: \.messageID) { hit in
                        Button {
                            dismiss()
                            onSelect(hit.messageID.uuidString)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(hit.snippet)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                Text(hit.content.previewText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
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
            results = page.items
        } else {
            results.append(contentsOf: page.items)
        }
        nextCursor = page.nextCursor
        statusMessage = results.isEmpty ? "没有找到匹配消息。" : nil
    }
}

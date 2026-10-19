import SwiftUI

struct V2FriendPickerView: View {
    @Bindable var store: V2ContactsStore
    var maximumSelection = 50
    var excludedUserIDs: Set<String> = []
    let onSelect: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: Set<String> = []
    @State private var selectedHandles: [String: String] = [:]
    @State private var originalQuery = ""
    @State private var pageID = UUID()
    var body: some View {
        NavigationStack {
            List {
                if store.filteredFriends.isEmpty { Text("没有可选择的好友").foregroundStyle(.secondary) }
                ForEach(store.filteredFriends.filter { !excludedUserIDs.contains($0.id) }) { friend in
                    Button {
                        guard let handle = friend.handle else { return }
                        if selected.contains(friend.id) { selected.remove(friend.id); selectedHandles[friend.id] = nil }
                        else if selected.count < maximumSelection { selected.insert(friend.id); selectedHandles[friend.id] = handle }
                    } label: {
                        HStack {
                            V2ContactRow(item: friend)
                            Spacer()
                            Image(systemName: selected.contains(friend.id) ? "checkmark.circle.fill" : "circle")
                        }
                    }.buttonStyle(.plain).disabled(friend.handle == nil)
                        .accessibilityIdentifier("v2.friend-picker.\(friend.id)")
                }
                if store.canLoadMoreFriends {
                    ProgressView().onAppear { Task { await store.loadMoreFriends() } }
                }
            }
            .v2GroupedPageSurface()
            .navigationTitle("选择好友")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索好友")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("选择（\(selected.count)）") { onSelect(selected.sorted().compactMap { selectedHandles[$0] }); dismiss() }
                        .disabled(selected.isEmpty)
                }
            }
            .task { originalQuery = store.searchQuery; store.searchQuery = ""; await store.refresh() }
            .task(id: query) {
                do { try await Task.sleep(for: .milliseconds(250)); try Task.checkCancellation() }
                catch { return }
                store.searchQuery = query
                await store.refreshFriendSearch()
            }
            .onDisappear { store.searchQuery = originalQuery }
        }.authorPresentationPage(context: .list(pageID))
    }
}

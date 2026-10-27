import Foundation
import IMV2ClientKit
import IMV2Core
import Observation
import SwiftUI

struct V2ResourceBusinessManagers: Sendable {
    let profile: (any V2ProfileIntentManaging)?
    let group: (@MainActor @Sendable (RoomID, GroupAvatarOperationID) -> V2GroupAvatarManagementStore)?
}

@MainActor @Observable
final class V2ResourceBusinessOwnersStore {
    struct Selection: Equatable { let id = UUID(); let owner: V2ResourceBusinessOwner }
    struct Presentation: Identifiable {
        enum Content { case profile(V2ResourceProfileIntentStore), group(V2GroupAvatarManagementStore) }
        let id = UUID()
        let content: Content
    }
    let transfer: V2ManagedResourceTransferID
    let service: V2ResourceManagementService
    private(set) var page: V2ResourceBusinessOwnerPage?
    private(set) var cursor: V2ResourceBusinessOwnerCursor?
    private(set) var pageNumber = 1
    private var previous: [V2ResourceBusinessOwnerCursor?] = []
    private var loadedCursor: V2ResourceBusinessOwnerCursor?
    private var readAvailable = false
    private(set) var selection: Selection?
    var presentation: Presentation?
    private(set) var feedback: String?
    private(set) var isReading = true
    private(set) var isOpening = false
    var hasCurrentPage: Bool { !isReading && readAvailable && loadedCursor == cursor && page != nil }
    var canGoNextPage: Bool { hasCurrentPage && !isOpening && page?.nextCursor != nil }
    var canGoPreviousPage: Bool { hasCurrentPage && !isOpening && !previous.isEmpty }
    init(transfer: V2ManagedResourceTransferID, service: V2ResourceManagementService) { self.transfer = transfer; self.service = service }
    func observe() async {
        let expected = cursor
        isReading = true; readAvailable = false
        do {
            let stream = try await service.center.businessOwnerSnapshots(for: .init(transfer: transfer, before: expected))
            for await snapshot in stream {
                guard !Task.isCancelled, cursor == expected else { return }
                isReading = false
                switch snapshot {
                case .available(let value): page = value; loadedCursor = expected; readAvailable = true; feedback = nil
                case .unavailable: readAvailable = false; feedback = "无法读取相关更改，请重新打开。"
                }
            }
            guard !Task.isCancelled, cursor == expected else { return }
            isReading = false; readAvailable = false; page = nil; presentation = nil; selection = nil
            feedback = "当前账号不可用，请重新连接账号。"
        } catch {
            if !Task.isCancelled, cursor == expected {
                isReading = false; readAvailable = false; feedback = V2ResourceFailure.message(error)
                if (error as? V2ResourceStorageError) == .closed { page = nil; presentation = nil; selection = nil }
            }
        }
    }
    func nextPage() { guard canGoNextPage, let next = page?.nextCursor else { return }; previous.append(cursor); cursor = next; pageNumber += 1; isReading = true }
    func previousPage() { guard canGoPreviousPage else { return }; cursor = previous.removeLast(); pageNumber -= 1; isReading = true }
    func select(_ owner: V2ResourceBusinessOwner) {
        guard hasCurrentPage, !isOpening, page?.entries.contains(where: { $0.owner == owner }) == true else { return }
        selection = .init(owner: owner)
    }
    func open(_ request: Selection, managers: V2ResourceBusinessManagers) async {
        guard selection == request else { return }
        isOpening = true; feedback = nil
        defer { isOpening = false; if selection == request { selection = nil } }
        do {
            guard try await service.center.containsBusinessOwner(request.owner, transfer: transfer) else { throw V2ResourceTransferManagementError.actionUnavailable }
            guard !Task.isCancelled, selection == request else { return }
            switch request.owner {
            case .profileIntent(let id):
                guard let manager = managers.profile else { feedback = "个人资料管理暂不可用，请重新连接账号。"; return }
                presentation = .init(content: .profile(.init(transfer: transfer, intentID: id, center: service.center, manager: manager)))
            case .groupAvatar(let room, let id):
                guard let make = managers.group else { feedback = "群头像管理暂不可用，请重新连接账号。"; return }
                let destination = make(room, id)
                guard destination.roomID == room, destination.focusedOperationID == id else { throw V2ResourceStorageError.unavailable }
                presentation = .init(content: .group(destination))
            }
        } catch { if !Task.isCancelled { feedback = V2ResourceFailure.message(error) } }
    }
}

struct V2ResourceBusinessOwnersView: View {
    @State private var store: V2ResourceBusinessOwnersStore
    private let managers: V2ResourceBusinessManagers
    init(transfer: V2ManagedResourceTransferID, service: V2ResourceManagementService, managers: V2ResourceBusinessManagers) {
        self.managers = managers; _store = State(initialValue: .init(transfer: transfer, service: service))
    }
    var body: some View {
        @Bindable var store = store
        List {
            Section {
                if let page = store.page {
                    if page.entries.isEmpty { ContentUnavailableView("相关更改已处理", systemImage: "checkmark.circle") }
                    ForEach(page.entries) { entry in
                        Button { store.select(entry.owner) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    Label(Self.title(entry.owner), systemImage: Self.symbol(entry.owner)).foregroundStyle(.primary)
                                    Text(entry.createdAt, format: .dateTime.year().month().day().hour().minute().second()).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                            }
                        }.disabled(!store.hasCurrentPage || store.isOpening)
                            .accessibilityIdentifier(Self.identifier(entry.owner))
                    }
                } else if store.isReading { ProgressView("正在读取相关更改") }
            } footer: { Text("打开对应更改，可确认结果、继续处理或按当前状态放弃。") }
            if store.pageNumber > 1 || store.page?.nextCursor != nil {
                Section {
                    HStack {
                        Button("上一页") { store.previousPage() }.disabled(!store.canGoPreviousPage)
                        Spacer(); Text("第 \(store.pageNumber) 页").font(.footnote); Spacer()
                        Button("下一页") { store.nextPage() }.disabled(!store.canGoNextPage)
                    }
                }
            }
            if store.isOpening { Section { ProgressView("正在打开更改") } }
            if let feedback = store.feedback { Section { Text(feedback).foregroundStyle(.secondary) } }
        }.v2GroupedPageSurface().navigationTitle("相关更改").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
            .task(id: store.cursor) { await store.observe() }
            .task(id: store.selection) { if let request = store.selection { await store.open(request, managers: managers) } }
            .sheet(item: $store.presentation) { item in
                switch item.content {
                case .profile(let state): V2ResourceProfileIntentView(store: state)
                case .group(let state): V2GroupAvatarManagementView(store: state)
                }
            }
    }
    private static func title(_ owner: V2ResourceBusinessOwner) -> String { switch owner { case .profileIntent: "个人资料更改"; case .groupAvatar: "群头像更改" } }
    private static func symbol(_ owner: V2ResourceBusinessOwner) -> String { switch owner { case .profileIntent: "person.crop.circle"; case .groupAvatar: "person.2" } }
    private static func identifier(_ owner: V2ResourceBusinessOwner) -> String {
        switch owner { case .profileIntent(let id): "v2.resources.owner.profile." + id.uuidString; case .groupAvatar(_, let id): "v2.resources.owner.group." + id.rawValue }
    }
}

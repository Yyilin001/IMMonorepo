import Foundation
import IMV2ClientKit
import IMV2Core
import Observation

@MainActor
@Observable
final class V2PendingGroupAvatarsStore {
    enum State { case inactive, loading, loaded(V2PendingGroupAvatarPage), failed }
    struct Selection: Identifiable {
        var id: GroupAvatarOperationID { operationID }
        let roomID: RoomID
        let operationID: GroupAvatarOperationID
    }
    private struct Read {
        let activation: UUID
        let after: V2PendingGroupAvatarPage.Cursor?
    }
    private(set) var state: State = .inactive
    private(set) var isFirstPage = true
    private let reader: any V2PendingGroupAvatarReading
    private let notifier: V2ProjectionChangeNotifier?
    private let makeManagement: @MainActor (RoomID, GroupAvatarOperationID) -> V2GroupAvatarManagementStore
    private var activation: UUID?
    private var after: V2PendingGroupAvatarPage.Cursor?
    private var queuedRead: Read?
    private var readTask: Task<Void, Never>?
    private var closed = false

    init(reader: any V2PendingGroupAvatarReading, notifier: V2ProjectionChangeNotifier?,
         makeManagement: @escaping @MainActor (RoomID, GroupAvatarOperationID) -> V2GroupAvatarManagementStore) {
        self.reader = reader; self.notifier = notifier; self.makeManagement = makeManagement
    }

    var page: V2PendingGroupAvatarPage? { if case .loaded(let page) = state { page } else { nil } }

    func managementStore(for selection: Selection) -> V2GroupAvatarManagementStore {
        makeManagement(selection.roomID, selection.operationID)
    }

    func observe() async {
        guard !closed, !Task.isCancelled else { return }
        let epoch = UUID(); activation = epoch; after = nil; isFirstPage = true
        guard let notifier else { requestRead(after: nil); return }
        for await _ in await notifier.updates(scopes: .conversationDetails) {
            guard activation == epoch, !Task.isCancelled else { return }
            requestRead(after: after)
        }
        if activation == epoch { suspend() }
    }

    func refresh() { requestRead(after: nil) }
    func refreshCurrentPage() { requestRead(after: after) }
    func nextPage() {
        guard let next = page?.next else { return }
        requestRead(after: next)
    }

    func suspend() {
        activation = nil; queuedRead = nil
        readTask?.cancel()
        after = nil; isFirstPage = true; state = .inactive
    }

    func close() async {
        closed = true
        suspend()
        await readTask?.value
    }

    private func requestRead(after: V2PendingGroupAvatarPage.Cursor?) {
        guard !closed, let activation else { return }
        let request = Read(activation: activation, after: after)
        queuedRead = request
        self.after = after; isFirstPage = after == nil; state = .loading
        launchReadIfNeeded()
    }

    private func launchReadIfNeeded() {
        guard readTask == nil, queuedRead != nil else { return }
        // One owned read plus one coalesced demand. Even a non-cooperative read
        // retains its slot across dismiss/reopen until its actual completion.
        readTask = Task {
            defer {
                readTask = nil
                if activation != nil { launchReadIfNeeded() }
            }
            while let request = queuedRead, !Task.isCancelled {
                queuedRead = nil
                do {
                    let page = try await reader.pendingPage(after: request.after)
                    // Reads are serial. A newer notification for the same page
                    // must not starve completed local results during IM bursts.
                    guard activation == request.activation, after == request.after, !Task.isCancelled else { continue }
                    if page.entries.isEmpty, request.after != nil {
                        requestRead(after: nil)
                    } else { state = .loaded(page) }
                } catch {
                    guard activation == request.activation, after == request.after, !Task.isCancelled else { continue }
                    state = .failed
                }
            }
        }
    }
}

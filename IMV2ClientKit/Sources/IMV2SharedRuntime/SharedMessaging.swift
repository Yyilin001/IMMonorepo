import Foundation
import IMV2Core
import IMV2ClientRuntime

struct SharedSearchHit: Encodable, Sendable { let id: String; let roomID: String; let text: String; let senderID: String }
struct SharedSearch: Encodable, Sendable { let query: String; let roomID: String?; let status: String; let hits: [SharedSearchHit]; let hasNext: Bool }
struct SharedMessageWork: Encodable, Sendable { let id: String; let messageID: String; let kind: String; let text: String?; let status: String; let retryable: Bool }
struct SharedReaders: Encodable, Sendable { let roomID: String; let messageID: String; let users: [String]; let hasNext: Bool; let remainingMilliseconds: Int64 }
struct SharedMessagingView: Encodable, Sendable {
    let roomID: String?; let isGroup: Bool; let allowsReadReceipts: Bool; let ownReadSequence: UInt64
    let mutations: [SharedMessageWork]; let readStatus: String?; let canRetryRead: Bool
    let search: SharedSearch?; let readers: SharedReaders?; let interactions: SharedInteractionView; let failure: String?
}
/// Android composition only: existing Swift services own search, mutation identity,
/// receipt coalescing, privacy policy, durable retry and execution.
actor SharedMessaging {
    private let account: UserID; private let store: GRDBV2LocalSyncStore
    private let messages: V2MessageService; private let reads: V2ReadReceiptService
    private let searchService: V2SearchService
    private let interactions: SharedInteractions
    private var preparation: Task<Void,Never>?
    private var observations: [Task<Void,Never>] = []
    private var room: RoomID?; private var mutationRows: [V2MessageMutationSnapshot] = []
    private var readWork: V2OperationWork?; private var failure: SharedFailure?
    private var searchRequest: V2MessageSearchRequest?; private var searchRoom: RoomID?
    private var searchVisible = false; private var nextSearch: V2MessageSearchCursor?
    private var readerPage: V2ReadReceiptReadersPage?; private var readerDeadline: ContinuousClock.Instant?
    init(account: UserID, store: GRDBV2LocalSyncStore, messages: V2MessageService, search: V2SearchService, reads: V2ReadReceiptService) {
        self.account = account; self.store = store; self.messages = messages
        self.searchService = search; self.reads = reads
        interactions = .init(store: store, messages: messages)
    }
    func start() async {
        await searchService.startIndexing()
        preparation = Task { do { try await reads.runPreparation() } catch is CancellationError {} catch { failure = sharedFailure(error) } }
    }
    func handlers() async -> [V2OperationWorkDispatcher.Handler] {
        await reads.handlers()
    }
    func open(_ room: RoomID) async {
        if self.room == room { return }
        await interactions.open(room)
        observations.forEach { $0.cancel() }; for task in observations { await task.value }
        self.room = room; mutationRows = []; readWork = nil; readerPage = nil
        observations = [Task { do { for try await value in await messages.mutationUpdates(in: room) { mutationRows = value } } catch is CancellationError {} catch { failure = sharedFailure(error) } },
            Task { do { for try await value in await reads.updates(in: room) { readWork = value.work } } catch is CancellationError {} catch { failure = sharedFailure(error) } }]
    }
    func clearTransient() { searchVisible = false; searchRequest = nil; nextSearch = nil; searchRoom = nil; readerPage = nil; readerDeadline = nil }
    func close() async {
        await interactions.close()
        clearTransient(); preparation?.cancel(); observations.forEach { $0.cancel() }
        await preparation?.value; for task in observations { await task.value }; observations = []; preparation = nil
        await searchService.stopIndexing()
    }
    func message(room: RoomID, id: MessageID) async throws -> V2ClientMessageProjection {
        try await messages.message(in: room, id: id)
    }
    func action(_ request: SharedRequest, room: RoomID) async throws {
        if request.action == "retry" {
            guard let id = UUID(uuidString: request.intentID ?? ""), let work = try await store.operationWork(id: id),
                  case .message(let scope, _) = work.identity.scope, scope == room else { throw SharedFailure.invalidInput }
            try await messages.retryMutation(id); return
        }
        if request.action == "readRetry" { try await reads.resumeConfirmation(in: room); return }
        let value = try await message(room: room, id: MessageID(request.messageID ?? ""))
        guard value.senderUserID == account, !value.isWithdrawn, let revision = request.revision,
              revision == value.messageRevision else { throw SharedFailure.invalidInput }
        switch request.action {
        case "edit":
            guard let text = request.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SharedFailure.invalidInput }
            _ = try await messages.edit(in: room, messageID: value.messageID, expectedRevision: revision, text: text)
        case "withdraw": _ = try await messages.withdraw(in: room, messageID: value.messageID, expectedRevision: revision)
        default: throw SharedFailure.invalidInput
        }
    }
    func interact(_ request: SharedRequest, room: RoomID) async throws {
        if request.operation == .interactionAction { try await interactions.action(request, room: room); return }
        let value = try await message(room: room, id: MessageID(request.messageID ?? ""))
        try await interactions.forward(request, message: value)
    }
    /// IDs are viewport evidence, never caller-provided sequence numbers. Resolve
    /// authorized projections and use roomSequence, not timelineSequence/ACK.
    func visible(_ ids: [String], room: RoomID) async throws {
        try await reads.recordVisible(in: room, messageIDs: ids.map(MessageID.init))
    }
    func search(_ request: SharedRequest) throws {
        if request.action == "next" {
            guard let current = searchRequest, let cursor = nextSearch else { throw SharedFailure.invalidInput }
            searchRequest = .init(query: current.query, scope: current.scope,
                                  contentFilter: current.contentFilter, senderUserID: current.senderUserID,
                                  limit: 20, cursor: cursor)
        } else {
            let query = (request.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard query.utf8.count <= 1024 else { throw SharedFailure.invalidInput }
            let filter = V2MessageSearchContentFilter(rawValue: request.scope ?? "all") ?? .all
            let sender = try request.targetUserID.map(UserID.init)
            searchRoom = try request.roomID.map(RoomID.init)
            searchRequest = (query.isEmpty && filter == .all) ? nil : .init(query: query,
                scope: searchRoom.map(V2MessageSearchScope.room) ?? .allMessages,
                contentFilter: filter, senderUserID: sender, limit: 20)
        }
        searchVisible = true; nextSearch = nil
    }
    func readers(_ request: SharedRequest, room: RoomID) async throws {
        let value = try await message(room: room, id: MessageID(request.messageID ?? ""))
        guard value.senderUserID == account, !value.isWithdrawn, try await store.roomProfile(roomID: room) != nil else { throw SharedFailure.invalidInput }
        let cursor: String?
        if request.action == "next" {
            guard let page = readerPage, page.roomID == room, page.messageID == value.messageID,
                  let next = page.nextCursor else { throw SharedFailure.invalidInput }; cursor = next
        } else { cursor = nil }
        readerPage = nil; readerDeadline = nil
        let page = try await reads.readers(in: room, messageID: value.messageID, cursor: cursor)
        _ = try await message(room: room, id: value.messageID)
        guard page.nextCursor == nil || page.nextCursor != cursor else { throw SharedFailure.operationFailed }
        readerPage = page; readerDeadline = .now.advanced(by: .seconds(30))
    }
    func snapshot() async throws -> SharedMessagingView {
        var search: SharedSearch?
        if searchVisible {
            var hits: [SharedSearchHit] = []; var status = "empty"
            if let request = searchRequest {
                do {
                    if let searchRoom, try await !store.roomAllowsLocalRead(roomID: searchRoom) { throw SharedFailure.invalidInput }
                    let page = try await searchService.search(request)
                    nextSearch = page.nextCursor; hits = page.hits.map { .init(id: $0.messageID.rawValue, roomID: $0.roomID.rawValue, text: String($0.text.prefix(160)), senderID: $0.senderUserID.rawValue) }; status = "ready"
                } catch is CancellationError { throw CancellationError() }
                catch V2MessageSearchError.indexUnavailable(let state) { status = String(describing: state); nextSearch = nil }
                catch V2MessageSearchError.cursorDoesNotMatchScope { status = "refreshRequired"; nextSearch = nil }
                catch { status = "unavailable"; nextSearch = nil }
            }
            search = .init(query: searchRequest?.query ?? "", roomID: searchRoom?.rawValue, status: status, hits: hits, hasNext: nextSearch != nil)
        }
        var readers: SharedReaders?
        if let page = readerPage, let deadline = readerDeadline, deadline > .now,
           let value = try? await message(room: page.roomID, id: page.messageID), !value.isWithdrawn {
            let d = ContinuousClock.now.duration(to: deadline)
            readers = .init(roomID: page.roomID.rawValue, messageID: page.messageID.rawValue, users: page.readers.map(\.userID.rawValue), hasNext: page.nextCursor != nil,
                remainingMilliseconds: max(0, d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000))
        } else { readerPage = nil; readerDeadline = nil }
        let receiptState = if let room { try await reads.state(in: room) } else { nil as V2ReadReceiptState? }
        let accessible = receiptState?.accessible ?? false
        let isGroup = receiptState?.isGroup ?? false
        let allowed = receiptState?.allowsPublication ?? false
        let own = receiptState?.ownReadSequence ?? 0
        return .init(roomID: room?.rawValue, isGroup: isGroup, allowsReadReceipts: allowed, ownReadSequence: own,
            mutations: accessible ? mutationRows.prefix(50).map { row in
                let id: MessageID; let text: String?
                switch row.payload { case .edit(let command): id = command.messageID; text = command.text; case .withdraw(let command): id = command.messageID; text = nil }
                return .init(id: row.work.id.uuidString, messageID: id.rawValue, kind: row.work.identity.kind.rawValue, text: text,
                    status: row.work.execution.isTerminal ? row.work.execution.rawValue : row.work.scheduling.rawValue,
                    retryable: !row.work.execution.isTerminal && row.work.scheduling == .needsAttention)
            } : [], readStatus: accessible ? readWork.map { $0.execution.isTerminal ? $0.execution.rawValue : $0.scheduling.rawValue } : nil,
            canRetryRead: accessible && readWork?.scheduling == .needsAttention, search: search, readers: readers, interactions: await interactions.snapshot(accessible: accessible), failure: failure?.rawValue)
    }
}

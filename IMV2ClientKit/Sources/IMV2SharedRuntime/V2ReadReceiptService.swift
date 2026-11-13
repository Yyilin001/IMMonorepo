import Foundation
import IMV2Core
import IMV2ClientRuntime

public enum V2ReadReceiptServiceError: Error, Sendable { case closed, invalidInput }

public struct V2ReadReceiptState: Sendable {
    public let accessible: Bool
    public let isGroup: Bool
    public let allowsPublication: Bool
    public let ownReadSequence: UInt64
}

/// Account-owned receipt commands, privacy queries and group reader queries.
/// Durable max coalescing, recovery identities and privacy-paused work stay in the existing service.
public actor V2ReadReceiptService {
    public nonisolated let accountID: UserID
    private let store: GRDBV2LocalSyncStore
    private let receipts: V2ReadReceiptOperationService
    private let transport: any V2ClientReadReceiptTransport
    private let operations = V2ResourceOperationScope(limit: 128)
    private var closed = false
    private var closing: Task<Void, Never>?
    private var observers: [UUID: (task: Task<Void, Never>, finish: @Sendable () -> Void)] = [:]

    public init(accountID: UserID, store: GRDBV2LocalSyncStore, receipts: V2ReadReceiptOperationService,
                transport: any V2ClientReadReceiptTransport) {
        self.accountID = accountID; self.store = store; self.receipts = receipts; self.transport = transport
    }
    private func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        guard !closed else { throw V2ReadReceiptServiceError.closed }
        let value = try await operations.run(body)
        guard !closed else { throw V2ReadReceiptServiceError.closed }
        try Task.checkCancellation()
        return value
    }
    /// Native clients supply their existing locally verified viewport/checkpoint sequence.
    /// Admission remains durable even while publication is paused by privacy preferences.
    @discardableResult public func recordReadThrough(in room: RoomID, roomSequence: UInt64) async throws -> Bool {
        try await run { [receipts] in try await receipts.enqueue(roomID: room, readThrough: roomSequence) }
    }
    /// Bindings submit visible identities, never untrusted sequence numbers. Stale or
    /// withdrawn viewport rows are skipped; ACK/timeline sequences cannot advance receipts.
    public func recordVisible(in room: RoomID, messageIDs: [MessageID]) async throws {
        try await run { [self] in
            guard !messageIDs.isEmpty, messageIDs.count <= 50,
                  try await store.roomAllowsLocalRead(roomID: room),
                  try await store.allowsLocalReadReceiptPublication(roomID: room) else { return }
            var through: UInt64 = 0
            for id in Set(messageIDs) {
                try Task.checkCancellation()
                if case .found(let window) = try await store.conversationTimelineWindow(in: room, for: accountID, around: id, before: 0, after: 0),
                   let value = window.page.messages.first(where: { $0.messageID == id }) {
                    through = max(through, value.roomSequence)
                }
            }
            if through > 0 { _ = try await receipts.enqueue(roomID: room, readThrough: through) }
        }
    }
    public func state(in room: RoomID) async throws -> V2ReadReceiptState {
        try await run { [store] in
            let accessible = try await store.roomAllowsLocalRead(roomID: room)
            guard accessible else { return .init(accessible: false, isGroup: false, allowsPublication: false, ownReadSequence: 0) }
            return try await .init(accessible: true, isGroup: store.roomProfile(roomID: room) != nil,
                allowsPublication: store.allowsLocalReadReceiptPublication(roomID: room), ownReadSequence: store.roomReadWatermark(roomID: room) ?? 0)
        }
    }
    private func requireReaders(in room: RoomID, messageID: MessageID) async throws {
        guard try await store.roomAllowsLocalRead(roomID: room),
              try await store.roomProfile(roomID: room) != nil,
              case .found(let window) = try await store.conversationTimelineWindow(in: room, for: accountID, around: messageID, before: 0, after: 0),
              let value = window.page.messages.first(where: { $0.messageID == messageID }),
              value.senderUserID == accountID, !value.isWithdrawn else { throw V2ReadReceiptServiceError.invalidInput }
    }
    public func readers(in room: RoomID, messageID: MessageID, cursor: String? = nil, limit: Int = 50) async throws -> V2ReadReceiptReadersPage {
        try await run { [self] in
            try await requireReaders(in: room, messageID: messageID)
            let page = try await transport.listReadReceiptReaders(roomID: room, messageID: messageID, cursor: cursor, pageSize: limit)
            try Task.checkCancellation()
            try await requireReaders(in: room, messageID: messageID)
            guard page.nextCursor == nil || page.nextCursor != cursor else { throw V2ReadReceiptServiceError.invalidInput }
            return page
        }
    }
    public func resumeConfirmation(in room: RoomID) async throws { try await run { [receipts] in try await receipts.resumeConfirmation(roomID: room) } }
    public func archiveUnavailable(_ workID: UUID) async throws { try await run { [receipts] in try await receipts.archiveUnavailable(workID: workID) } }
    public func restoreArchive(_ workID: UUID) async throws { try await run { [receipts] in try await receipts.restoreArchive(workID: workID) } }
    public func updates(in room: RoomID) -> AsyncThrowingStream<V2ReadReceiptTrackingSnapshot, any Error> {
        observe { [receipts] in await receipts.statusUpdates(roomID: room) }
    }
    public func runPreparation() async throws { try await run { [receipts] in try await receipts.runPreparation() } }
    public func handlers() -> [V2OperationWorkDispatcher.Handler] {
        [.init(kind: .readReceipt) { [self] claim in try await run { [receipts] in try await receipts.execute(claim) } }]
    }
    private func observe<T: Sendable>(_ source: @escaping @Sendable () async -> AsyncThrowingStream<T, any Error>) -> AsyncThrowingStream<T, any Error> {
        let (stream, continuation) = AsyncThrowingStream<T, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard !closed else { continuation.finish(throwing: V2ReadReceiptServiceError.closed); return stream }
        let id = UUID()
        let task = Task { [weak self] in
            do {
                for try await value in await source() {
                    try Task.checkCancellation()
                    continuation.yield(value)
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
            await self?.removeObserver(id)
        }
        observers[id] = (task, { continuation.finish(throwing: V2ReadReceiptServiceError.closed) })
        continuation.onTermination = { [weak self] _ in task.cancel(); Task { await self?.removeObserver(id) } }
        return stream
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id)?.task.cancel() }

    public func close() async {
        if let closing { await closing.value; return }
        closed = true
        let captured = Array(observers.values); observers.removeAll()
        let task = Task { [operations] in
            for observer in captured { observer.task.cancel(); observer.finish() }
            await operations.close()
            for observer in captured { await observer.task.value }
        }
        closing = task; await task.value
    }
}

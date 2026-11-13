import Foundation
import IMV2Core

/// C ABI observation cursor. The window owns a bounded observer; each ABI call owns
/// only its waiter. A cancelled waiter cannot close another window's observation.
actor SharedConversationWindowReader {
    nonisolated let window: V2ConversationWindow
    nonisolated let room: RoomID?
    nonisolated var id: String { window.id.uuidString }
    private var producer: Task<Void, Never>?
    private var pending: V2ConversationWindowUpdate?
    private var waiter: (id: UUID, continuation: CheckedContinuation<V2ConversationWindowUpdate, any Error>)?
    private var failure: (any Error)?
    private var closed = false
    init(window: V2ConversationWindow, room: RoomID?) { self.window = window; self.room = room }
    func next() async throws -> V2ConversationWindowContent {
        while true {
            let update = try await nextUpdate()
            if try await window.accepts(update) { return update.value }
        }
    }
    private func nextUpdate() async throws -> V2ConversationWindowUpdate {
        try Task.checkCancellation()
        guard !closed else { throw SharedFailure.closed }
        if let failure { throw failure }
        guard waiter == nil else { throw SharedFailure.busy }
        if let pending { self.pending = nil; return pending }
        if producer == nil {
            producer = Task { [weak self, window] in
                do {
                    let updates = await window.updates()
                    for try await value in updates.stream {
                        guard !Task.isCancelled else { break }
                        await self?.receive(value)
                    }
                    await self?.finish(SharedFailure.closed)
                } catch { await self?.finish(error) }
            }
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { waiter = (id, $0) }
        } onCancel: { Task { await self.cancelWaiter(id) } }
    }
    private func receive(_ value: V2ConversationWindowUpdate) {
        guard !closed else { return }
        if let waiter { self.waiter = nil; waiter.continuation.resume(returning: value) }
        else { pending = value }
    }
    private func finish(_ error: any Error) {
        failure = error; pending = nil
        waiter?.continuation.resume(throwing: error); waiter = nil
    }
    private func cancelWaiter(_ id: UUID) {
        guard waiter?.id == id else { return }
        waiter?.continuation.resume(throwing: CancellationError()); waiter = nil
    }
    func close() async {
        closed = true; finish(SharedFailure.closed)
        producer?.cancel(); await window.close(); await producer?.value; producer = nil
    }
}

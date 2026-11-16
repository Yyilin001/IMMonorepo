import Foundation
import IMV2Core
import IMV2ClientRuntime

struct SharedForwardWork: Encodable, Sendable {
    let id: String; let status: String; let succeeded: Int; let rejected: Int; let cancelled: Int; let unresolved: Int
    let retryable: Bool; let cancellable: Bool
}
struct SharedInteractionView: Encodable, Sendable { let forwards: [SharedForwardWork]; let failure: String? }

actor SharedInteractions {
    private let store: GRDBV2LocalSyncStore
    private let messages: V2MessageService
    private var observation: Task<Void, Never>?
    private var room: RoomID?
    private var forwardRows: [V2ForwardPlanSnapshot] = []
    private var failure: SharedFailure?
    init(store: GRDBV2LocalSyncStore, messages: V2MessageService) {
        self.store = store; self.messages = messages
    }
    func open(_ room: RoomID) async {
        guard self.room != room else { return }
        observation?.cancel()
        await observation?.value
        self.room = room
        forwardRows = []
        observation = Task {
            do {
                for try await rows in await messages.forwardUpdates(in: room) { forwardRows = rows }
            } catch is CancellationError {
            } catch { failure = sharedFailure(error) }
        }
    }
    func close() async {
        observation?.cancel()
        await observation?.value
        observation = nil; forwardRows = []; room = nil
    }
    func forward(_ request: SharedRequest, message: V2ClientMessageProjection) async throws {
        guard let revision = request.revision, revision == message.messageRevision, let raw = request.targetRoomID else { throw SharedFailure.invalidInput }
        let target = try RoomID(raw)
        guard try await store.roomAllowsLocalRead(roomID: target) else { throw SharedFailure.invalidInput }
        _ = try await messages.forward(sources: [.init(roomID: message.roomID, messageID: message.messageID, revision: .init(revision))], to: [target])
    }
    func action(_ request: SharedRequest, room: RoomID) async throws {
        guard self.room == room, try await store.roomAllowsLocalRead(roomID: room), let id = UUID(uuidString: request.intentID ?? "") else { throw SharedFailure.invalidInput }
        switch request.action {
        case "retryForward", "cancelForward":
            guard forwardRows.contains(where: { $0.work.id == id }) else { throw SharedFailure.invalidInput }
            if request.action == "retryForward" { try await messages.retryForward(id) }
            else { try await messages.cancelForward(id) }
        default: throw SharedFailure.invalidInput
        }
    }
    func snapshot(accessible: Bool) -> SharedInteractionView {
        .init(forwards: accessible ? forwardRows.prefix(50).map { row in
            .init(id: row.work.id.uuidString, status: row.work.execution.isTerminal ? row.work.execution.rawValue : row.work.scheduling.rawValue,
                  succeeded: row.succeeded, rejected: row.rejected, cancelled: row.cancelled, unresolved: row.unresolved,
                  retryable: !row.work.execution.isTerminal && row.work.scheduling == .needsAttention,
                  cancellable: !row.work.execution.isTerminal && !row.cancellationRequested)
        } : [], failure: failure?.rawValue)
    }
}

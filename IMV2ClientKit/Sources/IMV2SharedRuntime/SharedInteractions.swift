import Foundation
import IMV2Core
import IMV2ClientRuntime

struct SharedReaction: Encodable, Sendable { let value: String; let count: Int; let includesMe: Bool }
struct SharedReactionWork: Encodable, Sendable { let id: String; let messageID: String; let reaction: String; let present: Bool; let status: String; let retryable: Bool }
struct SharedForwardWork: Encodable, Sendable {
    let id: String; let status: String; let succeeded: Int; let rejected: Int; let cancelled: Int; let unresolved: Int
    let retryable: Bool; let cancellable: Bool
}
struct SharedInteractionView: Encodable, Sendable { let reactions: [SharedReactionWork]; let forwards: [SharedForwardWork]; let failure: String? }

/// Composition only. Existing Swift services own desired-state coalescing,
/// frozen forward revisions, durable identity, cancellation and recovery.
actor SharedInteractions {
    private let store: GRDBV2LocalSyncStore
    private let messages: V2MessageService
    private var preparation: Task<Void, Never>?
    private var observations: [Task<Void, Never>] = []
    private var room: RoomID?
    private var reactionRows: [V2MessageReactionPending] = []
    private var forwardRows: [V2ForwardPlanSnapshot] = []
    private var failure: SharedFailure?
    init(store: GRDBV2LocalSyncStore, messages: V2MessageService) {
        self.store = store; self.messages = messages
    }
    func start() {
        preparation = Task { do { try await messages.runReactionPreparation() } catch is CancellationError {} catch { failure = sharedFailure(error) } }
    }
    func open(_ room: RoomID) async {
        guard self.room != room else { return }
        observations.forEach { $0.cancel() }; for task in observations { await task.value }
        self.room = room; reactionRows = []; forwardRows = []
        observations = [Task { do { for try await rows in await messages.reactionUpdates(in: room) { reactionRows = rows } } catch is CancellationError {} catch { failure = sharedFailure(error) } },
            Task { do { for try await rows in await messages.forwardUpdates(in: room) { forwardRows = rows } } catch is CancellationError {} catch { failure = sharedFailure(error) } }]
    }
    func close() async {
        preparation?.cancel(); observations.forEach { $0.cancel() }
        await preparation?.value; for task in observations { await task.value }
        preparation = nil; observations = []; reactionRows = []; forwardRows = []; room = nil
    }
    func react(_ request: SharedRequest, message: V2ClientMessageProjection) async throws {
        guard let reaction = request.reaction, request.action == "add" || request.action == "remove" else { throw SharedFailure.invalidInput }
        _ = try await messages.react(in: message.roomID, messageID: message.messageID, reaction: reaction, targetState: request.action == "add" ? .present : .absent)
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
        case "retryReaction":
            guard reactionRows.contains(where: { $0.intent.id == id }) else { throw SharedFailure.invalidInput }
            try await messages.retryReaction(id)
        case "retryForward", "cancelForward":
            guard forwardRows.contains(where: { $0.work.id == id }) else { throw SharedFailure.invalidInput }
            if request.action == "retryForward" { try await messages.retryForward(id) }
            else { try await messages.cancelForward(id) }
        default: throw SharedFailure.invalidInput
        }
    }
    func snapshot(accessible: Bool) -> SharedInteractionView {
        .init(reactions: accessible ? reactionRows.prefix(50).map { row in
            let status = row.expiredUnsubmitted ? "expiredUnsubmitted" : row.work.map { $0.execution.isTerminal ? $0.execution.rawValue : $0.scheduling.rawValue } ?? (row.preparationPaused ? "paused" : "preparing")
            return .init(id: row.intent.id.uuidString, messageID: row.intent.messageID.rawValue, reaction: row.intent.reaction, present: row.intent.targetState == .present, status: status,
                         retryable: !row.expiredUnsubmitted && (row.work.map { !$0.execution.isTerminal && $0.scheduling == .needsAttention } ?? row.preparationPaused))
        } : [], forwards: accessible ? forwardRows.prefix(50).map { row in
            .init(id: row.work.id.uuidString, status: row.work.execution.isTerminal ? row.work.execution.rawValue : row.work.scheduling.rawValue,
                  succeeded: row.succeeded, rejected: row.rejected, cancelled: row.cancelled, unresolved: row.unresolved,
                  retryable: !row.work.execution.isTerminal && row.work.scheduling == .needsAttention,
                  cancellable: !row.work.execution.isTerminal && !row.cancellationRequested)
        } : [], failure: failure?.rawValue)
    }
}

import Foundation
import IMV2Core
import IMV2ClientRuntime

public enum V2MessageServiceError: Error, Sendable { case closed, invalidInput }

/// Account-owned message commands. The existing durable services remain the authority
/// for identity, admission, retry, revision conflicts and delivery confirmation.
public actor V2MessageService {
    public nonisolated let accountID: UserID
    private let store: GRDBV2LocalSyncStore
    private let sends: V2MessageSendOperationService
    private let mutations: V2MessageMutationOperationService
    private let reactions: V2MessageReactionOperationService
    private let forwards: V2ForwardPlanOperationService
    private let operations = V2ResourceOperationScope(limit: 128)
    private var closed = false
    private var closing: Task<Void, Never>?
    private var observers: [UUID: (task: Task<Void, Never>, finish: @Sendable () -> Void)] = [:]

    /// Composition boundary; production services are registered with V2SharedSession.
    public init(accountID: UserID, store: GRDBV2LocalSyncStore, sends: V2MessageSendOperationService,
                mutations: V2MessageMutationOperationService, reactions: V2MessageReactionOperationService,
                forwards: V2ForwardPlanOperationService) {
        self.accountID = accountID; self.store = store; self.sends = sends
        self.mutations = mutations; self.reactions = reactions; self.forwards = forwards
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        guard !closed else { throw V2MessageServiceError.closed }
        return try await operations.run(body)
    }

    public func message(in room: RoomID, id: MessageID) async throws -> V2ClientMessageProjection {
        try await run { [self] in try await readableMessage(in: room, id: id) }
    }
    private func readableMessage(in room: RoomID, id: MessageID) async throws -> V2ClientMessageProjection {
        guard try await store.roomAllowsLocalRead(roomID: room),
              case .found(let window) = try await store.conversationTimelineWindow(in: room, for: accountID, around: id, before: 0, after: 0),
              let message = window.page.messages.first(where: { $0.messageID == id }) else { throw V2MessageServiceError.invalidInput }
        return message
    }

    @discardableResult public func send(in room: RoomID, text: String, mentions: [V2MentionTarget] = [],
        entities: [V2MessageEntity] = [], replyTo: V2MessageReplyReference? = nil) async throws -> UUID {
        try await run { [self] in
            guard try await store.roomAllowsLocalRead(roomID: room) else { throw V2MessageServiceError.invalidInput }
            if let replyTo { _ = try await readableMessage(in: room, id: replyTo.messageID) }
            let id = try await sends.enqueueMessage(roomID: room, text: text, mentions: mentions, entities: entities, replyTo: replyTo)
            // Freeze is the durable boundary. Recovery retains the same identity if cancellation
            // interrupts handoff; caller cancellation never deletes an already frozen intent.
            _ = try await store.handOffSendIntent(id)
            return id
        }
    }

    /// Resource adapters prepare bytes; the shared message service freezes the consumer and
    /// upload dependencies atomically using the existing transfer engine.
    public func sendPreparedAttachments(_ intent: V2SendIntent, resources: [V2ResourcePreparedUpload],
        using transfers: V2ResourceTransferEngine) async throws {
        try await run { [self] in
            guard try await store.roomAllowsLocalRead(roomID: intent.roomID) else { throw V2MessageServiceError.invalidInput }
            if let reply = intent.replyTo { _ = try await readableMessage(in: intent.roomID, id: reply.messageID) }
            try await transfers.prepareSend(intent, resources: resources)
        }
    }

    @discardableResult public func edit(in room: RoomID, messageID: MessageID, expectedRevision: UInt64, text: String) async throws -> UUID {
        try await run { [self] in
            try await requireEditable(in: room, id: messageID, revision: expectedRevision)
            return try await mutations.enqueueEdit(roomID: room, messageID: messageID, expectedRevision: expectedRevision, text: text)
        }
    }
    @discardableResult public func withdraw(in room: RoomID, messageID: MessageID, expectedRevision: UInt64) async throws -> UUID {
        try await run { [self] in
            try await requireEditable(in: room, id: messageID, revision: expectedRevision)
            return try await mutations.enqueueWithdrawal(roomID: room, messageID: messageID, expectedRevision: expectedRevision)
        }
    }
    private func requireEditable(in room: RoomID, id: MessageID, revision: UInt64) async throws {
        let message = try await readableMessage(in: room, id: id)
        guard message.senderUserID == accountID, !message.isWithdrawn, message.messageRevision == revision else { throw V2MessageServiceError.invalidInput }
    }
    @discardableResult public func react(in room: RoomID, messageID: MessageID, reaction: String, targetState: V2MessageReactionTargetState) async throws -> UUID {
        try await run { [self] in
            _ = try await readableMessage(in: room, id: messageID)
            return try await reactions.enqueue(roomID: room, messageID: messageID, reaction: reaction, targetState: targetState)
        }
    }
    @discardableResult public func forward(sources: [V2ForwardMessageReference], to targets: [RoomID]) async throws -> UUID {
        try await run { [self] in
            for source in sources {
                try Task.checkCancellation()
                let value = try await readableMessage(in: source.roomID, id: source.messageID)
                guard value.messageRevision == source.revision.rawValue else { throw V2MessageServiceError.invalidInput }
            }
            for target in targets {
                try Task.checkCancellation()
                guard try await store.roomAllowsLocalRead(roomID: target) else { throw V2MessageServiceError.invalidInput }
            }
            return try await forwards.enqueue(sources: sources, targetRoomIDs: targets)
        }
    }

    public func retrySend(_ id: UUID) async throws { try await run { [sends] in try await sends.resumeConfirmation(intentID: id) } }
    public func retryMutation(_ id: UUID) async throws { try await run { [mutations] in try await mutations.resumeConfirmation(workID: id) } }
    public func retryReaction(_ id: UUID) async throws { try await run { [reactions] in try await reactions.resumeConfirmation(intentID: id) } }
    public func retryForward(_ id: UUID) async throws { try await run { [forwards] in try await forwards.resumeConfirmation(workID: id) } }
    public func cancelForward(_ id: UUID) async throws { try await run { [forwards] in try await forwards.cancelRemaining(workID: id) } }

    public func sendConfirmations(_ id: UUID) -> AsyncThrowingStream<V2OperationExecutionState?, any Error> {
        observe { [sends] in await sends.confirmationUpdates(intentID: id) }
    }
    public func mutationUpdates(in room: RoomID) -> AsyncThrowingStream<[V2MessageMutationSnapshot], any Error> {
        observe { [mutations] in await mutations.updates(roomID: room) }
    }
    public func reactionUpdates(in room: RoomID) -> AsyncThrowingStream<[V2MessageReactionPending], any Error> {
        observe { [reactions] in await reactions.updates(roomID: room) }
    }
    public func forwardUpdates(in room: RoomID) -> AsyncThrowingStream<[V2ForwardPlanSnapshot], any Error> {
        observe { [forwards] in await forwards.updates(sourceRoomID: room) }
    }
    private func observe<T: Sendable>(_ source: @escaping @Sendable () async -> AsyncThrowingStream<T, any Error>) -> AsyncThrowingStream<T, any Error> {
        let (stream, continuation) = AsyncThrowingStream<T, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard !closed else { continuation.finish(throwing: V2MessageServiceError.closed); return stream }
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
        observers[id] = (task, { continuation.finish(throwing: V2MessageServiceError.closed) })
        continuation.onTermination = { [weak self] _ in task.cancel(); Task { await self?.removeObserver(id) } }
        return stream
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id)?.task.cancel() }

    /// Hosts register these existing durable executors with their account dispatcher.
    public func handlers() -> [V2OperationWorkDispatcher.Handler] {
        [.init(kind: .sendMessage) { [self] claim in try await run { [sends] in try await sends.execute(claim) } },
         .init(kind: .editMessage) { [self] claim in try await run { [mutations] in try await mutations.execute(claim) } },
         .init(kind: .withdrawMessage) { [self] claim in try await run { [mutations] in try await mutations.execute(claim) } },
         .init(kind: .reaction) { [self] claim in try await run { [reactions] in try await reactions.execute(claim) } },
         .init(kind: .forwardMessage) { [self] claim in try await run { [forwards] in try await forwards.execute(claim) } }]
    }
    public func runReactionPreparation() async throws { try await run { [reactions] in try await reactions.runPreparation() } }

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

import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core

/// Each operation store owns its transaction and verifies the bound activation
/// token on the owner connection. This adapter never opens an outer transaction.
struct PostgresV2RoomMessagingAdapter: V2RoomMessagingPersisting {
    private let token: V2RoomActivationToken
    private let writes: PostgresV2RoomWriteStore
    private let sendOperations: PostgresV2MessageSendOperationStore?
    private let mutations: PostgresV2MessageMutationOperationStore?
    private let reactionOperations: PostgresV2MessageReactionOperationStore?
    private let capacityProfile: V2CapacityProfile
    private let identifiers: V2AcceptanceIDFactory
    private let maximumEditBytes: Int
    private let now: @Sendable () -> Date

    init(token: V2RoomActivationToken, writes: PostgresV2RoomWriteStore,
         capacityProfile: V2CapacityProfile, identifiers: V2AcceptanceIDFactory,
         maximumEditBytes: Int, now: @escaping @Sendable () -> Date,
         mutations: PostgresV2MessageMutationOperationStore?,
         sendOperations: PostgresV2MessageSendOperationStore?,
         reactionOperations: PostgresV2MessageReactionOperationStore?) throws {
        let scope = try V2RoomActivationWriteScope(tokens: [token])
        self.token = token
        self.writes = writes.usingActivationScope(scope)
        self.sendOperations = sendOperations
        self.mutations = mutations
        self.reactionOperations = reactionOperations
        self.capacityProfile = capacityProfile
        self.identifiers = identifiers
        self.maximumEditBytes = maximumEditBytes
        self.now = now
    }

    func execute(_ command: V2RoomMessagingCommand) async throws -> V2RoomMessagingResult {
        switch command {
        case .reactionOperation(let value):
            guard let reactionOperations else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
            return .reactionOperation(try await reactionOperations.change(value, token: token,
                capacityProfile: capacityProfile, eventID: .init(uuid: UUID()), now: now()))
        case .recoverReaction(let value):
            guard let reactionOperations else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
            return .reactionOperation(try await reactionOperations.recover(value, token: token, now: now()))
        case .reactionSnapshot(let value):
            guard let reactionOperations else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
            return .reactionSnapshot(try await reactionOperations.snapshot(roomID: value.roomID,
                actorUserID: value.actorUserID, messageID: value.messageID,
                reaction: value.reaction, token: token))
        case .sendOperation(let value):
            guard let sendOperations else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
            do {
                return .sendOperation(try await sendOperations.send(value, token: token,
                    capacityProfile: capacityProfile, identifiers: identifiers.make(at: now())))
            } catch {
                throw v2NormalizeMessageOperationClosed(error)
            }
        case .recoverSendOperation(let value):
            guard let sendOperations else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
            return .sendOperation(try await sendOperations.recover(value, token: token))
        case .editOperation(let value):
            guard let mutations else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
            return .mutation(try await mutations.edit(value, token: token, capacityProfile: capacityProfile,
                eventID: .init(uuid: UUID()), now: now(), maximumUTF8Bytes: maximumEditBytes))
        case .withdrawOperation(let value):
            guard let mutations else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
            return .mutation(try await mutations.withdraw(value, token: token,
                capacityProfile: capacityProfile, eventID: .init(uuid: UUID()), now: now()))
        case .recoverMutation(let value):
            guard let mutations else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
            return .mutation(try await mutations.recover(value, token: token, now: now()))
        }
    }

    func accept(_ request: V2RoomWriteRequest) async throws -> V2RoomMessagingResult {
        do {
            return .send(.init(try await writes.accept(command: request.command,
                capacityProfile: request.capacityProfile, identifiers: request.identifiers, now: request.now)))
        } catch {
            throw v2NormalizeMessageOperationClosed(error)
        }
    }
}

public extension V2RoomMessagingExecutor {
    init(token: V2RoomActivationToken, writes: PostgresV2RoomWriteStore,
         capacityProfile: V2CapacityProfile,
         limits: V2MessageCommandLimits, maximumEditBytes: Int,
         identifiers: V2AcceptanceIDFactory = .init(),
         now: @escaping @Sendable () -> Date = Date.init,
         mutations: PostgresV2MessageMutationOperationStore? = nil,
         sendOperations: PostgresV2MessageSendOperationStore? = nil,
         reactionOperations: PostgresV2MessageReactionOperationStore? = nil) throws {
        let adapter = try PostgresV2RoomMessagingAdapter(token: token, writes: writes,
            capacityProfile: capacityProfile, identifiers: identifiers,
            maximumEditBytes: maximumEditBytes, now: now, mutations: mutations,
            sendOperations: sendOperations, reactionOperations: reactionOperations)
        try self.init(token: token, persistence: adapter, capacityProfile: capacityProfile,
            limits: limits, maximumEditBytes: maximumEditBytes,
            identifiers: identifiers, now: now)
    }
}

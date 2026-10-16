import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core

/// 操作存储持有各自的提交边界。发送统一使用注入的权限准备器和房间生命周期，
/// 本适配器不打开外层事务。
struct PostgresV2RoomMessagingAdapter: V2RoomMessagingPersisting {
    private let token: V2RoomActivationToken
    private let sendOperations: PostgresV2MessageSendOperationStore?
    private let sendOperationOwnerBatcher: V2DurableSendOperationOwnerBatcher?
    private let directSendPreparation: V2RoomSendPreparation?
    private let mutations: PostgresV2MessageMutationOperationStore?
    private let reactionOperations: PostgresV2MessageReactionOperationStore?
    private let capacityProfile: V2CapacityProfile
    private let maximumEditBytes: Int
    private let now: @Sendable () -> Date

    init(token: V2RoomActivationToken,
         capacityProfile: V2CapacityProfile,
         maximumEditBytes: Int, now: @escaping @Sendable () -> Date,
         mutations: PostgresV2MessageMutationOperationStore?,
         sendOperations: PostgresV2MessageSendOperationStore?,
         reactionOperations: PostgresV2MessageReactionOperationStore?,
         sendOperationOwnerBatcher: V2DurableSendOperationOwnerBatcher?,
         directSendPreparation: V2RoomSendPreparation?) throws {
        _ = try V2RoomActivationWriteScope(tokens: [token])
        guard sendOperations == nil
            ? (directSendPreparation == nil && sendOperationOwnerBatcher == nil)
            : (directSendPreparation != nil && sendOperationOwnerBatcher != nil) else {
            throw V2ActorContractError.invalidConfiguration("message send preparation and scheduler required")
        }
        self.token = token
        self.sendOperations = sendOperations
        self.sendOperationOwnerBatcher = sendOperationOwnerBatcher
        self.directSendPreparation = directSendPreparation
        self.mutations = mutations
        self.reactionOperations = reactionOperations
        self.capacityProfile = capacityProfile
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
            let results = try await executeSendOperationBatch([value])
            guard results.count == 1, let result = results.first else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return result
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

    func executeSendOperationBatch(_ commands: [V2MessageSendOperationCommand]) async throws -> [V2RoomMessagingResult] {
        let prepared = try await prepareSendOperationBatch(commands,
            deadline: V2RoomSQLDeadline.boundedTransactionDeadline())
        return try await prepared.execute()
    }

    func prepareSendOperationBatch(_ commands: [V2MessageSendOperationCommand],
                                   deadline: ContinuousClock.Instant) async throws -> V2PreparedRoomSendOperationBatch {
        V2SendPathTrace.current?.mark("persistence_prepare_enter")
        guard let batcher = sendOperationOwnerBatcher, let prepare = directSendPreparation else {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        let startedAt = ContinuousClock.now
        let prepared = try await prepare(commands, token, deadline)
        V2SendPathTrace.current?.record("permission_preparation", from: startedAt)
        let trace = V2SendPathTrace.current
        return .init {
            try await V2SendPathTrace.$current.withValue(trace) {
                return try await batcher.execute(prepared)
            }
        }
    }
}

public extension V2RoomMessagingExecutor {
    init(token: V2RoomActivationToken,
         capacityProfile: V2CapacityProfile,
         limits: V2MessageCommandLimits, maximumEditBytes: Int,
         now: @escaping @Sendable () -> Date = Date.init,
         mutations: PostgresV2MessageMutationOperationStore? = nil,
         sendOperations: PostgresV2MessageSendOperationStore? = nil,
         sendOperationOwnerBatcher: V2DurableSendOperationOwnerBatcher? = nil,
         directSendPreparation: V2RoomSendPreparation? = nil,
         reactionOperations: PostgresV2MessageReactionOperationStore? = nil) throws {
        let adapter = try PostgresV2RoomMessagingAdapter(token: token,
            capacityProfile: capacityProfile,
            maximumEditBytes: maximumEditBytes, now: now, mutations: mutations,
            sendOperations: sendOperations, reactionOperations: reactionOperations,
            sendOperationOwnerBatcher: sendOperationOwnerBatcher,
            directSendPreparation: directSendPreparation)
        try self.init(token: token, persistence: adapter,
            limits: limits, maximumEditBytes: maximumEditBytes)
    }
}

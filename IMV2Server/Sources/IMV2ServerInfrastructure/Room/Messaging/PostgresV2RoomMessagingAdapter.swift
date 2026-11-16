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
    private let capacityProfile: V2CapacityProfile
    private let maximumEditBytes: Int
    private let now: @Sendable () -> Date

    init(token: V2RoomActivationToken,
         capacityProfile: V2CapacityProfile,
         maximumEditBytes: Int, now: @escaping @Sendable () -> Date,
         mutations: PostgresV2MessageMutationOperationStore?,
         sendOperations: PostgresV2MessageSendOperationStore?,
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
        self.capacityProfile = capacityProfile
        self.maximumEditBytes = maximumEditBytes
        self.now = now
    }

    func execute(_ command: V2RoomMessagingCommand) async throws -> V2RoomMessagingResult {
        switch command {
        case .sendOperation(let value):
            let prepared = try await prepareSendOperationBatch([value], deadline: nil)
            let results = try await prepared.execute()
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

    func prepareSendOperationBatch(_ commands: [V2MessageSendOperationCommand],
                                   deadline: ContinuousClock.Instant?) async throws -> V2PreparedRoomSendOperationBatch {
        V2SendPathTrace.current?.mark("persistence_prepare_enter")
        guard let batcher = sendOperationOwnerBatcher, let prepare = directSendPreparation else {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        let startedAt = ContinuousClock.now
        let prepared = try await prepare(commands, token, deadline ?? V2RoomSQLDeadline.boundedTransactionDeadline())
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
         directSendPreparation: V2RoomSendPreparation? = nil) throws {
        let adapter = try PostgresV2RoomMessagingAdapter(token: token,
            capacityProfile: capacityProfile,
            maximumEditBytes: maximumEditBytes, now: now, mutations: mutations,
            sendOperations: sendOperations,
            sendOperationOwnerBatcher: sendOperationOwnerBatcher,
            directSendPreparation: directSendPreparation)
        try self.init(token: token, persistence: adapter,
            limits: limits, maximumEditBytes: maximumEditBytes)
    }
}

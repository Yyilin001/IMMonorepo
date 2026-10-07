import IMV2ServerApplication
import IMV2ServerContracts
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core

/// 供来源准备、回执工作器和目标导入投递共用。
/// 调用方无需处理 ActorID、所有者地址或激活纪元。
public struct V2RoomRefForwardPort: Sendable {
    private let directory: V2RoomDirectory
    public init(directory: V2RoomDirectory) { self.directory = directory }

    public func execute(_ command: V2RoomForwardCommand,
                        deadline: ContinuousClock.Instant) async throws -> V2RoomForwardResult {
        guard !command.requiresReservation else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        let response = try await directory.room(command.roomID).call(.forward(command),
            principal: .service, deadline: deadline)
        guard case .forward(let value) = response else { throw V2RoomCallFailure.outcomeUnknown }
        if case .failure(let failure) = value { throw failure.domainError() }
        return value
    }
}

public extension V2ActorForwardPairPort {
    init(coordinator: V2RoomReservationCoordinator,
         executorsByShard: [String: V2ActorForwardPairDomainExecutor],
         expectedTarget: V2RoomActivationToken? = nil) {
        self.init { pair, deadline in
            try await coordinator.withReservations(source: pair.source.roomID,
                target: pair.targetRoomID, deadline: deadline) { grants in
                if let expectedTarget,
                   grants.first(where: { $0.token.roomID == pair.targetRoomID })?.token != expectedTarget {
                    return .rolledBack(.staleActivation)
                }
                guard let shard = grants.first?.token.owner.shardID,
                      let executor = executorsByShard[shard] else { return .rolledBack(.unavailable) }
                do {
                    return .committed(try await executor.execute(pair,
                        activationTokens: grants.map(\.token), deadline: deadline))
                } catch {
                    // 已知的房间对业务拒绝是彼此独立的结果；
                    // 无关目标仍可完成它自己的房间对操作。
                    if let code = v2ActorForwardPairBusinessFailure(error) {
                        return .committed(.init(sourceMessageID: pair.source.messageID,
                            targetRoomID: pair.targetRoomID, messageID: nil,
                            roomSequence: nil, errorCode: code))
                    }
                    return v2RoomDomainCompletion(error)
                }
            }
        }
    }
}

private func v2ActorForwardPairBusinessFailure(_ error: any Error) -> String? {
    switch error {
    case V2RoomWriteStoreError.actorNotEligible: "FORBIDDEN"
    case V2RoomWriteStoreError.roomNotFound: "NOT_FOUND"
    case V2RoomWriteStoreError.actorMuted: "ACTOR_MUTED"
    case V2RoomWriteStoreError.roomFrozen: "ROOM_FROZEN"
    case V2RoomWriteStoreError.strangerMessageLimitReached: "RATE_LIMITED"
    case V2MediaStoreError.mediaUnavailable, V2MediaStoreError.mediaExpired,
         V2MediaStoreError.invalidStateTransition: "MEDIA_UNAVAILABLE"
    default: nil
    }
}

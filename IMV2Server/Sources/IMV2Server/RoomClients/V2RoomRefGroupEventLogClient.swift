import Foundation
import IMV2Core

/// 网关通过 RoomRef 进入房间读取事件日志。可选缓存只接收提交后提示；
/// 它既不能授权，也不能直接满足这些读取。
public struct V2RoomRefGroupEventLogClient: Sendable, V2GatewayGroupEventLogHandling {
    private let service: V2GroupEventLogService

    public init(rooms: V2RoomRefQueryClient,
                directRoomLogEventCache: V2DirectRoomLogEventCache? = nil) {
        service = .init(store: RoomRefEventLogStore(rooms: rooms),
                        directRoomLogEventCache: directRoomLogEventCache)
    }

    public func pull(roomID: RoomID, actorUserID: UserID,
                     afterRoomSequence: UInt64, pageSize: Int) async throws -> V2GroupEventLogPage {
        try await service.pull(roomID: roomID, actorUserID: actorUserID,
                               afterRoomSequence: afterRoomSequence, pageSize: pageSize)
    }

    public func subscribe(roomID: RoomID, actorUserID: UserID) async throws -> V2GroupEventSubscription {
        try await service.subscribe(roomID: roomID, actorUserID: actorUserID)
    }

    public func recordRelayedForegroundEvents(_ events: [V2DirectRoomLiveEvent]) {
        service.recordRelayedForegroundEvents(events)
    }

    public func recordCommittedDirectRoomLogMessage(_ message: V2AcceptedMessage) async {
        await service.recordCommittedDirectRoomLogMessage(message)
    }

    func recordCommittedDirectRoomLogEvent(_ event: V2DirectRoomLiveEvent) async {
        await service.recordCommittedDirectRoomLogEvent(event)
    }
}

private struct RoomRefEventLogStore: V2GroupEventLogStore {
    let rooms: V2RoomRefQueryClient

    func pull(roomID: RoomID, actorUserID: UserID,
              afterRoomSequence: UInt64, pageSize: Int) async throws -> V2GroupEventLogPage {
        try await rooms.pull(roomID: roomID, actorUserID: actorUserID,
                             afterRoomSequence: afterRoomSequence, pageSize: pageSize)
    }

    func subscribe(roomID: RoomID, actorUserID: UserID) async throws -> V2GroupEventSubscription {
        try await rooms.subscribeEligibility(roomID: roomID, actorUserID: actorUserID)
    }
}

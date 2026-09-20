import Foundation
import IMV2Core

/// Wire boundary for recovery reads. Authentication and admission belong to
/// the gateway; only its authenticated user identity is accepted here.
public protocol V2RoomRecoveryCommandHandling: Sendable {
    func list(_ request: IMV2UserRoomDirectoryList, actorUserID: UserID) async throws -> IMV2Envelope
    func batch(_ request: IMV2RoomLatestVisibleBatch, actorUserID: UserID) async throws -> IMV2Envelope
    func batch(_ request: IMV2RoomSyncStateBatch, actorUserID: UserID) async throws -> IMV2Envelope
}

public struct V2RoomRecoveryCommandService: V2RoomRecoveryCommandHandling {
    private let directory: V2UserRoomDirectoryService
    private let states: any V2RoomStateReading
    private let latestVisible: V2RoomLatestVisibleCommandService

    public init(directory: V2UserRoomDirectoryService, states: any V2RoomStateReading, latestVisible: V2RoomLatestVisibleCommandService) {
        self.directory = directory
        self.states = states
        self.latestVisible = latestVisible
    }

    public func batch(_ request: IMV2RoomLatestVisibleBatch, actorUserID: UserID) async throws -> IMV2Envelope {
        try await latestVisible.batch(request, actorUserID: actorUserID)
    }

    public func list(_ request: IMV2UserRoomDirectoryList, actorUserID: UserID) async throws -> IMV2Envelope {
        let page = try await directory.list(actorUserID: actorUserID,
            cursor: request.cursor.isEmpty ? nil : request.cursor, pageSize: Int(request.pageSize))
        var response = IMV2Envelope()
        response.userRoomDirectoryPage = .init()
        response.userRoomDirectoryPage.topologyGeneration = page.topologyGeneration
        response.userRoomDirectoryPage.nextCursor = page.nextCursor ?? ""
        response.userRoomDirectoryPage.rooms = page.rooms.map { entry in
            var wire = IMV2UserRoomDirectoryEntry()
            wire.roomID = entry.roomID.rawValue
            wire.roomKind = entry.roomKind.rawValue
            wire.viewerMembershipRevision = entry.viewerMembershipRevision
            wire.ownerEpoch = entry.ownerEpoch
            return wire
        }
        return response
    }

    public func batch(_ request: IMV2RoomSyncStateBatch, actorUserID: UserID) async throws -> IMV2Envelope {
        guard actorUserID.uuidValue != nil, !request.roomIds.isEmpty, request.roomIds.count <= 100 else {
            throw V2RoomRecoveryReadError.invalidRequest
        }
        let ids = try request.roomIds.map { value -> RoomID in
            guard let uuid = UUID(uuidString: value) else { throw V2RoomRecoveryReadError.invalidRequest }
            return RoomID(uuid: uuid)
        }
        guard Set(ids).count == ids.count else { throw V2RoomRecoveryReadError.invalidRequest }
        let results = try await states.states(roomIDs: ids, actorUserID: actorUserID)
        guard Set(results.keys) == Set(ids) else { throw V2RoomRecoveryReadError.corruptPersistence }
        try Task.checkCancellation()
        var response = IMV2Envelope()
        response.roomSyncStateBatchResult = .init()
        response.roomSyncStateBatchResult.rooms = try ids.map { id in
            var result = IMV2RoomSyncStateResult()
            result.roomID = id.rawValue
            switch results[id]! {
            case .state(let state):
                guard state.roomID == id else { throw V2RoomRecoveryReadError.corruptPersistence }
                var wire = IMV2RoomSyncState()
                wire.roomID = id.rawValue
                wire.ownerEpoch = state.ownerEpoch
                wire.viewerMembershipRevision = state.viewerMembershipRevision
                wire.head = state.head
                wire.trimmedThrough = state.trimmedThrough
                wire.readThrough = state.readThrough
                wire.latestOwnMessageSequence = state.latestOwnMessageSequence
                wire.unreadCount = state.unreadCount
                result.state = wire
            case .unavailable:
                result.unavailable = .init()
            case .retry:
                result.retry = .init()
                result.retry.retryAfterSeconds = 1
            }
            return result
        }
        return response
    }
}

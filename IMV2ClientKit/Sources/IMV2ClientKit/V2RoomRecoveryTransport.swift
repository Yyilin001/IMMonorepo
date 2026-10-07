import Foundation
import IMV2Core

public struct V2ClientUserRoomEntry: Equatable, Sendable {
    public let roomID: RoomID
    public let kind: V2ClientRoomKind
    public let viewerMembershipRevision: UInt64
    public let ownerEpoch: UInt64

    public init(roomID: RoomID, kind: V2ClientRoomKind, viewerMembershipRevision: UInt64, ownerEpoch: UInt64) throws {
        guard roomID.uuidValue != nil,
              viewerMembershipRevision <= UInt64(Int64.max), ownerEpoch <= UInt64(Int64.max)
        else { throw V2RealtimeTransportError.unexpectedResponse }
        self.roomID = roomID
        self.kind = kind
        self.viewerMembershipRevision = viewerMembershipRevision
        self.ownerEpoch = ownerEpoch
    }
}

public struct V2ClientUserRoomPage: Equatable, Sendable {
    public let rooms: [V2ClientUserRoomEntry]
    public let nextCursor: String?
    public let topologyGeneration: String

    public init(rooms: [V2ClientUserRoomEntry], nextCursor: String?, topologyGeneration: String) throws {
        guard rooms.count <= 100, Set(rooms.map(\.roomID)).count == rooms.count,
              !topologyGeneration.isEmpty, topologyGeneration.utf8.count <= 128,
              nextCursor.map({ !$0.isEmpty && $0.utf8.count <= 2048 }) ?? true
        else { throw V2RealtimeTransportError.unexpectedResponse }
        self.rooms = rooms
        self.nextCursor = nextCursor
        self.topologyGeneration = topologyGeneration
    }
}

public enum V2ClientRoomStateResult: Equatable, Sendable {
    case state(V2RoomSynchronizationState)
    case unavailable
    case retry(afterSeconds: UInt32)
}

public protocol V2ClientRoomRecoveryTransport: Sendable {
    func startAccountRoomChanges() async throws -> UUID
    func userRoomDirectory(cursor: String?, pageSize: Int) async throws -> V2ClientUserRoomPage
    func roomSyncStates(roomIDs: [RoomID]) async throws -> [RoomID: V2ClientRoomStateResult]
}

public enum V2ClientRoomRecoveryError: Error, Equatable, Sendable {
    /// Persist a fresh scan with an empty cursor; retrying the old token cannot recover.
    case directoryResetRequired
}

extension V2ProtobufSyncTransport: V2ClientRoomRecoveryTransport {
    public func startAccountRoomChanges() async throws -> UUID {
        var request = IMV2Envelope()
        request.accountRoomChangesStart = .init()
        let response = try await requestEnvelope(request)
        guard case .accountRoomChangesReady(let ready)? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
        guard let epoch = UUID(uuidString: ready.connectionEpoch) else { throw V2RealtimeTransportError.unexpectedResponse }
        return epoch
    }

    public func userRoomDirectory(cursor: String?, pageSize: Int) async throws -> V2ClientUserRoomPage {
        guard pageSize > 0, pageSize <= 100,
              cursor.map({ !$0.isEmpty && $0.utf8.count <= 2048 }) ?? true
        else { throw V2RealtimeTransportError.unexpectedResponse }
        var request = IMV2Envelope()
        request.userRoomDirectoryList.pageSize = UInt32(pageSize)
        request.userRoomDirectoryList.cursor = cursor ?? ""
        let response = try await requestEnvelope(request)
        if case .error(let error)? = response.body, error.code == "ROOM_DIRECTORY_RESET_REQUIRED" {
            throw V2ClientRoomRecoveryError.directoryResetRequired
        }
        guard case .userRoomDirectoryPage(let page)? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
        guard page.rooms.count <= pageSize, page.nextCursor.isEmpty || page.nextCursor != cursor else {
            throw V2RealtimeTransportError.unexpectedResponse
        }
        let rooms = try page.rooms.map { room in
            guard let kind = V2ClientRoomKind(rawValue: room.roomKind) else { throw V2RealtimeTransportError.unexpectedResponse }
            return try V2ClientUserRoomEntry(roomID: .init(room.roomID), kind: kind,
                viewerMembershipRevision: room.viewerMembershipRevision, ownerEpoch: room.ownerEpoch)
        }
        return try .init(rooms: rooms, nextCursor: page.nextCursor.isEmpty ? nil : page.nextCursor,
                         topologyGeneration: page.topologyGeneration)
    }

    public func roomSyncStates(roomIDs: [RoomID]) async throws -> [RoomID: V2ClientRoomStateResult] {
        guard !roomIDs.isEmpty, roomIDs.count <= 100, roomIDs.allSatisfy({ $0.uuidValue != nil }) else {
            throw V2RealtimeTransportError.unexpectedResponse
        }
        let ids = Set(roomIDs)
        var request = IMV2Envelope()
        request.roomSyncStateBatch.roomIds = ids.map(\.rawValue).sorted()
        let response = try await requestEnvelope(request)
        guard case .roomSyncStateBatchResult(let batch)? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
        guard batch.rooms.count == ids.count else { throw V2RealtimeTransportError.unexpectedResponse }
        var result: [RoomID: V2ClientRoomStateResult] = [:]
        for item in batch.rooms {
            let id = try RoomID(item.roomID)
            guard ids.contains(id), result[id] == nil else { throw V2RealtimeTransportError.unexpectedResponse }
            switch item.result {
            case .state(let state):
                guard try RoomID(state.roomID) == id else { throw V2RealtimeTransportError.unexpectedResponse }
                let value = try V2RoomSynchronizationState(roomID: id, ownerEpoch: state.ownerEpoch,
                    viewerMembershipRevision: state.viewerMembershipRevision, head: state.head,
                    trimmedThrough: state.trimmedThrough, readThrough: state.readThrough,
                    latestOwnMessageSequence: state.latestOwnMessageSequence)
                guard value.unreadCount == state.unreadCount else { throw V2RealtimeTransportError.unexpectedResponse }
                result[id] = .state(value)
            case .unavailable: result[id] = .unavailable
            case .retry(let retry): result[id] = .retry(afterSeconds: retry.retryAfterSeconds)
            case nil: throw V2RealtimeTransportError.unexpectedResponse
            }
        }
        return result
    }
}

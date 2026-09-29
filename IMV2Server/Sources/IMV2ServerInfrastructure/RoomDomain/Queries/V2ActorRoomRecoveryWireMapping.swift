import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core

private func verifyRoomItems(_ actual: [RoomID], expected: [RoomID]?) throws {
    guard actual.count <= V2ActorRoomRecoveryBatchQueryWire.maximumRoomCount,
          Set(actual).count == actual.count else { throw V2ActorRoomRecoveryWireError.invalidResult }
    if let expected {
        guard actual.count == expected.count, Set(actual) == Set(expected) else {
            throw V2ActorRoomRecoveryWireError.invalidResult
        }
    }
}

public extension V2ActorRoomSynchronizationStateWire {
    init(_ value: V2RoomSynchronizationState) {
        self.init(roomID: value.roomID, ownerEpoch: value.ownerEpoch,
                  viewerMembershipRevision: value.viewerMembershipRevision, head: value.head,
                  trimmedThrough: value.trimmedThrough, readThrough: value.readThrough,
                  latestOwnMessageSequence: value.latestOwnMessageSequence)
    }
    func domainValue() throws -> V2RoomSynchronizationState {
        try .init(roomID: roomID, ownerEpoch: ownerEpoch,
                  viewerMembershipRevision: viewerMembershipRevision, head: head,
                  trimmedThrough: trimmedThrough, readThrough: readThrough,
                  latestOwnMessageSequence: latestOwnMessageSequence)
    }
}

public extension V2ActorRoomStateReadWire {
    init(_ value: V2RoomStateReadResult) {
        switch value {
        case .state(let state): self = .state(.init(state))
        case .unavailable: self = .unavailable
        case .retry: self = .retry
        }
    }
    func domainValue() throws -> V2RoomStateReadResult {
        switch self {
        case .state(let state): return .state(try state.domainValue())
        case .unavailable: return .unavailable
        case .retry: return .retry
        }
    }
}

public extension V2ActorRoomStateBatchWire {
    init(_ values: [RoomID: V2RoomStateReadResult], requestedRoomIDs: [RoomID]) throws {
        try verifyRoomItems(Array(values.keys), expected: requestedRoomIDs)
        self.init(items: try requestedRoomIDs.map { id in
            guard let result = values[id] else { throw V2ActorRoomRecoveryWireError.invalidResult }
            return .init(roomID: id, result: .init(result))
        })
    }
    func domainValue(expectedRoomIDs: [RoomID]? = nil) throws -> [RoomID: V2RoomStateReadResult] {
        try verifyRoomItems(items.map(\.roomID), expected: expectedRoomIDs)
        var values: [RoomID: V2RoomStateReadResult] = [:]
        for item in items {
            let result = try item.result.domainValue()
            if case .state(let state) = result, state.roomID != item.roomID {
                throw V2ActorRoomRecoveryWireError.invalidResult
            }
            values[item.roomID] = result
        }
        return values
    }
}

public extension V2ActorRoomLatestMessageWire {
    init(_ value: V2RoomLatestVisible.Message) {
        self.init(id: value.id, senderID: value.senderID, sequence: value.sequence,
                  revision: value.revision, preview: value.preview, mediaCount: value.mediaCount,
                  createdAt: value.createdAt)
    }
    func domainValue() throws -> V2RoomLatestVisible.Message {
        try .init(id: id, senderID: senderID, sequence: sequence, revision: revision,
                  preview: preview, mediaCount: mediaCount, createdAt: createdAt)
    }
}

public extension V2ActorRoomLatestVisibleWire {
    init(_ value: V2RoomLatestVisible) {
        self.init(roomID: value.roomID, ownerEpoch: value.ownerEpoch,
                  membershipRevision: value.membershipRevision, head: value.head,
                  latest: value.latest.map(V2ActorRoomLatestMessageWire.init))
    }
    func domainValue() throws -> V2RoomLatestVisible {
        try .init(roomID: roomID, ownerEpoch: ownerEpoch,
                  membershipRevision: membershipRevision, head: head,
                  latest: try latest?.domainValue())
    }
}

public extension V2ActorRoomLatestVisibleReadWire {
    init(_ value: V2RoomLatestVisibleResult) {
        switch value {
        case .snapshot(let snapshot): self = .snapshot(.init(snapshot))
        case .unavailable: self = .unavailable
        case .retry: self = .retry
        }
    }
    func domainValue() throws -> V2RoomLatestVisibleResult {
        switch self {
        case .snapshot(let snapshot): return .snapshot(try snapshot.domainValue())
        case .unavailable: return .unavailable
        case .retry: return .retry
        }
    }
}

public extension V2ActorRoomLatestVisibleBatchWire {
    init(_ values: [RoomID: V2RoomLatestVisibleResult], requestedRoomIDs: [RoomID]) throws {
        try verifyRoomItems(Array(values.keys), expected: requestedRoomIDs)
        self.init(items: try requestedRoomIDs.map { id in
            guard let result = values[id] else { throw V2ActorRoomRecoveryWireError.invalidResult }
            return .init(roomID: id, result: .init(result))
        })
    }
    func domainValue(expectedRoomIDs: [RoomID]? = nil) throws -> [RoomID: V2RoomLatestVisibleResult] {
        try verifyRoomItems(items.map(\.roomID), expected: expectedRoomIDs)
        var values: [RoomID: V2RoomLatestVisibleResult] = [:]
        for item in items {
            let result = try item.result.domainValue()
            if case .snapshot(let snapshot) = result, snapshot.roomID != item.roomID {
                throw V2ActorRoomRecoveryWireError.invalidResult
            }
            values[item.roomID] = result
        }
        return values
    }
}

public extension V2ActorRoomRecoveryReadErrorWire {
    init(_ value: V2RoomRecoveryReadError) {
        switch value {
        case .invalidRequest: self = .invalidRequest
        case .corruptPersistence: self = .corruptPersistence
        case .invalidCursor: self = .invalidCursor
        case .topologyChanged: self = .topologyChanged
        }
    }
    func domainValue() -> V2RoomRecoveryReadError {
        switch self {
        case .invalidRequest: .invalidRequest
        case .corruptPersistence: .corruptPersistence
        case .invalidCursor: .invalidCursor
        case .topologyChanged: .topologyChanged
        }
    }
}

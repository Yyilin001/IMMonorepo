import Foundation
import IMV2ActorContracts

func validateJournalProjectionBatch(_ batch: V2RealtimeJournalProjectionBatch,
                                    limits: V2RealtimeTransportLimits) throws {
    guard !batch.source.sourceID.isEmpty, (0..<256).contains(batch.source.partitionID),
          batch.fence.sourceLeaseEpoch > 0, batch.fence.routingPartitionEpoch > 0,
          batch.fence.interestGeneration > 0 else { throw V2ActorAuthenticationError.invalidRequest }
    func validateRoom(_ raw: String, ownerEpoch: UInt64, controlVersion: UInt64, head: UInt64) throws {
        guard UUID(uuidString: raw) != nil, ownerEpoch <= UInt64(Int64.max),
              controlVersion <= UInt64(Int64.max), head <= UInt64(Int64.max) else {
            throw V2ActorAuthenticationError.invalidRequest
        }
    }
    func validateAuthorization(_ room: V2RealtimeJournalRoomAuthorization) throws {
        try validateRoom(room.roomID.rawValue, ownerEpoch: room.ownerEpoch,
                         controlVersion: room.controlVersion, head: room.highWatermark)
        guard room.permissionVersion == room.controlVersion,
              room.viewerMembershipRevisions.allSatisfy({ UUID(uuidString: $0.key.rawValue) != nil && $0.value > 0 && $0.value <= UInt64(Int64.max) }) else {
            throw V2ActorAuthenticationError.invalidRequest
        }
    }
    switch batch.payload {
    case .baseline(let minimumCut):
        guard minimumCut >= 0 else { throw V2ActorAuthenticationError.invalidRequest }
    case .heads(let heads):
        guard heads.count <= limits.maximumBatchItems,
              Set(heads.map(\.roomID)).count == heads.count else { throw V2ActorAuthenticationError.invalidRequest }
        for head in heads {
            try validateRoom(head.roomID.rawValue, ownerEpoch: head.ownerEpoch,
                             controlVersion: head.controlVersion, head: head.highWatermark)
        }
    case .snapshot(let cut, let rooms):
        guard cut >= 0, rooms.count <= limits.maximumBatchItems,
              Set(rooms.map(\.roomID)).count == rooms.count else { throw V2ActorAuthenticationError.invalidRequest }
        for room in rooms { try validateAuthorization(room) }
    case .changes(let from, let through, let entries):
        guard from >= 0, through >= from, entries.count <= limits.maximumBatchItems else {
            throw V2ActorAuthenticationError.invalidRequest
        }
        var previous = from
        for entry in entries {
            guard entry.sequence > previous, entry.sequence <= through else { throw V2ActorAuthenticationError.invalidRequest }
            previous = entry.sequence
            switch entry.change {
            case .authorization(let room):
                guard room.controlVersion > 0 else { throw V2ActorAuthenticationError.invalidRequest }
                try validateAuthorization(room)
            case .head(let roomID, let head, let epoch, let permission):
                try validateRoom(roomID.rawValue, ownerEpoch: epoch, controlVersion: permission, head: head)
            case .controlInvalidation(let roomID, let epoch, let control):
                guard control > 0 else { throw V2ActorAuthenticationError.invalidRequest }
                try validateRoom(roomID.rawValue, ownerEpoch: epoch, controlVersion: control, head: 0)
            case .userControlInvalidation(let userID, let version, _, let membershipRoom):
                guard membershipRoom == nil || membershipRoom?.uuidValue != nil else { throw V2ActorAuthenticationError.invalidRequest }
                guard UUID(uuidString: userID.rawValue) != nil, version > 0, version <= UInt64(Int64.max) else {
                    throw V2ActorAuthenticationError.invalidRequest
                }
            case .invalidate(let roomID):
                guard UUID(uuidString: roomID.rawValue) != nil else { throw V2ActorAuthenticationError.invalidRequest }
            }
        }
    }
}

/// Head merge receipts carry no ordered journal checkpoint. Cross-kind receipts
/// cannot turn a dirty head or source revision into control progress.
func validateJournalProjectionReceipt(_ result: V2RealtimeJournalProjectionResult,
                                      batch: V2RealtimeJournalProjectionBatch) throws {
    switch (batch.payload, result) {
    case (.heads, .headsApplied(let applied)):
        guard applied.batchID == batch.batchID, applied.source == batch.source, applied.fence == batch.fence else {
            throw V2ActorAuthenticationError.wrongRecipient
        }
    case (.changes(_, let through, _), .applied(let applied)):
        guard applied.batchID == batch.batchID, applied.source == batch.source, applied.fence == batch.fence,
              applied.appliedThrough == through, !applied.snapshotInstalled else {
            throw V2ActorAuthenticationError.wrongRecipient
        }
    case (.snapshot(let cut, _), .applied(let applied)):
        guard applied.batchID == batch.batchID, applied.source == batch.source, applied.fence == batch.fence,
              applied.appliedThrough == cut, applied.snapshotInstalled else {
            throw V2ActorAuthenticationError.wrongRecipient
        }
    case (.baseline(let minimumCut), .applied(let applied)):
        guard applied.batchID == batch.batchID, applied.source == batch.source, applied.fence == batch.fence,
              applied.appliedThrough >= minimumCut, applied.snapshotInstalled else {
            throw V2ActorAuthenticationError.wrongRecipient
        }
    case (.heads, .applied), (.changes, .headsApplied), (.snapshot, .headsApplied), (.baseline, .headsApplied):
        throw V2ActorAuthenticationError.wrongRecipient
    case (_, .stale), (_, .snapshotRequired), (_, .overloaded), (_, .invalid):
        break
    }
}

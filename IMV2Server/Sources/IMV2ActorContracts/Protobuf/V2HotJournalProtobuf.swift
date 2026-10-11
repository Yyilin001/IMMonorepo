import Foundation
import IMV2Core

extension Im_Actor_V1_HotJournalSource {
    package init(_ value: V2RealtimeJournalSource) { self.init(); sourceID = value.sourceID; incarnationID = V2HotPB.bytes(value.incarnationID); partitionID = Int64(value.partitionID) }
    package func model() throws -> V2RealtimeJournalSource { try V2HotPB.check(self); return try .init(sourceID: sourceID, incarnationID: V2HotPB.uuid(incarnationID), partitionID: Int(partitionID)) }
}
extension Im_Actor_V1_HotJournalFence {
    package init(_ value: V2RealtimeJournalProjectionFence) {
        self.init(); publisherIncarnation = V2HotPB.bytes(value.publisherIncarnationID); sourceEpoch = value.sourceLeaseEpoch
        sourceToken = V2HotPB.bytes(value.sourceLeaseToken); sourceExpires = value.sourceLeaseExpiresAt.timeIntervalSinceReferenceDate
        routingEpoch = value.routingPartitionEpoch; routingToken = V2HotPB.bytes(value.routingLeaseToken); sessionID = V2HotPB.bytes(value.sessionID)
        interestGeneration = value.interestGeneration; gatewayIncarnation = V2HotPB.bytes(value.gatewayIncarnationID)
    }
    package func model() throws -> V2RealtimeJournalProjectionFence {
        try V2HotPB.check(self, sourceExpires.isFinite)
        return try .init(publisherIncarnationID: V2HotPB.uuid(publisherIncarnation), sourceLeaseEpoch: sourceEpoch, sourceLeaseToken: V2HotPB.uuid(sourceToken),
            sourceLeaseExpiresAt: .init(timeIntervalSinceReferenceDate: sourceExpires), routingPartitionEpoch: routingEpoch, routingLeaseToken: V2HotPB.uuid(routingToken),
            sessionID: V2HotPB.uuid(sessionID), interestGeneration: interestGeneration, gatewayIncarnationID: V2HotPB.uuid(gatewayIncarnation))
    }
}
extension Im_Actor_V1_HotJournalAuthorization {
    package init(_ value: V2RealtimeJournalRoomAuthorization) {
        self.init(); roomID = value.roomID.rawValue; ownerEpoch = value.ownerEpoch; permissionVersion = value.permissionVersion
        controlVersion = value.controlVersion; watermark = value.highWatermark
        viewers = value.viewerMembershipRevisions.sorted { $0.key.rawValue < $1.key.rawValue }.map { .init(.init(userID: $0.key, memberRevision: $0.value)) }
    }
    package func model() throws -> V2RealtimeJournalRoomAuthorization {
        try V2HotPB.check(self)
        var members: [UserID: UInt64] = [:]; members.reserveCapacity(viewers.count)
        for value in viewers { let member = try value.model(); guard members.updateValue(member.memberRevision, forKey: member.userID) == nil else { throw V2HotPB.Invalid.value } }
        return try .init(roomID: .init(roomID), ownerEpoch: ownerEpoch, permissionVersion: permissionVersion, controlVersion: controlVersion, viewerMembershipRevisions: members, highWatermark: watermark)
    }
}
extension Im_Actor_V1_HotJournalHead {
    package init(_ value: V2RealtimeJournalRoomHead) { self.init(); roomID = value.roomID.rawValue; watermark = value.highWatermark; ownerEpoch = value.ownerEpoch; controlVersion = value.controlVersion }
    package func model() throws -> V2RealtimeJournalRoomHead { try V2HotPB.check(self); return try .init(roomID: .init(roomID), highWatermark: watermark, ownerEpoch: ownerEpoch, controlVersion: controlVersion) }
}
extension Im_Actor_V1_HotJournalChange {
    package init(_ value: V2RealtimeJournalProjectionChange) {
        self.init()
        switch value {
        case .authorization(let value): kind = 1; authorization = .init(value)
        case .head(let room, let watermark, let owner, let permission): kind = 2; subjectID = room.rawValue; self.watermark = watermark; ownerEpoch = owner; permissionVersion = permission
        case .invalidate(let room): kind = 3; subjectID = room.rawValue
        case .controlInvalidation(let room, let owner, let control): kind = 4; subjectID = room.rawValue; ownerEpoch = owner; controlVersion = control
        case .userControlInvalidation(let user, let control, let device, let room):
            kind = 5; subjectID = user.rawValue; controlVersion = control
            if let device { deviceID = V2HotPB.bytes(device) }; if let room { membershipRoomID = room.rawValue }
        }
    }
    package func model() throws -> V2RealtimeJournalProjectionChange {
        try V2HotPB.check(self)
        switch kind {
        case 1: try V2HotPB.check(self, hasAuthorization && subjectID.isEmpty && watermark == 0 && ownerEpoch == 0 && permissionVersion == 0 && controlVersion == 0 && !hasDeviceID && !hasMembershipRoomID); return .authorization(try authorization.model())
        case 2: try V2HotPB.check(self, !hasAuthorization && controlVersion == 0 && !hasDeviceID && !hasMembershipRoomID); return .head(roomID: try .init(subjectID), highWatermark: watermark, ownerEpoch: ownerEpoch, permissionVersion: permissionVersion)
        case 3: try V2HotPB.check(self, !hasAuthorization && watermark == 0 && ownerEpoch == 0 && permissionVersion == 0 && controlVersion == 0 && !hasDeviceID && !hasMembershipRoomID); return .invalidate(roomID: try .init(subjectID))
        case 4: try V2HotPB.check(self, !hasAuthorization && watermark == 0 && permissionVersion == 0 && !hasDeviceID && !hasMembershipRoomID); return .controlInvalidation(roomID: try .init(subjectID), ownerEpoch: ownerEpoch, controlVersion: controlVersion)
        case 5: try V2HotPB.check(self, !hasAuthorization && watermark == 0 && ownerEpoch == 0 && permissionVersion == 0); return .userControlInvalidation(userID: try .init(subjectID), controlVersion: controlVersion, deviceID: hasDeviceID ? try V2HotPB.uuid(deviceID) : nil, membershipRoomID: hasMembershipRoomID ? try .init(membershipRoomID) : nil)
        default: throw V2HotPB.Invalid.value
        }
    }
}
extension Im_Actor_V1_HotJournalBatch {
    package init(_ value: V2RealtimeJournalProjectionBatch) {
        self.init(); batchID = V2HotPB.bytes(value.batchID); source = .init(value.source); fence = .init(value.fence)
        switch value.payload {
        case .baseline(let cut): baseline = cut
        case .changes(let from, let through, let entries):
            var v = Im_Actor_V1_HotJournalChanges(); v.fromExclusive = from; v.throughInclusive = through
            v.entries = entries.map { item in var e = Im_Actor_V1_HotJournalEntry(); e.sequence = item.sequence; e.change = .init(item.change); return e }; changes = v
        case .snapshot(let cut, let rooms): var v = Im_Actor_V1_HotJournalSnapshot(); v.cut = cut; v.rooms = rooms.map { .init($0) }; snapshot = v
        case .heads(let heads): var v = Im_Actor_V1_HotJournalHeads(); v.heads = heads.map { .init($0) }; self.heads = v
        }
    }
    package func model() throws -> V2RealtimeJournalProjectionBatch {
        try V2HotPB.check(self, hasSource && hasFence)
        let payload: V2RealtimeJournalProjectionPayload
        switch self.payload {
        case .baseline(let cut): payload = .baseline(minimumCut: cut)
        case .changes(let value):
            try V2HotPB.check(value)
            payload = .changes(fromExclusive: value.fromExclusive, throughInclusive: value.throughInclusive, entries: try value.entries.map { v in try V2HotPB.check(v, v.hasChange); return .init(sequence: v.sequence, change: try v.change.model()) })
        case .snapshot(let value): try V2HotPB.check(value); payload = .snapshot(cut: value.cut, rooms: try value.rooms.map { try $0.model() })
        case .heads(let value): try V2HotPB.check(value); payload = .heads(try value.heads.map { try $0.model() })
        default: throw V2HotPB.Invalid.value
        }
        return try .init(batchID: V2HotPB.uuid(batchID), source: source.model(), fence: fence.model(), payload: payload)
    }
}
extension Im_Actor_V1_HotJournalResult {
    package init(_ value: V2RealtimeJournalProjectionResult) {
        self.init()
        switch value {
        case .applied(let value):
            var v = Im_Actor_V1_HotJournalApplied(); v.batchID = V2HotPB.bytes(value.batchID); v.source = .init(value.source); v.fence = .init(value.fence)
            v.appliedThrough = value.appliedThrough; v.snapshotInstalled = value.snapshotInstalled; applied = v
        case .headsApplied(let value): var v = Im_Actor_V1_HotJournalApplied(); v.batchID = V2HotPB.bytes(value.batchID); v.source = .init(value.source); v.fence = .init(value.fence); headsApplied = v
        case .stale: stale = .init()
        case .snapshotRequired: snapshotRequired = .init()
        case .overloaded: overloaded = .init()
        case .invalid: invalid = .init()
        }
    }
    package func model() throws -> V2RealtimeJournalProjectionResult {
        try V2HotPB.check(self)
        switch result {
        case .applied(let value): try V2HotPB.check(value, value.hasSource && value.hasFence); return .applied(try .init(batchID: V2HotPB.uuid(value.batchID), source: value.source.model(), fence: value.fence.model(), appliedThrough: value.appliedThrough, snapshotInstalled: value.snapshotInstalled))
        case .headsApplied(let value): try V2HotPB.check(value, value.hasSource && value.hasFence && value.appliedThrough == 0 && !value.snapshotInstalled); return .headsApplied(try .init(batchID: V2HotPB.uuid(value.batchID), source: value.source.model(), fence: value.fence.model()))
        case .stale(let value): try V2HotPB.check(value); return .stale
        case .snapshotRequired(let value): try V2HotPB.check(value); return .snapshotRequired
        case .overloaded(let value): try V2HotPB.check(value); return .overloaded
        case .invalid(let value): try V2HotPB.check(value); return .invalid
        default: throw V2HotPB.Invalid.value
        }
    }
}

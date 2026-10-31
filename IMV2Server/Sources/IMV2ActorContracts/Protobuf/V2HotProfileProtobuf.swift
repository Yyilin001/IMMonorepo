import Foundation
import IMV2Core

extension Im_Actor_V1_HotProfileRead {
    package init(_ value: V2ActorProfileVisibilityBatchWire) {
        self.init(); roomID = value.roomID.rawValue; actorID = value.actorUserID.rawValue
        roomKind = value.roomKind.rawValue; targetIds = value.targetUserIDs.map(\.rawValue)
    }
    package func model() throws -> V2ActorProfileVisibilityBatchWire {
        try V2HotPB.check(self, (1...100).contains(targetIds.count))
        guard let kind = V2ActorProfileVisibilityBatchWire.RoomKind(rawValue: roomKind) else { throw V2HotPB.Invalid.value }
        let value = try V2ActorProfileVisibilityBatchWire(roomID: .init(roomID), actorUserID: .init(actorID),
            roomKind: kind, targetUserIDs: targetIds.map { try .init($0) })
        guard value.validatedTargetCount != nil else { throw V2HotPB.Invalid.value }
        return value
    }
}
extension Im_Actor_V1_HotProfileCohort {
    package init(_ value: V2ActorProfileVisibilityCohortWire) {
        self.init(); roomID = value.roomID.rawValue; requests = value.requests.map { .init($0) }
    }
    package func model() throws -> V2ActorProfileVisibilityCohortWire {
        try V2HotPB.check(self, (1...100).contains(requests.count)
            && requests.allSatisfy({ (1...100).contains($0.targetIds.count) })
            && requests.reduce(0, { $0 + $1.targetIds.count }) <= 100)
        let value = try V2ActorProfileVisibilityCohortWire(roomID: .init(roomID), requests: requests.map { try $0.model() })
        guard value.validatedTargetCount != nil else { throw V2HotPB.Invalid.value }
        return value
    }
}
extension Im_Actor_V1_HotGroupMember {
    package init(_ value: V2ActorGroupMemberPresentationWire) {
        self.init(); roomID = value.roomID.rawValue; userID = value.userID.rawValue; revision = value.revision.rawValue
        if let name = value.groupNickname { nickname = name }
    }
    package func model() throws -> V2ActorGroupMemberPresentationWire {
        try V2HotPB.check(self)
        guard let version = V2ProfileRevision(rawValue: revision) else { throw V2HotPB.Invalid.value }
        let name = hasNickname ? nickname : nil
        let value = try V2GroupMemberPresentation(roomID: .init(roomID), userID: .init(userID), groupNickname: name, revision: version)
        guard value.roomID.uuidValue != nil, value.userID.uuidValue != nil, value.groupNickname == name else { throw V2HotPB.Invalid.value }
        return .init(roomID: value.roomID, userID: value.userID, groupNickname: name, revision: version)
    }
}
extension Im_Actor_V1_HotProfileSnapshot {
    package init(_ value: V2ActorProfileVisibilityBatchSnapshotWire) {
        self.init(); request = .init(value.request); activation = .init(value.activation)
        membershipRevision = value.membershipRevision; permissionRevision = value.permissionRevision
        visibleTargetIds = value.visibleTargetUserIDs.map(\.rawValue); groupMembers = value.groupMembers.map { .init($0) }
        observedAtReferenceSeconds = value.observedAt.timeIntervalSinceReferenceDate
        expiresAtReferenceSeconds = value.activationExpiresAt.timeIntervalSinceReferenceDate
    }
    package func model() throws -> V2ActorProfileVisibilityBatchSnapshotWire {
        try V2HotPB.check(self, hasRequest && hasActivation && membershipRevision >= 0 && permissionRevision >= 0
            && visibleTargetIds.count <= 100 && groupMembers.count <= visibleTargetIds.count
            && hasObservedAtReferenceSeconds && hasExpiresAtReferenceSeconds
            && observedAtReferenceSeconds.isFinite && expiresAtReferenceSeconds.isFinite
            && expiresAtReferenceSeconds > observedAtReferenceSeconds)
        let query = try request.model(), token = try activation.model()
        let visible: [UserID] = try visibleTargetIds.map { try .init($0) }, members = try groupMembers.map { try $0.model() }
        guard token.roomID == query.roomID, Set(visible).count == visible.count,
              Set(visible).isSubset(of: Set(query.targetUserIDs)),
              Set(members.map(\.userID)).count == members.count,
              members.allSatisfy({ ($0.roomID == query.roomID && visible.contains($0.userID))
                  && (query.roomKind == .group || query.roomKind == .memberRoom) }) else { throw V2HotPB.Invalid.value }
        return .init(request: query, activation: token, membershipRevision: membershipRevision, visibleTargetUserIDs: visible,
            observedAt: Date(timeIntervalSinceReferenceDate: observedAtReferenceSeconds),
            activationExpiresAt: Date(timeIntervalSinceReferenceDate: expiresAtReferenceSeconds),
            groupMembers: members, permissionRevision: permissionRevision)
    }
}
extension Im_Actor_V1_HotProfileSnapshots {
    package init(_ values: [V2ActorProfileVisibilityBatchSnapshotWire]) { self.init(); snapshots = values.map { .init($0) } }
    package func model() throws -> [V2ActorProfileVisibilityBatchSnapshotWire] {
        try V2HotPB.check(self, (1...100).contains(snapshots.count)
            && snapshots.allSatisfy({ (1...100).contains($0.request.targetIds.count) })
            && snapshots.reduce(0, { $0 + $1.request.targetIds.count }) <= 100)
        let values = try snapshots.map { try $0.model() }
        guard let first = values.first,
              V2ActorProfileVisibilityCohortWire(roomID: first.request.roomID, requests: values.map(\.request)).validatedTargetCount != nil,
              values.allSatisfy({ $0.activation == first.activation && $0.membershipRevision == first.membershipRevision
                  && $0.permissionRevision == first.permissionRevision && $0.observedAt == first.observedAt
                  && $0.activationExpiresAt == first.activationExpiresAt }) else { throw V2HotPB.Invalid.value }
        return values
    }
}

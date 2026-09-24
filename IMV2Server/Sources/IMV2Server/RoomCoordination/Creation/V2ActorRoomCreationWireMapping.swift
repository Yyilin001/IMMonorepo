import Foundation
import IMV2ActorContracts
import IMV2Core

extension V2ActorOpenDirectRoomWire {
    public func toDomain() throws -> V2OpenDirectRoomCommand {
        try .init(actorUserID: actorUserID, operationID: operationID, targetUserID: targetUserID)
    }
}
extension V2ActorCreateGroupRoomWire {
    /// Capacity class is derived by the coordinator's policy; it is not caller authority.
    public func toDomain(capacityClass: V2GroupCapacityClass) throws -> V2CreateGroupRoomCommand {
        try .init(actorUserID: actorUserID, operationID: operationID, title: title,
                  capacityClass: capacityClass, initialMemberUserIDs: initialMemberUserIDs)
    }
}
extension V2ActorStagedGroupBeginWire {
    public func validatedTitle() throws -> String {
        try V2GroupAudienceImport(actorUserID: actorUserID, operationID: operationID,
                                  title: title, memberUserIDs: []).title
    }
}
extension V2ActorStagedGroupAppendWire {
    public func validatedMemberUserIDs() throws -> [UserID] {
        guard (1...V2GroupAudienceImport.maximumMembersPerAppend).contains(memberUserIDs.count) else {
            throw V2GroupAudienceImportError.invalidInput
        }
        return try V2GroupAudienceImport(actorUserID: actorUserID, operationID: operationID,
                                         title: "validated", memberUserIDs: memberUserIDs).memberUserIDs
    }
}
extension V2ActorDirectRoomWire {
    public init(domain: V2DirectRoom) {
        self.init(roomID: domain.roomID, actorUserID: domain.actorUserID,
                  targetUserID: domain.targetUserID, createdAt: domain.createdAt)
    }
    public func toDomain() throws -> V2DirectRoom {
        guard actorUserID != targetUserID, createdAt.timeIntervalSince1970.isFinite else {
            throw V2DirectMessagingValidationError.selfTargetingNotAllowed
        }
        return .init(roomID: roomID, actorUserID: actorUserID, targetUserID: targetUserID, createdAt: createdAt)
    }
}
extension V2ActorGroupRoomWire {
    public init(domain: V2GroupRoom) {
        self.init(roomID: domain.roomID, ownerUserID: domain.ownerUserID, title: domain.title,
                  capacityClass: domain.capacityClass, memberCount: domain.memberCount,
                  memberUserIDs: domain.memberUserIDs, createdAt: domain.createdAt)
    }
    public func toDomain() throws -> V2GroupRoom {
        guard createdAt.timeIntervalSince1970.isFinite else { throw V2GroupMessagingValidationError.invalidMemberCount }
        return try .init(roomID: roomID, ownerUserID: ownerUserID, title: title,
                         capacityClass: capacityClass, memberUserIDs: memberUserIDs,
                         memberCount: memberCount, createdAt: createdAt)
    }
}
extension V2ActorStagedGroupDraftWire {
    public init(domain: V2GroupAudienceDraft) {
        self.init(operationID: domain.operationID, title: domain.title, stagedMemberCount: domain.stagedMemberCount)
    }
    public func toDomain() throws -> V2GroupAudienceDraft {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= V2CreateGroupRoomCommand.maximumTitleUTF8Bytes,
              !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              stagedMemberCount >= 0 else { throw V2GroupAudienceImportError.invalidInput }
        return .init(operationID: operationID, title: normalized, stagedMemberCount: stagedMemberCount)
    }
}
extension V2ActorOpenDirectRoomOutcomeWire {
    public init(domain: V2OpenDirectRoomOutcome) {
        switch domain {
        case .opened(let v): self = .opened(.init(domain: v))
        case .idempotent(let v): self = .idempotent(.init(domain: v))
        case .idempotencyConflict: self = .idempotencyConflict
        case .unavailable: self = .unavailable
        }
    }
    public func toDomain() throws -> V2OpenDirectRoomOutcome {
        switch self {
        case .opened(let v): .opened(try v.toDomain())
        case .idempotent(let v): .idempotent(try v.toDomain())
        case .idempotencyConflict: .idempotencyConflict
        case .unavailable: .unavailable
        }
    }
}
extension V2ActorCreateGroupRoomOutcomeWire {
    public init(domain: V2CreateGroupRoomOutcome) {
        switch domain {
        case .created(let v): self = .created(.init(domain: v))
        case .idempotent(let v): self = .idempotent(.init(domain: v))
        case .idempotencyConflict: self = .idempotencyConflict
        case .invalidMembers: self = .invalidMembers
        case .memberLimitReached: self = .memberLimitReached
        case .rateLimited(let seconds): self = .rateLimited(retryAfterSeconds: seconds)
        case .unavailable: self = .unavailable
        }
    }
    public func toDomain() throws -> V2CreateGroupRoomOutcome {
        switch self {
        case .created(let v): .created(try v.toDomain())
        case .idempotent(let v): .idempotent(try v.toDomain())
        case .idempotencyConflict: .idempotencyConflict
        case .invalidMembers: .invalidMembers
        case .memberLimitReached: .memberLimitReached
        case .rateLimited(let seconds): .rateLimited(retryAfterSeconds: seconds)
        case .unavailable: .unavailable
        }
    }
}
extension V2ActorGroupCreationIntentWire {
    public init(domain: V2GroupRoomCreationIntent) {
        self.init(actorUserID: domain.actorUserID, operationID: domain.operationID, roomID: domain.roomID,
                  eventID: domain.eventID, roomShardID: domain.roomShardID, routeEpoch: domain.routeEpoch,
                  requestFingerprint: domain.requestFingerprint, audienceMemberCount: domain.audienceMemberCount,
                  state: domain.state == .prepared ? .prepared : .committed)
    }
    public func toDomain() throws -> V2GroupRoomCreationIntent {
        guard roomShardID == roomShardID.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw V2GroupRoomCreationIntentStoreError.invalidIntent
        }
        return try .init(actorUserID: actorUserID, operationID: operationID, roomID: roomID, eventID: eventID,
                  roomShardID: roomShardID, routeEpoch: routeEpoch, requestFingerprint: requestFingerprint,
                  audienceMemberCount: audienceMemberCount,
                  state: state == .prepared ? .prepared : .committed)
    }
}
extension V2ActorPrepareGroupCreationIntentResultWire {
    public init(domain: V2PrepareGroupRoomCreationIntentOutcome) {
        switch domain {
        case .prepared(let v): self = .prepared(.init(domain: v))
        case .idempotent(let v): self = .idempotent(.init(domain: v))
        case .idempotencyConflict: self = .idempotencyConflict
        case .invalidMembers: self = .invalidMembers
        }
    }
    public func toDomain() throws -> V2PrepareGroupRoomCreationIntentOutcome {
        switch self {
        case .prepared(let v): .prepared(try v.toDomain())
        case .idempotent(let v): .idempotent(try v.toDomain())
        case .idempotencyConflict: .idempotencyConflict
        case .invalidMembers: .invalidMembers
        }
    }
}
extension V2ActorGroupCreationManifestPageWire {
    public init(domain: V2GroupRoomCreationManifestPage) {
        self.init(pageNumber: domain.pageNumber, memberUserIDs: domain.memberUserIDs,
                  isFinal: domain.isFinal, digest: domain.digest)
    }
    public func toDomain() throws -> V2GroupRoomCreationManifestPage {
        let page = try V2GroupRoomCreationManifestPage(pageNumber: pageNumber, memberUserIDs: memberUserIDs, isFinal: isFinal)
        guard page.memberUserIDs == memberUserIDs, page.digest == digest else {
            throw V2GroupRoomCreationIntentStoreError.invalidIntent
        }
        return page
    }
}
extension V2ActorGroupCreationManifestSliceWire {
    public init(domain: V2GroupRoomCreationManifestSlice) {
        self.init(memberUserIDs: domain.memberUserIDs, hasMore: domain.hasMore)
    }
    public func toDomain() throws -> V2GroupRoomCreationManifestSlice {
        guard memberUserIDs.count <= V2GroupRoomCreationManifestPage.maximumMemberCount,
              Set(memberUserIDs).count == memberUserIDs.count else {
            throw V2GroupRoomCreationIntentStoreError.invalidIntent
        }
        return .init(memberUserIDs: memberUserIDs, hasMore: hasMore)
    }
}

extension V2ActorDirectBootstrapWire {
    public func validatedCommand() throws -> V2OpenDirectRoomCommand {
        guard !roomShardID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              roomShardID == roomShardID.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw V2GroupMessagingPolicyError.invalidRoomShard
        }
        return try command.toDomain()
    }
}
extension V2ActorGroupBootstrapWire {
    public func validatedCommand() throws -> V2CreateGroupRoomCommand {
        let candidate = try V2CreateGroupRoomCommand(actorUserID: actorUserID, operationID: operationID,
                                                      title: title, capacityClass: capacityClass,
                                                      initialMemberUserIDs: initialMemberUserIDs)
        let intent = try intent.toDomain()
        guard intent.actorUserID == actorUserID, intent.operationID == operationID,
              intent.audienceMemberCount == validatedMemberUserIDs.count,
              validatedMemberUserIDs == validatedMemberUserIDs.sorted(),
              Set(validatedMemberUserIDs).count == validatedMemberUserIDs.count,
              validatedMemberUserIDs.contains(actorUserID),
              Set(validatedMemberUserIDs) == Set(candidate.allMemberUserIDs),
              candidate.title == title else {
            throw V2GroupRoomCreationIntentStoreError.invalidIntent
        }
        return candidate
    }
}
extension V2ActorStagedGroupBootstrapWire {
    public func validatedCommand() throws -> V2StagedGroupRoomCommand {
        let command = try V2StagedGroupRoomCommand(actorUserID: actorUserID, operationID: operationID,
                                                    title: title, capacityClass: capacityClass,
                                                    stagedMemberCount: stagedMemberCount)
        let intent = try intent.toDomain()
        guard intent.actorUserID == actorUserID, intent.operationID == operationID,
              intent.audienceMemberCount == stagedMemberCount + 1 else {
            throw V2GroupRoomCreationIntentStoreError.invalidIntent
        }
        return command
    }
}

extension V2ActorGroupAudienceImportWire {
    public init(domain: V2GroupAudienceImport) {
        self.init(actorUserID: domain.actorUserID, operationID: domain.operationID, title: domain.title,
                  memberUserIDs: domain.memberUserIDs, stagedMemberCount: domain.stagedMemberCount,
                  hasMaterializedMembers: domain.hasMaterializedMembers)
    }
    public func toDomain() throws -> V2GroupAudienceImport {
        let value: V2GroupAudienceImport
        if hasMaterializedMembers {
            guard stagedMemberCount == memberUserIDs.count,
                  memberUserIDs == memberUserIDs.sorted() else { throw V2GroupAudienceImportError.invalidInput }
            value = try .init(actorUserID: actorUserID, operationID: operationID,
                              title: title, memberUserIDs: memberUserIDs)
        } else {
            guard memberUserIDs.isEmpty else { throw V2GroupAudienceImportError.invalidInput }
            value = try .init(actorUserID: actorUserID, operationID: operationID,
                              title: title, stagedMemberCount: stagedMemberCount)
        }
        guard value.title == title else { throw V2GroupAudienceImportError.invalidInput }
        return value
    }
}

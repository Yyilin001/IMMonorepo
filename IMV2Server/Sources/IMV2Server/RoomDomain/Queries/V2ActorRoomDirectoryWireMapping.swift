import Foundation
import IMV2ActorContracts
import IMV2Core

private func validateDirectoryPage(_ count: Int, ids: [UserID], cursor: String?) throws {
    guard count <= V2RoomMembershipDirectoryRequest.maximumPageSize,
          Set(ids).count == count,
          cursor.map({ !$0.isEmpty && $0.utf8.count <= V2RoomMembershipDirectoryRequest.maximumCursorBytes }) ?? true
    else { throw V2ActorRoomDirectoryWireError.invalidPage }
}

public extension V2ActorPublicIdentityWire {
    init(_ value: V2PublicIdentity) {
        self.init(userID: value.userID, handle: value.handle.rawValue,
                  displayName: value.displayName, accountKind: value.accountKind)
    }

    func domainValue() throws -> V2PublicIdentity {
        let validatedHandle = try V2PublicHandle(handle)
        guard validatedHandle.rawValue.utf8.elementsEqual(handle.utf8) else {
            throw V2ActorRoomDirectoryWireError.invalidIdentity
        }
        let identity = try V2PublicIdentity(userID: userID, handle: validatedHandle,
                                            displayName: displayName, accountKind: accountKind)
        guard identity.displayName.utf8.elementsEqual(displayName.utf8) else {
            throw V2ActorRoomDirectoryWireError.invalidIdentity
        }
        return identity
    }
}

public extension V2ActorMembershipDirectoryQueryWire {
    init(_ value: V2RoomMembershipDirectoryRequest) throws {
        try self.init(roomID: value.roomID, actorUserID: value.actorUserID,
                      cursor: value.cursor, pageSize: value.pageSize)
    }
    func domainValue() throws -> V2RoomMembershipDirectoryRequest {
        try .init(roomID: roomID, actorUserID: actorUserID,
                  cursor: cursor, pageSize: pageSize)
    }
}

public extension V2ActorMembershipDirectoryEntryWire {
    init(_ value: V2RoomMembershipDirectoryEntry) {
        self.init(userID: value.userID, role: value.role,
                  publicIdentity: .init(value.publicIdentity))
    }
    func domainValue() throws -> V2RoomMembershipDirectoryEntry {
        let identity = try publicIdentity.domainValue()
        guard identity.userID == userID else { throw V2ActorRoomDirectoryWireError.invalidIdentity }
        return .init(userID: userID, role: role, publicIdentity: identity)
    }
}

public extension V2ActorMembershipDirectoryPageWire {
    init(_ value: V2RoomMembershipDirectoryPage) {
        self.init(roomID: value.roomID, membershipRevision: value.membershipRevision,
                  actorRole: value.actorRole,
                  entries: value.entries.map(V2ActorMembershipDirectoryEntryWire.init),
                  nextCursor: value.nextCursor)
    }
    func domainValue() throws -> V2RoomMembershipDirectoryPage {
        guard membershipRevision <= UInt64(Int64.max) else {
            throw V2RoomMembershipDirectoryError.corruptPersistenceState
        }
        try validateDirectoryPage(entries.count, ids: entries.map(\.userID), cursor: nextCursor)
        return .init(roomID: roomID, membershipRevision: membershipRevision,
                     actorRole: actorRole, entries: try entries.map { try $0.domainValue() },
                     nextCursor: nextCursor)
    }
}

public extension V2ActorRoleBaselineWire {
    init(_ value: V2GroupRolePolicyBaseline) {
        self.init(roomID: value.roomID, permissionRevision: value.permissionRevision,
                  membershipRevision: value.membershipRevision, roomSequence: value.roomSequence,
                  adminPermissions: value.adminPermissions.sorted { $0.rawValue < $1.rawValue },
                  memberPermissions: value.memberPermissions.sorted { $0.rawValue < $1.rawValue })
    }
    func domainValue() throws -> V2GroupRolePolicyBaseline {
        guard Set(adminPermissions).count == adminPermissions.count,
              Set(memberPermissions).count == memberPermissions.count else {
            throw V2ActorRoomDirectoryWireError.invalidPage
        }
        return try .init(roomID: roomID, permissionRevision: permissionRevision,
                         membershipRevision: membershipRevision, roomSequence: roomSequence,
                         adminPermissions: Set(adminPermissions), memberPermissions: Set(memberPermissions))
    }
}

public extension V2ActorRoomKindWire {
    init(_ value: V2RoomKind) {
        switch value {
        case .group: self = .group
        case .direct: self = .direct
        }
    }
    func domainValue() -> V2RoomKind {
        switch self {
        case .group: .group
        case .direct: .direct
        }
    }
}

public extension V2ActorUserRoomDirectoryEntryWire {
    init(_ value: V2UserRoomDirectoryEntry) {
        self.init(roomID: value.roomID, roomKind: .init(value.roomKind),
                  viewerMembershipRevision: value.viewerMembershipRevision,
                  ownerEpoch: value.ownerEpoch)
    }
    func domainValue() throws -> V2UserRoomDirectoryEntry {
        try .init(roomID: roomID, roomKind: roomKind.domainValue(),
                  viewerMembershipRevision: viewerMembershipRevision, ownerEpoch: ownerEpoch)
    }
}

private func validateUserDirectory(_ entries: [V2ActorUserRoomDirectoryEntryWire]) throws {
    guard entries.count <= 100, Set(entries.map(\.roomID)).count == entries.count else {
        throw V2ActorRoomDirectoryWireError.invalidPage
    }
}

public extension V2ActorUserRoomDirectoryPageWire {
    init(_ value: V2UserRoomDirectoryPage) {
        self.init(rooms: value.rooms.map(V2ActorUserRoomDirectoryEntryWire.init),
                  nextCursor: value.nextCursor, topologyGeneration: value.topologyGeneration)
    }
    func domainValue() throws -> V2UserRoomDirectoryPage {
        try validateUserDirectory(rooms)
        guard !topologyGeneration.isEmpty, topologyGeneration.utf8.count <= 128,
              nextCursor.map({ !$0.isEmpty && $0.utf8.count <= V2UserRoomDirectoryCursorCodec.maximumBytes }) ?? true else {
            throw V2ActorRoomDirectoryWireError.invalidPage
        }
        return .init(rooms: try rooms.map { try $0.domainValue() },
                     nextCursor: nextCursor, topologyGeneration: topologyGeneration)
    }
}

public extension V2ActorUserRoomDirectorySliceWire {
    init(_ value: V2UserRoomDirectorySlice) {
        self.init(entries: value.entries.map(V2ActorUserRoomDirectoryEntryWire.init),
                  scannedThrough: value.scannedThrough, hasMore: value.hasMore)
    }
    func domainValue() throws -> V2UserRoomDirectorySlice {
        try validateUserDirectory(entries)
        guard !hasMore || scannedThrough != nil else {
            throw V2ActorRoomDirectoryWireError.invalidPage
        }
        return .init(entries: try entries.map { try $0.domainValue() },
                     scannedThrough: scannedThrough, hasMore: hasMore)
    }
}

public extension V2ActorMembershipDirectoryErrorWire {
    init(_ value: V2RoomMembershipDirectoryError) {
        switch value {
        case .invalidRequest: self = .invalidRequest
        case .roomNotFound: self = .roomNotFound
        case .actorNotMember: self = .actorNotMember
        case .invalidCursor: self = .invalidCursor
        case .revisionConflict(let current): self = .revisionConflict(currentRevision: current)
        case .ownerChanged: self = .ownerChanged
        case .corruptPersistenceState: self = .corruptPersistenceState
        }
    }
    func domainValue() -> V2RoomMembershipDirectoryError {
        switch self {
        case .invalidRequest: .invalidRequest
        case .roomNotFound: .roomNotFound
        case .actorNotMember: .actorNotMember
        case .invalidCursor: .invalidCursor
        case .revisionConflict(let current): .revisionConflict(currentRevision: current)
        case .ownerChanged: .ownerChanged
        case .corruptPersistenceState: .corruptPersistenceState
        }
    }
}

public extension V2ActorRoleBaselineErrorWire {
    init(_ value: V2GroupRolePolicyBaselineError) {
        switch value {
        case .roomNotFound: self = .roomNotFound
        case .actorNotMember: self = .actorNotMember
        case .corruptPersistenceState: self = .corruptPersistenceState
        }
    }
    func domainValue() -> V2GroupRolePolicyBaselineError {
        switch self {
        case .roomNotFound: .roomNotFound
        case .actorNotMember: .actorNotMember
        case .corruptPersistenceState: .corruptPersistenceState
        }
    }
}

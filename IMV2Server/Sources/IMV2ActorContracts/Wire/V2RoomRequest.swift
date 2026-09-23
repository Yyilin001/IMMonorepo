import IMV2Core

/// A collection query obtains one independent read turn per item. The host
/// batcher only combines items whose turns have already been granted.
public struct V2ActorRoomRecoveryItemQuery: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case state, latestVisible }
    public let roomID: RoomID
    public let actorUserID: UserID
    public let kind: Kind

    public init(roomID: RoomID, actorUserID: UserID, kind: Kind) {
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.kind = kind
    }
}

public enum V2ActorRoomRecoveryItemResult: Codable, Equatable, Sendable {
    case state(V2ActorRoomStateReadWire)
    case latestVisible(V2ActorRoomLatestVisibleReadWire)
    case failure(V2ActorRoomRecoveryReadErrorWire)
}

/// Closed capability set. Adding another domain requires an explicit protocol
/// version decision and executor case; unknown cases cannot fall through to a
/// successful empty response. Coordinators and user directories are separate.
public enum V2RoomRequest: Codable, Equatable, Sendable {
    case messaging(V2RoomMessagingCommand)
    case administration(V2RoomAdministrationCommand)
    case administrationQuery(V2RoomAdministrationQuery)
    case receipt(V2RoomReceiptCommand)
    case receiptQuery(V2RoomReceiptQuery)
    case roomLog(V2RoomLogQuery)
    case directory(V2RoomDirectoryQuery)
    case recovery(V2ActorRoomRecoveryItemQuery)
    case specialAccountAudit(V2ActorSpecialAccountAuditWire)

    public var roomID: RoomID {
        switch self {
        case .messaging(let value): value.roomID
        case .administration(let value): value.roomID
        case .administrationQuery(let value): value.roomID
        case .receipt(let value): value.roomID
        case .receiptQuery(let value): value.roomID
        case .roomLog(let value): value.roomID
        case .directory(let value): value.roomID
        case .recovery(let value): value.roomID
        case .specialAccountAudit(let value): value.roomID
        }
    }

    /// A service-authorized command has no user assertion. The inbound adapter
    /// checks its specific trusted capability instead of inventing a user.
    public var actorUserID: UserID? {
        switch self {
        case .messaging(let value): value.actorUserID
        case .administration(let value): value.actorUserID
        case .administrationQuery(let value): value.actorUserID
        case .receipt(let value): value.actorUserID
        case .receiptQuery(let value): value.actorUserID
        case .roomLog(let value): value.actorUserID
        case .directory(let value): value.actorUserID
        case .recovery(let value): value.actorUserID
        case .specialAccountAudit: nil
        }
    }

    public var replayPolicy: V2RoomReplayPolicy {
        switch self {
        case .messaging, .administration, .receipt, .specialAccountAudit: .durableIdempotent
        case .administrationQuery, .receiptQuery, .roomLog, .directory, .recovery: .readOnly
        }
    }

    public var hasStableOperationID: Bool {
        switch self {
        case .messaging, .administration, .receipt, .specialAccountAudit: true
        case .administrationQuery, .receiptQuery, .roomLog, .directory, .recovery: false
        }
    }

    public var canShareSendTurn: Bool {
        if case .messaging(.send) = self { return true }
        return false
    }
}

public enum V2RoomResponse: Codable, Equatable, Sendable {
    case messaging(V2RoomMessagingResult)
    case administration(V2RoomAdministrationResult)
    case receipt(V2RoomReceiptResult)
    case roomLog(V2RoomLogQueryResult)
    case directory(V2RoomDirectoryResult)
    case recovery(V2ActorRoomRecoveryItemResult)
    case specialAccountAudit(V2ActorSpecialAccountAuditResultWire)
}

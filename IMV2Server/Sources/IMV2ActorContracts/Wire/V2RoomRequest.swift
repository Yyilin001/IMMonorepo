import IMV2Core

/// 集合查询为每个项目分别取得读取轮次。
/// 宿主批处理器只合并轮次已获准的项目。
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

/// 封闭的能力集合。新增领域须明确决定协议版本并增加执行器分支；
/// 未知分支不能落入成功的空响应。协调器和用户目录另行处理。
public enum V2RoomRequest: Codable, Equatable, Sendable {
    case messaging(V2RoomMessagingCommand)
    case administration(V2RoomAdministrationCommand)
    case administrationQuery(V2RoomAdministrationQuery)
    case receipt(V2RoomReceiptCommand)
    case receiptQuery(V2RoomReceiptQuery)
    case roomLog(V2RoomLogQuery)
    case directory(V2RoomDirectoryQuery)
    case recovery(V2ActorRoomRecoveryItemQuery)
    case invitationQuery(V2RoomInvitationQuery)
    case specialAccountAudit(V2ActorSpecialAccountAuditWire)
    case maintenance(V2RoomMaintenanceCommand)
    case forward(V2RoomForwardCommand)
    case mediaAuthorization(V2RoomMediaAuthorizationQuery)

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
        case .invitationQuery(let value): value.roomID
        case .specialAccountAudit(let value): value.roomID
        case .maintenance(let value): value.roomID
        case .forward(let value): value.roomID
        case .mediaAuthorization(let value): value.roomID
        }
    }

    /// 服务授权的命令不含用户声明。入站适配器检查其特定可信能力，
    /// 不虚构用户身份。
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
        case .invitationQuery(let value): value.actorUserID
        case .specialAccountAudit, .maintenance: nil
        case .forward(let value): value.actorUserID
        case .mediaAuthorization(let value): value.actorUserID
        }
    }

    public var replayPolicy: V2RoomReplayPolicy {
        switch self {
        case .messaging, .administration, .receipt, .specialAccountAudit: .durableIdempotent
        case .administrationQuery, .receiptQuery, .roomLog, .directory, .recovery: .readOnly
        case .invitationQuery, .mediaAuthorization: .readOnly
        case .forward: .durableIdempotent
        case .maintenance: .noAutomaticRetry
        }
    }

    public var hasStableOperationID: Bool {
        switch self {
        case .messaging, .administration, .receipt, .specialAccountAudit: true
        case .administrationQuery, .receiptQuery, .roomLog, .directory, .recovery: false
        case .invitationQuery, .maintenance, .mediaAuthorization: false
        case .forward: true
        }
    }

    public var canShareSendTurn: Bool {
        // Bound operations retain their own receipt transaction and execute scalar turns.
        return false
    }

    /// 仅描述可合并的输入形状，不授予成员或资料读取权限。
    /// 每个信封仍声明自己的 actor，由入站认证逐项验证。
    public var profileVisibilityTargetCount: Int? {
        guard case .mediaAuthorization(.profileVisibilityBatch(let request)) = self,
              request.roomID.uuidValue != nil, request.actorUserID.uuidValue != nil,
              (1...100).contains(request.targetUserIDs.count) else { return nil }
        let targets = request.targetUserIDs.compactMap(\.uuidValue)
        guard targets.count == request.targetUserIDs.count,
              Set(targets).count == targets.count else { return nil }
        return targets.count
    }
}

public enum V2RoomResponse: Codable, Equatable, Sendable {
    case messaging(V2RoomMessagingResult)
    case administration(V2RoomAdministrationResult)
    case receipt(V2RoomReceiptResult)
    case roomLog(V2RoomLogQueryResult)
    case directory(V2RoomDirectoryResult)
    case recovery(V2ActorRoomRecoveryItemResult)
    case invitation(V2RoomInvitationResult)
    case specialAccountAudit(V2ActorSpecialAccountAuditResultWire)
    case maintenance(V2RoomMaintenanceResult)
    case forward(V2RoomForwardResult)
    case mediaAuthorization(V2RoomMediaAuthorizationResult)
}

import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core

/// 由已认证的服务通道构造，而非由解码后的房间命令构造。
public struct V2ActorTrustedSafetyAuthority: Sendable {
    let safetyActorUserID: UserID
    init(safetyActorUserID: UserID) { self.safetyActorUserID = safetyActorUserID }
}

/// 具体的 D2 房间领域执行器。调用方选定物理所有者数据库；
/// 每个存储事务在重放或修改前，都重新检查此精确获准令牌。
public struct V2RoomAdministrationDomainExecutor: Sendable {
    private let database: any Database
    private let token: V2RoomActivationToken
    private let capacityProfile: V2CapacityProfile
    private let membershipIdentities: any V2MembershipIdentitySnapshotValidating
    private let membership: PostgresV2RoomMembershipStore
    private let capabilities: PostgresV2GroupCapabilitiesStore
    private let moderation: PostgresV2ModerationStore
    private let presentation: PostgresV2ProfilePresentationStore
    private let makeEventID: @Sendable () throws -> EventID
    private let now: @Sendable () -> Date

    public init(
        database: any Database,
        token: V2RoomActivationToken,
        capacityProfile: V2CapacityProfile,
        membershipIdentities: any V2MembershipIdentitySnapshotValidating,
        makeEventID: @escaping @Sendable () throws -> EventID = { try EventID(UUID().uuidString) },
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        let scope = try V2RoomActivationWriteScope(tokens: [token])
        self.database = database
        self.token = token
        self.capacityProfile = capacityProfile
        self.membershipIdentities = membershipIdentities
        self.membership = .init(database: database, activationScope: scope)
        self.capabilities = .init(database: database, activationScope: scope)
        self.moderation = .init(database: database, activationScope: scope)
        self.presentation = .init(database: database, activationScope: scope,
            nicknameCapacityProfile: capacityProfile, makeEventID: makeEventID, now: now)
        self.makeEventID = makeEventID
        self.now = now
    }

    private func requireRoom(_ roomID: RoomID) throws {
        guard token.roomID == roomID else { throw V2RoomActivationLeaseError.activationChanged }
    }

    /// 用户通道绝不接受可信安全服务分支，即使它来自有效信封。
    public func executeUser(_ command: V2RoomAdministrationCommand) async throws -> V2RoomAdministrationResult {
        try requireRoom(command.roomID)
        switch command {
        case .groupAvatarRecovery(let request):
            return .groupAvatarRecovery(try await capabilities.recoverAvatar(actorUserID: request.actorUserID, request: request.request))
        case .groupAvatar(let request):
            return .groupAvatar(.init(try await capabilities.setAvatar(actorUserID: request.actorUserID,
                command: request.command, capacityProfile: capacityProfile, eventID: makeEventID(), now: now())))
        case .membership(let request):
            let domain = try request.domainCommand()
            let snapshot = try await membershipIdentities.snapshot(
                actorUserID: request.actorUserID, targetUserID: request.targetUserID
            )
            let route = try V2RoomShardRoute(shardID: token.owner.shardID, epoch: token.owner.epoch)
            let outcome = try await membership.changeControlValidated(
                command: domain, ownerRoute: route, identitySnapshot: snapshot,
                capacityProfile: capacityProfile, eventID: makeEventID(), now: now()
            )
            return .membership(.init(outcome))
        case .pinned(let request):
            let outcome = try await capabilities.setPinnedMessage(
                actorUserID: request.actorUserID, command: request.domainCommand(),
                capacityProfile: capacityProfile, eventID: makeEventID(), now: now()
            )
            return .pinned(.init(outcome))
        case .announcement(let request):
            let outcome = try await capabilities.setAnnouncement(
                actorUserID: request.actorUserID, command: request.domainCommand(),
                capacityProfile: capacityProfile, eventID: makeEventID(), now: now()
            )
            return .announcement(.init(outcome))
        case .rolePermissions(let request):
            let outcome = try await capabilities.setRolePermissions(
                actorUserID: request.actorUserID, command: request.domainCommand(),
                capacityProfile: capacityProfile, eventID: makeEventID(), now: now()
            )
            return .rolePermissions(.init(outcome))
        case .memberRole(let request):
            let outcome = try await capabilities.changeMemberRole(
                actorUserID: request.actorUserID, command: request.domainCommand(),
                capacityProfile: capacityProfile, eventID: makeEventID(), now: now()
            )
            return .memberRole(.init(outcome))
        case .moderation(let request):
            let outcome = try await moderation.apply(
                command: request.domainCommand(), capacityProfile: capacityProfile,
                eventID: makeEventID(), now: now()
            )
            return .moderation(.init(outcome))
        case .trustedSafety:
            throw V2ActorAdministrationWireError.trustedActionOnUserLane
        case .groupNickname(let request):
            try request.validateForDomain()
            let value = try await presentation.updateOwnGroupNickname(
                actorUserID: request.actorUserID, roomID: request.roomID,
                operationID: request.operationID, expectedRevision: request.expectedRevision,
                nickname: request.nickname
            )
            return .groupNickname(.init(value))
        }
    }

    /// Cluster 的服务角色检查必须独立于线路数据提供此权限。
    public func executeTrustedSafety(
        _ request: V2ActorTrustedSafetyWire,
        authority: V2ActorTrustedSafetyAuthority
    ) async throws -> V2RoomAdministrationResult {
        try requireRoom(request.roomID)
        let trusted = try request.trustedModeration()
        let domain = try V2ModerationCommand(
            roomID: trusted.roomID, actorUserID: authority.safetyActorUserID,
            operationID: trusted.operationID, action: trusted.action,
            messageID: trusted.messageID,
            expectedMessageRevision: trusted.expectedMessageRevision,
            reasonCode: trusted.reasonCode
        )
        let outcome = try await moderation.applyTrustedSafety(
            command: domain, capacityProfile: capacityProfile,
            eventID: makeEventID(), now: now()
        )
        return .trustedSafety(.init(outcome))
    }

    public func execute(_ query: V2RoomAdministrationQuery) async throws -> V2RoomAdministrationResult {
        try requireRoom(query.roomID)
        return try await V2ActorRoomQueryExecutor(database: database)
            .withFencedRead(roomIDs: [query.roomID], tokens: [token]) { transaction in
                switch query {
                case .groupNicknames(let request):
                    try request.validateForDomain()
                    let page = try await PostgresV2ProfilePresentationStore(database: transaction, now: now)
                        .groupNicknames(actorUserID: request.actorUserID, roomID: request.roomID,
                            afterUserID: request.afterUserID, limit: request.limit)
                    return .groupNicknames(.init(page))
                }
        }
    }
}

import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core

/// Constructed by the authenticated service lane, not by a decoded room command.
public struct V2ActorTrustedSafetyAuthority: Sendable {
    let safetyActorUserID: UserID
    init(safetyActorUserID: UserID) { self.safetyActorUserID = safetyActorUserID }
}

/// Concrete D2 room-domain executor. The caller selects the physical owner database;
/// every store transaction rechecks this exact granted token before replay or mutation.
public struct V2RoomAdministrationDomainExecutor: Sendable {
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
        self.token = token
        self.capacityProfile = capacityProfile
        self.membershipIdentities = membershipIdentities
        self.membership = .init(database: database, activationScope: scope)
        self.capabilities = .init(database: database, activationScope: scope)
        self.moderation = .init(database: database, activationScope: scope)
        self.presentation = .init(database: database, activationScope: scope, now: now)
        self.makeEventID = makeEventID
        self.now = now
    }

    private func requireRoom(_ roomID: RoomID) throws {
        guard token.roomID == roomID else { throw V2RoomActivationLeaseError.activationChanged }
    }

    /// The user lane never accepts a trusted-safety variant, even if decoded from a valid envelope.
    public func executeUser(_ command: V2RoomAdministrationCommand) async throws -> V2RoomAdministrationResult {
        try requireRoom(command.roomID)
        switch command {
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

    /// The cluster's service-role gate must provide this authority independently of the wire.
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
        switch query {
        case .groupNicknames(let request):
            try request.validateForDomain()
            let page = try await presentation.groupNicknames(
                actorUserID: request.actorUserID, roomID: request.roomID,
                afterUserID: request.afterUserID, limit: request.limit
            )
            return .groupNicknames(.init(page))
        }
    }
}

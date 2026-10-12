import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core

/// Owner-bound PostgreSQL adapter. Each operation store checks the precise
/// activation token in its transaction before replay or mutation.
struct PostgresV2RoomAdministrationAdapter: Sendable {
    private let invitationSecretIssuer: V2GroupInviteSecretIssuer
    private let invitationIdentities: any V2GroupInvitationIdentityReading
    private let database: any Database
    private let token: V2RoomActivationToken
    private let capacityProfile: V2CapacityProfile
    private let capabilities: PostgresV2GroupCapabilitiesStore
    private let moderation: PostgresV2ModerationStore
    private let personalPreferences: PostgresV2ConversationCapabilitiesStore
    private let presentation: PostgresV2ProfilePresentationStore
    private let makeEventID: @Sendable () throws -> EventID
    private let now: @Sendable () -> Date

    init(
        database: any Database,
        invitationSecretIssuer: V2GroupInviteSecretIssuer,
        invitationIdentities: any V2GroupInvitationIdentityReading,
        token: V2RoomActivationToken,
        capacityProfile: V2CapacityProfile,
        makeEventID: @escaping @Sendable () throws -> EventID = { try EventID(UUID().uuidString) },
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        let scope = try V2RoomActivationWriteScope(tokens: [token])
        self.personalPreferences = .init(database:database,activationScope:scope)
        self.invitationSecretIssuer = invitationSecretIssuer
        self.invitationIdentities = invitationIdentities
        self.database = database
        self.token = token
        self.capacityProfile = capacityProfile
        self.capabilities = .init(database: database, activationScope: scope)
        self.moderation = .init(database: database, activationScope: scope)
        self.presentation = .init(database: database, activationScope: scope,
            nicknameCapacityProfile: capacityProfile, makeEventID: makeEventID, now: now)
        self.makeEventID = makeEventID
        self.now = now
    }

    private func invitationStore(_ intent: V2GroupInvitationOperationIntent) throws -> PostgresV2GroupInvitationOperationStore {
        let invite: GroupInviteID?
        switch intent.action { case .submit(let id,_,_), .revoke(let id,_): invite = id; default: invite = nil }
        return try .init(database:database,activationToken:token,identities:invitationIdentities,issuer:invitationSecretIssuer,policy:.standard,capacity:capacityProfile,inviteID:invite)
    }

    private func requireRoom(_ roomID: RoomID) throws {
        guard token.roomID == roomID else { throw V2RoomActorStateError.activationChanged }
    }

    /// 用户通道绝不接受可信安全服务分支，即使它来自有效信封。
    public func executeUser(_ command: V2RoomAdministrationCommand) async throws -> V2RoomAdministrationResult {
        try requireRoom(command.roomID)
        switch command {
        case .groupInvitationAdmit(let request):
            return .groupInvitationAdmission(try await invitationStore(request).admit(request,now:now()))
        case .groupInvitationSubmit(let request):
            return .groupInvitationRecovery(try await invitationStore(request.command.intent).submit(request,now:now()))
        case .groupInvitationRecover(let request):
            return .groupInvitationRecovery(try await invitationStore(request.intent).recover(request,now:now()))
        case .groupCapabilityAdmit(let intent):
            return .groupCapabilityAdmission(try await PostgresV2GroupCapabilityOperationStore(database:database,clock:now).admit(intent,token:token))
        case .groupCapabilitySubmit(let command):
            return .groupCapabilityRecovery(try await PostgresV2GroupCapabilityOperationStore(database:database,clock:now).submit(command,token:token,capacityProfile:capacityProfile,eventID:makeEventID()))
        case .groupCapabilityRecover(let request):
            return .groupCapabilityRecovery(try await PostgresV2GroupCapabilityOperationStore(database:database,clock:now).recover(request,token:token))
        case .membershipAdmission, .membershipSubmit, .membershipRecovery:
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        case .messageModerationAdmission(let intent):
            return .messageModerationAdmission(try await PostgresV2MessageModerationOperationStore(database:database,clock:now).admit(intent,token:token))
        case .messageModerationSubmit(let command):
            return .messageModerationRecovery(try await PostgresV2MessageModerationOperationStore(database:database,clock:now).submit(command,token:token,capacityProfile:capacityProfile,eventID:makeEventID()))
        case .messageModerationRecovery(let request):
            return .messageModerationRecovery(try await PostgresV2MessageModerationOperationStore(database:database,clock:now).recover(request,token:token))
        case .memberAdministrationAdmission(let intent):
            return .memberAdministrationAdmission(try await PostgresV2MemberAdministrationStore(database:database,clock:now).admit(intent,token:token))
        case .memberAdministrationSubmit(let command):
            return .memberAdministrationRecovery(try await PostgresV2MemberAdministrationStore(database:database,clock:now).submit(command,token:token,capacityProfile:capacityProfile,eventID:makeEventID()))
        case .memberAdministrationRecovery(let request):
            return .memberAdministrationRecovery(try await PostgresV2MemberAdministrationStore(database:database,clock:now).recover(request,token:token))
        case .conversationState(let request):
            do { return .personalPreference(try await personalPreferences.setConversationState(actorUserID:request.actorUserID,command:request.command,now:now())) }
            catch V2ConversationCapabilitiesStoreError.operationPayloadMismatch { return .personalPreferenceFingerprintConflict }
        case .messageFavorite(let request):
            do { return .personalPreference(try await personalPreferences.setMessageFavorite(actorUserID:request.actorUserID,command:request.command,now:now())) }
            catch V2ConversationCapabilitiesStoreError.operationPayloadMismatch { return .personalPreferenceFingerprintConflict }
        case .personalPreferenceRecovery(let request):
            return .personalPreferenceRecovery(try await personalPreferences.recover(actorUserID:request.actorUserID,request:request.request,now:now()))
        case .groupAvatarRecovery(let request):
            return .groupAvatarRecovery(try await capabilities.recoverAvatar(actorUserID: request.actorUserID, request: request.request))
        case .groupAvatar(let request):
            return .groupAvatar(.init(try await capabilities.setAvatar(actorUserID: request.actorUserID,
                command: request.command, capacityProfile: capacityProfile, eventID: makeEventID(), now: now())))
        case .trustedSafety:
            throw V2ActorAdministrationWireError.trustedActionOnUserLane
        case .groupNickname(let request):
            return .groupNickname(try await presentation.updateOwnGroupNickname(request.command))
        case .groupNicknameRecovery(let request):
            return .groupNicknameRecovery(try await presentation.recoverGroupNickname(request))
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
        if case .messageModerationBaseline(let request)=query {
            return .messageModerationBaseline(try await PostgresV2MessageModerationOperationStore(database:database,clock:now).baseline(request,token:token))
        }
        if case .groupInvitationBaseline(let request) = query {
            let store = try PostgresV2GroupInvitationOperationStore(database:database,activationToken:token,identities:invitationIdentities,issuer:invitationSecretIssuer,policy:.standard,capacity:capacityProfile)
            return .groupInvitationBaseline(try await store.baseline(roomID:request.roomID,actorUserID:request.actorUserID))
        }
        if case .pinnedBaseline(let request)=query {
            return .pinnedBaseline(try await PostgresV2GroupCapabilityOperationStore(database:database,clock:now).pinnedBaseline(request,token:token))
        }
        return try await V2ActorRoomQueryExecutor(database: database)
            .withFencedRead(roomIDs: [query.roomID], tokens: [token]) { transaction in
                switch query {
                case .messageModerationBaseline,.pinnedBaseline,.groupInvitationBaseline: throw V2RoomCallFailure.outcomeUnknown
                case .ownGroupNickname(let request):
                    return .ownGroupNickname(try await PostgresV2ProfilePresentationStore(database:transaction).ownGroupNicknameSnapshot(actorUserID:request.actorUserID,roomID:request.roomID))
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

extension PostgresV2RoomAdministrationAdapter: V2RoomAdministrationStoring {}

extension PostgresV2RoomAdministrationAdapter: V2RoomMembershipOperationPersisting {
    func admitMembership(_ intent: V2MembershipIntent,
                         snapshot: V2MembershipIdentitySnapshot) async throws -> V2MembershipAdmissionResult {
        try await PostgresV2MembershipOperationStore(database: database, clock: now)
            .admit(intent, identitySnapshot: snapshot, token: token)
    }

    func submitMembership(_ command: V2MembershipOperationCommand,
                          snapshot: V2MembershipIdentitySnapshot) async throws -> V2MembershipRecoveryResult {
        try await PostgresV2MembershipOperationStore(database: database, clock: now)
            .submit(command, token: token, capacityProfile: capacityProfile,
                    eventID: makeEventID(), identitySnapshot: snapshot)
    }

    func recoverMembership(_ request: V2MembershipRecoveryRequest) async throws -> V2MembershipRecoveryResult {
        try await PostgresV2MembershipOperationStore(database: database, clock: now)
            .recover(request, token: token)
    }
}

public extension V2RoomAdministrationDomainExecutor {
    init(database: any Database,
         invitationSecretIssuer: V2GroupInviteSecretIssuer,
         invitationIdentities: any V2GroupInvitationIdentityReading,
         token: V2RoomActivationToken,
         capacityProfile: V2CapacityProfile,
         membershipIdentities: any V2MembershipIdentitySnapshotValidating,
         makeEventID: @escaping @Sendable () throws -> EventID = { try EventID(UUID().uuidString) },
         now: @escaping @Sendable () -> Date = Date.init) throws {
        let adapter = try PostgresV2RoomAdministrationAdapter(
            database: database, invitationSecretIssuer: invitationSecretIssuer,
            invitationIdentities: invitationIdentities, token: token,
            capacityProfile: capacityProfile, makeEventID: makeEventID, now: now)
        self.init(token: token, store: adapter, membership: adapter,
                  membershipIdentities: membershipIdentities)
    }
}

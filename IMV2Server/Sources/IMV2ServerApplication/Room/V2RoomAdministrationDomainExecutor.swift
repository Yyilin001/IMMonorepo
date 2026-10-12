import IMV2ServerContracts
import IMV2ActorContracts
import IMV2Core

public struct V2RoomAdministrationDomainExecutor: Sendable {
    private let token: V2RoomActivationToken
    private let store: any V2RoomAdministrationStoring
    private let membership: any V2RoomMembershipOperationPersisting
    private let membershipIdentities: any V2MembershipIdentitySnapshotValidating

    package init(token: V2RoomActivationToken, store: any V2RoomAdministrationStoring,
         membership: any V2RoomMembershipOperationPersisting,
         membershipIdentities: any V2MembershipIdentitySnapshotValidating) {
        self.token = token
        self.store = store
        self.membership = membership
        self.membershipIdentities = membershipIdentities
    }

    public func executeUser(_ command: V2RoomAdministrationCommand) async throws -> V2RoomAdministrationResult {
        try requireRoom(command.roomID)
        if case .trustedSafety = command {
            throw V2ActorAdministrationWireError.trustedActionOnUserLane
        }
        switch command {
        case .membershipAdmission(let intent):
            let snapshot = try await membershipIdentities.snapshot(actorUserID: intent.actorUserID,
                targetUserID: intent.targetUserID)
            return .membershipAdmission(try await membership.admitMembership(intent, snapshot: snapshot))
        case .membershipSubmit(let value):
            let original = try await membership.recoverMembership(.init(identity: value.identity,
                fingerprint: value.fingerprint, action: .query))
            if original != .unresolved { return .membershipRecovery(original) }
            let snapshot = try await membershipIdentities.snapshot(actorUserID: value.intent.actorUserID,
                targetUserID: value.intent.targetUserID)
            return .membershipRecovery(try await membership.submitMembership(value, snapshot: snapshot))
        case .membershipRecovery(let request):
            return .membershipRecovery(try await membership.recoverMembership(request))
        default:
            break
        }
        return try await store.executeUser(command)
    }

    public func executeTrustedSafety(_ request: V2ActorTrustedSafetyWire,
                                     authority: V2ActorTrustedSafetyAuthority) async throws -> V2RoomAdministrationResult {
        try requireRoom(request.roomID)
        return try await store.executeTrustedSafety(request, authority: authority)
    }

    public func execute(_ query: V2RoomAdministrationQuery) async throws -> V2RoomAdministrationResult {
        try requireRoom(query.roomID)
        return try await store.execute(query)
    }

    private func requireRoom(_ roomID: RoomID) throws {
        guard token.roomID == roomID else { throw V2RoomActorStateError.activationChanged }
    }
}

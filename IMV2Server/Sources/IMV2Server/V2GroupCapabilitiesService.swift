import Foundation
import IMV2Core

/// Domain seam for ordered group-capability mutations. PostgreSQL is required
/// to implement this protocol atomically with room-event delivery; keeping it
/// explicit prevents gateway handlers from owning SQL or authorization logic.
public protocol V2GroupCapabilitiesStore: Sendable {
    func setPinnedMessage(actorUserID: UserID, command: V2PinnedMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2PinnedMessage>
    func setAnnouncement(actorUserID: UserID, command: V2GroupAnnouncementCommand, capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupAnnouncement>
    func setRolePermissions(actorUserID: UserID, command: V2GroupRolePermissionsCommand, capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupRolePermissionsChange>
    func changeMemberRole(actorUserID: UserID, command: V2GroupMemberRoleCommand, capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupMemberRoleChange>
}

public enum V2GroupCapabilitiesOutcome<Value: Equatable & Sendable>: Equatable, Sendable {
    case applied(Value), idempotent(Value), idempotencyConflict
    case alreadyInDesiredState
    case revisionConflict
    case rateLimited(retryAfterSeconds: Int)
    case unavailable(FanoutAdmissionUnavailableReason)
}

public enum V2GroupCapabilitiesStoreError: Error, Equatable, Sendable {
    case roomNotFound, messageNotFound, actorNotMember, actorNotAuthorized
    case targetNotMember, notGroupRoom, messageWithdrawn, corruptPersistenceState
}

public struct V2GroupCapabilitiesIDFactory: Sendable {
    private let makeUUID: @Sendable () -> UUID
    public init(makeUUID: @escaping @Sendable () -> UUID = UUID.init) { self.makeUUID = makeUUID }
    public func make() throws -> (eventID: EventID, planID: FanoutPlanID) { try (.init(makeUUID().uuidString), .init(makeUUID().uuidString)) }
}

public struct V2GroupCapabilitiesService: Sendable {
    private let store: any V2GroupCapabilitiesStore
    private let capacityProfile: V2CapacityProfile
    private let identifiers: V2GroupCapabilitiesIDFactory
    private let now: @Sendable () -> Date
    public init(store: any V2GroupCapabilitiesStore, capacityProfile: V2CapacityProfile, identifiers: V2GroupCapabilitiesIDFactory = .init(), now: @escaping @Sendable () -> Date = Date.init) { self.store = store; self.capacityProfile = capacityProfile; self.identifiers = identifiers; self.now = now }
    public func setPinnedMessage(actorUserID: UserID, command: V2PinnedMessageCommand) async throws -> V2GroupCapabilitiesOutcome<V2PinnedMessage> { let ids = try identifiers.make(); return try await store.setPinnedMessage(actorUserID: actorUserID, command: command, capacityProfile: capacityProfile, eventID: ids.eventID, planID: ids.planID, now: now()) }
    public func setAnnouncement(actorUserID: UserID, command: V2GroupAnnouncementCommand) async throws -> V2GroupCapabilitiesOutcome<V2GroupAnnouncement> { let ids = try identifiers.make(); return try await store.setAnnouncement(actorUserID: actorUserID, command: command, capacityProfile: capacityProfile, eventID: ids.eventID, planID: ids.planID, now: now()) }
    public func setRolePermissions(actorUserID: UserID, command: V2GroupRolePermissionsCommand) async throws -> V2GroupCapabilitiesOutcome<V2GroupRolePermissionsChange> { let ids = try identifiers.make(); return try await store.setRolePermissions(actorUserID: actorUserID, command: command, capacityProfile: capacityProfile, eventID: ids.eventID, planID: ids.planID, now: now()) }
    public func changeMemberRole(actorUserID: UserID, command: V2GroupMemberRoleCommand) async throws -> V2GroupCapabilitiesOutcome<V2GroupMemberRoleChange> { let ids = try identifiers.make(); return try await store.changeMemberRole(actorUserID: actorUserID, command: command, capacityProfile: capacityProfile, eventID: ids.eventID, planID: ids.planID, now: now()) }
}

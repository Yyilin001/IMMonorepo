import Foundation
import IMV2ActorContracts
import IMV2Core

/// The two user-owned preference writes needed beside direct-room creation.
/// Opening a room is intentionally absent from this control-side capability.
public protocol V2DirectMessagePreferenceManaging: Sendable {
    func setStrangerMessagePermission(actorUserID: UserID, operationID: StrangerMessagePreferenceOperationID,
                                      permission: V2StrangerMessagePermission) async throws -> V2SetStrangerMessagePermissionOutcome
    func setUserAddPermission(actorUserID: UserID, operationID: UserAddPreferenceOperationID,
                              permission: V2UserAddPermission) async throws -> V2SetUserAddPermissionOutcome
}

extension V2DirectMessagingService: V2DirectMessagePreferenceManaging {}

/// Constructs only the user preference capability from the control store;
/// the legacy service's room-opening method need not be built in the app.
public struct V2ControlDirectMessagePreferenceClient: V2DirectMessagePreferenceManaging {
    private let store: any V2DirectMessagingStore
    private let now: @Sendable () -> Date

    public init(store: any V2DirectMessagingStore,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    public func setStrangerMessagePermission(actorUserID: UserID,
        operationID: StrangerMessagePreferenceOperationID,
        permission: V2StrangerMessagePermission) async throws -> V2SetStrangerMessagePermissionOutcome {
        try await store.setStrangerMessagePermission(command: .init(actorUserID: actorUserID,
            operationID: operationID, permission: permission), now: now())
    }

    public func setUserAddPermission(actorUserID: UserID,
        operationID: UserAddPreferenceOperationID,
        permission: V2UserAddPermission) async throws -> V2SetUserAddPermissionOutcome {
        try await store.setUserAddPermission(command: .init(actorUserID: actorUserID,
            operationID: operationID, permission: permission), now: now())
    }
}

/// Pre-room operations use the control coordinator and its fixed-placement
/// bootstrap. No old direct/group creation writer is exposed to this handler.
public struct V2GatewayRoomCreationServices: Sendable {
    typealias Invoke = @Sendable (V2ActorRoomCreationCommand, ContinuousClock.Instant) async throws -> V2ActorRoomCreationResult
    let direct: V2ActorDirectMessagingClient
    let staged: V2ActorStagedGroupCreationClient

    public init(coordinator: V2ActorRoomCreationCoordinator,
                directPreferences: any V2DirectMessagePreferenceManaging,
                callTimeout: V2ActorMilliseconds) {
        self.init(directPreferences: directPreferences, callTimeout: callTimeout) { command, deadline in
            try await coordinator.execute(command, deadline: deadline)
        }
    }

    init(directPreferences: any V2DirectMessagePreferenceManaging,
         callTimeout: V2ActorMilliseconds, invoke: @escaping Invoke) {
        let caller = V2CreationCaller(invoke: invoke, timeout: callTimeout.duration)
        direct = .init(caller: caller, preferences: directPreferences)
        staged = .init(caller: caller)
    }
}

struct V2CreationCaller: Sendable {
    let invoke: V2GatewayRoomCreationServices.Invoke
    let timeout: Duration

    func call(_ command: V2ActorRoomCreationCommand) async throws -> V2ActorRoomCreationResult {
        try Task.checkCancellation()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        return try await invoke(command, deadline)
    }
}

struct V2ActorDirectMessagingClient: V2GatewayDirectMessagingHandling {
    private let caller: V2CreationCaller
    private let preferences: any V2DirectMessagePreferenceManaging

    init(caller: V2CreationCaller, preferences: any V2DirectMessagePreferenceManaging) {
        self.caller = caller
        self.preferences = preferences
    }

    func open(actorUserID: UserID, operationID: DirectRoomOperationID,
              targetUserID: UserID) async throws -> V2OpenDirectRoomOutcome {
        let command = V2ActorOpenDirectRoomWire(actorUserID: actorUserID,
            operationID: operationID, targetUserID: targetUserID)
        guard case .direct(let value) = try await caller.call(.openDirect(command)) else {
            throw V2RoomCallFailure.outcomeUnknown
        }
        let outcome = try value.toDomain()
        switch outcome {
        case .opened(let room), .idempotent(let room):
            guard room.actorUserID == actorUserID, room.targetUserID == targetUserID else {
                throw V2RoomCallFailure.outcomeUnknown
            }
        case .idempotencyConflict, .unavailable: break
        }
        return outcome
    }

    func setStrangerMessagePermission(actorUserID: UserID,
        operationID: StrangerMessagePreferenceOperationID,
        permission: V2StrangerMessagePermission) async throws -> V2SetStrangerMessagePermissionOutcome {
        try await preferences.setStrangerMessagePermission(actorUserID: actorUserID,
            operationID: operationID, permission: permission)
    }

    func setUserAddPermission(actorUserID: UserID,
        operationID: UserAddPreferenceOperationID,
        permission: V2UserAddPermission) async throws -> V2SetUserAddPermissionOutcome {
        try await preferences.setUserAddPermission(actorUserID: actorUserID,
            operationID: operationID, permission: permission)
    }
}

struct V2ActorStagedGroupCreationClient: V2GatewayGroupAudienceImportHandling {
    private let caller: V2CreationCaller

    init(caller: V2CreationCaller) { self.caller = caller }

    func begin(actorUserID: UserID, operationID: GroupRoomOperationID,
               title: String) async throws -> V2GroupAudienceDraft {
        let command = V2ActorStagedGroupBeginWire(actorUserID: actorUserID,
            operationID: operationID, title: title)
        guard case .draft(let value) = try await caller.call(.beginStaged(command)),
              value.operationID == operationID else { throw V2RoomCallFailure.outcomeUnknown }
        return try value.toDomain()
    }

    func append(actorUserID: UserID, operationID: GroupRoomOperationID,
                memberUserIDs: [UserID]) async throws -> V2GroupAudienceDraft {
        let command = V2ActorStagedGroupAppendWire(actorUserID: actorUserID,
            operationID: operationID, memberUserIDs: memberUserIDs)
        guard case .draft(let value) = try await caller.call(.appendStaged(command)),
              value.operationID == operationID else { throw V2RoomCallFailure.outcomeUnknown }
        return try value.toDomain()
    }

    func finalize(actorUserID: UserID, operationID: GroupRoomOperationID) async throws -> V2CreateGroupRoomOutcome {
        let command = V2ActorStagedGroupOperationWire(actorUserID: actorUserID,
            operationID: operationID)
        guard case .group(let value) = try await caller.call(.finalizeStaged(command)) else {
            throw V2RoomCallFailure.outcomeUnknown
        }
        let outcome = try value.toDomain()
        switch outcome {
        case .created(let room), .idempotent(let room):
            guard room.ownerUserID == actorUserID else { throw V2RoomCallFailure.outcomeUnknown }
        default: break
        }
        return outcome
    }

    func cancel(actorUserID: UserID, operationID: GroupRoomOperationID) async throws {
        let command = V2ActorStagedGroupOperationWire(actorUserID: actorUserID,
            operationID: operationID)
        guard case .cancelled = try await caller.call(.cancelStaged(command)) else {
            throw V2RoomCallFailure.outcomeUnknown
        }
    }
}

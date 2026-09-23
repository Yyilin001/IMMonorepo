import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core

/// A single total deadline is made before resolution and is passed unchanged
/// through activation, transport, and the room turn. Runtime retry preserves
/// the original operation ID; clients never create event IDs or timestamps.
struct V2RoomRefUserCaller: Sendable {
    let invoke: @Sendable (V2RoomRequest, UserID, ContinuousClock.Instant) async throws -> V2RoomResponse
    let timeout: Duration

    init(directory: V2RoomDirectory, timeout: Duration) {
        precondition(timeout > .zero)
        self.timeout = timeout
        self.invoke = { request, actor, deadline in
            try await directory.room(request.roomID).call(request, principal: .user(actor), deadline: deadline)
        }
    }

    init(timeout: Duration,
         invoke: @escaping @Sendable (V2RoomRequest, UserID, ContinuousClock.Instant) async throws -> V2RoomResponse) {
        precondition(timeout > .zero)
        self.timeout = timeout
        self.invoke = invoke
    }

    func call(_ request: V2RoomRequest, actor: UserID,
              deadline: ContinuousClock.Instant? = nil) async throws -> V2RoomResponse {
        guard request.actorUserID == actor else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        try Task.checkCancellation()
        let end = deadline ?? ContinuousClock.now.advanced(by: timeout)
        guard end > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        return try await invoke(request, actor, end)
    }
}

public struct V2RoomRefAdministrationClient: Sendable,
    V2GatewayRoomMembershipHandling, V2GatewayModerationHandling,
    V2GatewayGroupCapabilitiesHandling {
    private let caller: V2RoomRefUserCaller

    public init(directory: V2RoomDirectory, callTimeout: Duration = .seconds(10)) {
        self.caller = .init(directory: directory, timeout: callTimeout)
    }

    init(caller: V2RoomRefUserCaller) { self.caller = caller }

    private func command(_ value: V2RoomAdministrationCommand, actor: UserID) async throws -> V2RoomAdministrationResult {
        guard case .administration(let result) = try await caller.call(.administration(value), actor: actor) else {
            throw V2RoomCallFailure.outcomeUnknown
        }
        if case .failure(let failure) = result { throw try failure.domainError() }
        return result
    }

    public func change(_ request: V2AuthenticatedMembershipChange) async throws -> V2RoomMembershipChangeOutcome {
        guard case .membership(let value) = try await command(.membership(.init(request)), actor: request.actorUserID) else {
            throw V2RoomCallFailure.outcomeUnknown
        }
        switch value {
        case .changed(let result), .idempotent(let result):
            guard result.roomID == request.roomID, result.targetUserID == request.targetUserID,
                  result.action == request.action else { throw V2RoomCallFailure.outcomeUnknown }
        default: break
        }
        return try value.domain()
    }

    public func apply(_ request: V2AuthenticatedModeration) async throws -> V2ModerationOutcome {
        guard case .moderation(let value) = try await command(.moderation(.init(request)), actor: request.actorUserID) else {
            throw V2RoomCallFailure.outcomeUnknown
        }
        switch value {
        case .applied(let result), .idempotent(let result):
            guard result.roomID == request.roomID, result.operationID == request.operationID,
                  result.action == request.action else { throw V2RoomCallFailure.outcomeUnknown }
        default: break
        }
        return try value.domain()
    }

    public func setPinnedMessage(actorUserID: UserID, command: V2PinnedMessageCommand) async throws -> V2GroupCapabilitiesOutcome<V2PinnedMessage> {
        guard case .pinned(let value) = try await self.command(.pinned(.init(actorUserID: actorUserID, command: command)), actor: actorUserID) else {
            throw V2RoomCallFailure.outcomeUnknown
        }
        switch value {
        case .applied(let result), .idempotent(let result):
            guard result.roomID == command.roomID, result.messageID == command.messageID else {
                throw V2RoomCallFailure.outcomeUnknown
            }
        default: break
        }
        return try value.domain()
    }

    public func setAnnouncement(actorUserID: UserID, command: V2GroupAnnouncementCommand) async throws -> V2GroupCapabilitiesOutcome<V2GroupAnnouncement> {
        guard case .announcement(let value) = try await self.command(.announcement(.init(actorUserID: actorUserID, command: command)), actor: actorUserID) else {
            throw V2RoomCallFailure.outcomeUnknown
        }
        switch value {
        case .applied(let result), .idempotent(let result):
            guard result.roomID == command.roomID else { throw V2RoomCallFailure.outcomeUnknown }
        default: break
        }
        return try value.domain()
    }

    public func setRolePermissions(actorUserID: UserID, command: V2GroupRolePermissionsCommand) async throws -> V2GroupCapabilitiesOutcome<V2GroupRolePermissionsChange> {
        guard case .rolePermissions(let value) = try await self.command(.rolePermissions(.init(actorUserID: actorUserID, command: command)), actor: actorUserID) else {
            throw V2RoomCallFailure.outcomeUnknown
        }
        switch value {
        case .applied(let result), .idempotent(let result):
            guard result.roomID == command.roomID else { throw V2RoomCallFailure.outcomeUnknown }
        default: break
        }
        return try value.domain()
    }

    public func changeMemberRole(actorUserID: UserID, command: V2GroupMemberRoleCommand) async throws -> V2GroupCapabilitiesOutcome<V2GroupMemberRoleChange> {
        guard case .memberRole(let value) = try await self.command(.memberRole(.init(actorUserID: actorUserID, command: command)), actor: actorUserID) else {
            throw V2RoomCallFailure.outcomeUnknown
        }
        switch value {
        case .applied(let result), .idempotent(let result):
            guard result.roomID == command.roomID, result.targetUserID == command.targetUserID else {
                throw V2RoomCallFailure.outcomeUnknown
            }
        default: break
        }
        return try value.domain()
    }
}

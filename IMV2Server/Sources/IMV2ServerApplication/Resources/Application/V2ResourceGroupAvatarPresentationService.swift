import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core

/// Control authorizes the viewer, the room Actor authorizes membership and logical state,
/// and the injected delivery port signs exact bytes. No provider-specific state enters the room.
public struct V2ResourceGroupAvatarPresentationService: Sendable {
    private let readDevice: @Sendable (UserID, DeviceID) async throws -> V2GroupAvatarDeviceObservation
    private let rooms: any V2RoomShardRouting
    private let authorization: V2ActorRoomMediaAuthorizationPort
    private let avatarForOwner: @Sendable (MediaID, String, Date) async throws -> V2ResourceAvatarAccess
    private let admission = V2GroupAvatarPresentationAdmission()

    public init(readDevice: @escaping @Sendable (UserID, DeviceID) async throws -> V2GroupAvatarDeviceObservation,
                rooms: any V2RoomShardRouting, authorization: V2ActorRoomMediaAuthorizationPort,
                avatarForOwner: @escaping @Sendable (MediaID, String, Date) async throws -> V2ResourceAvatarAccess) {
        self.readDevice = readDevice; self.rooms = rooms
        self.authorization = authorization; self.avatarForOwner = avatarForOwner
    }

    public func read(roomID: RoomID, actorUserID: UserID, deviceID: DeviceID) async throws -> V2GroupAvatarPresentation {
        guard roomID.uuidValue != nil, actorUserID.uuidValue != nil, deviceID.uuidValue != nil else {
            throw V2ResourceProviderError.preconditionFailed
        }
        guard await admission.enter(deviceID) else { throw V2ResourceProviderError.throttled(retryAfter: 1) }
        do {
            let result = try await readAdmitted(roomID: roomID, actor: actorUserID, device: deviceID)
            await admission.leave(deviceID)
            return result
        } catch { await admission.leave(deviceID); throw error }
    }

    private func readAdmitted(roomID: RoomID, actor: UserID, device: DeviceID) async throws -> V2GroupAvatarPresentation {
        let deadline = ContinuousClock.now + .seconds(10)
        let initial = try await requireDevice(actor: actor, device: device)
        let route = try await rooms.route(for: roomID)
        guard let proof = try await authorization.captureGroupAvatar(.init(roomID: roomID, actorUserID: actor), deadline: deadline),
              proof.activation.owner.shardID == route.shardID, proof.activation.owner.epoch == route.epoch else {
            throw V2MediaStoreError.downloadNotAuthorized
        }
        let observed = min(initial.observedAt, proof.observedAt)
        let validUntil = min(observed.addingTimeInterval(300), initial.expiresAt, proof.activationExpiresAt)
        try checkDeadline(deadline)
        guard validUntil > Date() else { throw V2ResourceProviderError.preconditionFailed }
        let avatar: V2ResourceAvatarAccess?
        if let media = proof.state.mediaID {
            avatar = try await avatarForOwner(media, route.shardID, min(validUntil, observed.addingTimeInterval(120)))
        } else { avatar = nil }
        // Signing may suspend on a remote provider. Never hold SQL locks while awaiting it.
        let final = try await requireDevice(actor: actor, device: device)
        guard final.expiresAt >= validUntil,
              try await authorization.recheckGroupAvatar(proof, deadline: deadline),
              try await rooms.route(for: roomID) == route else { throw V2MediaStoreError.downloadNotAuthorized }
        try checkDeadline(deadline)
        return try .init(actorUserID: actor, deviceID: device, state: proof.state,
            membershipRevision: UInt64(proof.membershipRevision), resourceGeneration: proof.resourceGeneration,
            canManage: proof.canManage, avatar: avatar, observedAt: observed, validUntil: validUntil, serverNow: Date())
    }

    private func requireDevice(actor: UserID, device: DeviceID) async throws -> V2GroupAvatarDeviceObservation {
        try await readDevice(actor, device)
    }
    private func checkDeadline(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
    }
}

private actor V2GroupAvatarPresentationAdmission {
    private var devices: [DeviceID: Int] = [:]
    private var count = 0
    func enter(_ device: DeviceID) -> Bool {
        guard count < 64, devices[device, default: 0] < 2 else { return false }
        count += 1; devices[device, default: 0] += 1; return true
    }
    func leave(_ device: DeviceID) {
        count -= 1
        if let remaining = devices[device], remaining > 1 { devices[device] = remaining - 1 }
        else { devices.removeValue(forKey: device) }
    }
}

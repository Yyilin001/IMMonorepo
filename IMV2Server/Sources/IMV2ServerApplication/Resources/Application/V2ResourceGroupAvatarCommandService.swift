import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core

/// Control authenticates the account/device; the room Actor owns the mutation and
/// immutable receipt. No storage implementation or signing operation is involved.
public struct V2ResourceGroupAvatarCommandService: Sendable {
    private let readDevice: @Sendable (UserID, DeviceID) async throws -> V2GroupAvatarDeviceObservation
    private let submit: @Sendable (UserID, V2GroupAvatarCommand, ContinuousClock.Instant) async throws -> V2GroupCapabilitiesOutcome<V2GroupAvatarChange>
    private let recovery: (@Sendable (UserID, V2GroupAvatarRecoveryRequest, ContinuousClock.Instant) async throws -> V2GroupAvatarRecoveryResult)?
    private let admission = V2GroupAvatarCommandAdmission()

    public init(readDevice: @escaping @Sendable (UserID, DeviceID) async throws -> V2GroupAvatarDeviceObservation,
         recovery: (@Sendable (UserID, V2GroupAvatarRecoveryRequest, ContinuousClock.Instant) async throws -> V2GroupAvatarRecoveryResult)? = nil,
         submit: @escaping @Sendable (UserID, V2GroupAvatarCommand, ContinuousClock.Instant) async throws -> V2GroupCapabilitiesOutcome<V2GroupAvatarChange>) {
        self.readDevice = readDevice; self.submit = submit; self.recovery = recovery
    }

    public func execute(_ command: V2GroupAvatarCommand, actorUserID: UserID, deviceID: DeviceID) async throws -> V2GroupAvatarCommandResponse {
        try Task.checkCancellation()
        guard let actor = actorUserID.uuidValue, let device = deviceID.uuidValue else { throw V2MediaStoreError.uploadNotAuthorized }
        guard await admission.enter(deviceID) else { throw V2ResourceProviderError.throttled(retryAfter: 1) }
        do {
            let response = try await executeAdmitted(command, actor: actor, device: device)
            await admission.leave(deviceID)
            return response
        } catch { await admission.leave(deviceID); throw error }
    }

    public func recover(_ request: V2GroupAvatarRecoveryRequest, actorUserID: UserID, deviceID: DeviceID) async throws -> V2GroupAvatarRecoveryResponse {
        try Task.checkCancellation()
        guard let actor = actorUserID.uuidValue, let device = deviceID.uuidValue else { throw V2MediaStoreError.uploadNotAuthorized }
        guard await admission.enter(deviceID) else { throw V2ResourceProviderError.throttled(retryAfter: 1) }
        do {
            guard let recovery else { throw V2ResourceProviderError.configurationInvalid }
            let deadline = try await authorizedDeadline(actor: actor, device: device)
            let value = try await recovery(actorUserID, request, deadline)
            let response = try V2GroupAvatarRecoveryResponse(actorUserID: actorUserID, deviceID: deviceID, request: request, result: value)
            await admission.leave(deviceID)
            return response
        } catch { await admission.leave(deviceID); throw error }
    }

    private func authorizedDeadline(actor: UUID, device: UUID) async throws -> ContinuousClock.Instant {
        let started = ContinuousClock.now
        let observation = try await readDevice(.init(uuid: actor), .init(uuid: device))
        // Start before the control read, so its latency cannot extend the grant.
        let remaining = min(10, observation.expiresAt.timeIntervalSince(observation.observedAt))
        guard remaining.isFinite, remaining > 0 else { throw V2MediaStoreError.uploadNotAuthorized }
        let deadline = started + .seconds(remaining)
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        return deadline
    }

    private func executeAdmitted(_ command: V2GroupAvatarCommand, actor: UUID, device: UUID) async throws -> V2GroupAvatarCommandResponse {
        let deadline = try await authorizedDeadline(actor: actor, device: device)
        let outcome: V2GroupAvatarCommandResponse.Outcome
        do {
            switch try await submit(.init(uuid: actor), command, deadline) {
            case .applied(let value), .idempotent(let value): outcome = .committed(value)
            case .revisionConflict: outcome = .revisionConflict
            case .idempotencyConflict: outcome = .idempotencyConflict
            case .rateLimited(let seconds): throw V2ResourceProviderError.throttled(retryAfter: TimeInterval(max(1, min(60, seconds))))
            case .unavailable: throw V2ResourceProviderError.temporarilyUnavailable
            case .alreadyInDesiredState: throw V2RoomCallFailure.outcomeUnknown
            }
        } catch V2GroupCapabilitiesStoreError.resourceUnavailable { outcome = .resourceUnavailable
        } catch V2GroupCapabilitiesStoreError.actorNotMember { outcome = .forbidden
        } catch V2GroupCapabilitiesStoreError.actorNotAuthorized { outcome = .forbidden
        } catch V2GroupCapabilitiesStoreError.roomNotFound { outcome = .forbidden
        } catch V2GroupCapabilitiesStoreError.notGroupRoom { outcome = .forbidden }
        // Do not turn a known durable receipt into a denial after the mutation.
        // The caller must replay this exact command if the HTTP response is lost.
        return try .init(actorUserID: .init(uuid: actor), deviceID: .init(uuid: device), command: command, outcome: outcome)
    }
}

public struct V2GroupAvatarDeviceObservation: Sendable {
    public let expiresAt: Date
    public let observedAt: Date
    public init(expiresAt: Date, observedAt: Date) {
        self.expiresAt = expiresAt; self.observedAt = observedAt
    }
}
private actor V2GroupAvatarCommandAdmission {
    private var devices: Set<DeviceID> = []
    func enter(_ device: DeviceID) -> Bool {
        guard devices.count < 32, !devices.contains(device) else { return false }
        devices.insert(device); return true
    }
    func leave(_ device: DeviceID) { devices.remove(device) }
}

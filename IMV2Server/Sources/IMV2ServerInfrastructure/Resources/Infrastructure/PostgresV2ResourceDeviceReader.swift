import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// Reads the control authority before and after provider I/O.
public struct PostgresV2ResourceDeviceReader: Sendable {
    private let database: any Database
    public init(database: any Database) { self.database = database }
    public enum Purpose: Equatable, Sendable { case command, presentation }
    public func read(actor: UserID, device: DeviceID, purpose: Purpose = .command) async throws -> V2GroupAvatarDeviceObservation {
        guard let actorID = actor.uuidValue, let deviceID = device.uuidValue else {
            throw purpose == .command ? V2MediaStoreError.uploadNotAuthorized : V2MediaStoreError.downloadNotAuthorized
        }
        guard let sql = database as? any SQLDatabase else { throw V2ResourceProviderError.configurationInvalid }
        guard let row = try await sql.raw("""
            SELECT d.session_expires_at,clock_timestamp() AS observed_at FROM im_v2.auth_devices d
            JOIN im_v2.public_user_profiles p ON p.user_id=d.user_id AND p.state='active'
            WHERE d.user_id=\(bind:actorID) AND d.device_id=\(bind:deviceID)
              AND d.revoked_at IS NULL AND d.session_expires_at>clock_timestamp()
              AND NOT EXISTS(SELECT 1 FROM im_v2.account_disables WHERE user_id=d.user_id)
            """).first(decoding: Row.self) else {
            throw purpose == .command ? V2MediaStoreError.uploadNotAuthorized : V2MediaStoreError.downloadNotAuthorized
        }
        return .init(expiresAt: row.expiresAt, observedAt: row.observedAt)
    }
    private struct Row: Decodable {
        let expiresAt: Date; let observedAt: Date
        enum CodingKeys: String, CodingKey { case expiresAt = "session_expires_at", observedAt = "observed_at" }
    }
}

extension V2ResourceGroupAvatarCommandService {
    public init(controlDatabase: any Database, administration: V2RoomRefAdministrationClient) {
        let reader = PostgresV2ResourceDeviceReader(database: controlDatabase)
        self.init(readDevice: { actor, device in try await reader.read(actor: actor, device: device) },
            recovery: { actor, request, deadline in
                try await administration.recoverGroupAvatar(actorUserID: actor, request: request, deadline: deadline)
            }, submit: { actor, command, deadline in
                try await administration.setGroupAvatar(actorUserID: actor, command: command, deadline: deadline)
            })
    }
    init(controlDatabase: any Database,
         recovery: (@Sendable (UserID, V2GroupAvatarRecoveryRequest, ContinuousClock.Instant) async throws -> V2GroupAvatarRecoveryResult)? = nil,
         submit: @escaping @Sendable (UserID, V2GroupAvatarCommand, ContinuousClock.Instant) async throws -> V2GroupCapabilitiesOutcome<V2GroupAvatarChange>) {
        let reader = PostgresV2ResourceDeviceReader(database: controlDatabase)
        self.init(readDevice: { actor, device in try await reader.read(actor: actor, device: device) }, recovery: recovery, submit: submit)
    }
}

extension V2ResourceGroupAvatarPresentationService {
    public init(controlDatabase: any Database, rooms: any V2RoomShardRouting,
                ownerDatabases: [String: any Database], authorization: V2ActorRoomMediaAuthorizationPort,
                avatars: V2ResourceAvatarDelivery) {
        let reader = PostgresV2ResourceDeviceReader(database: controlDatabase)
        self.init(readDevice: { actor, device in try await reader.read(actor: actor, device: device, purpose: .presentation) },
            rooms: rooms, authorization: authorization, avatarForOwner: { media, shard, expiresAt in
                guard let owner = ownerDatabases[shard] else { throw V2ResourceProviderError.configurationInvalid }
                return try await avatars.authorizedAvatar(mediaID: media, database: owner, expiresAt: expiresAt)
            })
    }
}

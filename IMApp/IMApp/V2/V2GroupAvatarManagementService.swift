import Foundation
import IMV2ClientKit
import IMV2Core

protocol V2GroupAvatarManaging: Sendable {
    func load(roomID: RoomID) async throws -> V2GroupAvatarManagementSnapshot
    func pending(roomID: RoomID) async throws -> [V2GroupAvatarIntent]
    func pendingIntent(roomID: RoomID, operationID: GroupAvatarOperationID) async throws -> V2GroupAvatarIntent?
    func change(roomID: RoomID, expectedRevision: UInt64, image: V2StagedConversationAttachment?) async throws
    func changeUsingResource(roomID: RoomID, expectedRevision: UInt64, selection: V2AvatarResourceSelection) async throws
    func act(roomID: RoomID, operationID: GroupAvatarOperationID, action: V2GroupAvatarManagementAction) async throws
}

/// iOS value adapter; authority, durable commands and recovery live in the shared SDK.
actor V2GroupAvatarManagementService: V2GroupAvatarManaging {
    nonisolated let business: V2GroupAvatarService
    init(actorUserID: UserID, deviceID: DeviceID, store: GRDBV2LocalSyncStore,
         intents: V2GroupAvatarIntentEngine, reader: any V2GroupAvatarPresentationReading,
         capabilities: any V2ResourceCapabilityReading, resources: V2ResourceCenter,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        business = .init(actorUserID: actorUserID, deviceID: deviceID, store: store, intents: intents,
            reader: reader, capabilities: capabilities, resources: resources, now: now)
    }
    func load(roomID: RoomID) async throws -> V2GroupAvatarManagementSnapshot { try await business.load(roomID: roomID) }
    func pending(roomID: RoomID) async throws -> [V2GroupAvatarIntent] { try await business.pending(roomID: roomID) }
    func pendingIntent(roomID: RoomID, operationID: GroupAvatarOperationID) async throws -> V2GroupAvatarIntent? { try await business.pendingIntent(roomID: roomID, operationID: operationID) }
    func change(roomID: RoomID, expectedRevision: UInt64, image: V2StagedConversationAttachment?) async throws {
        _ = try await business.change(roomID: roomID, expectedRevision: expectedRevision,
            image: image.map { .init(id: $0.id, localAssetID: $0.localAssetID, contentType: $0.contentType, byteCount: $0.byteCount) })
    }
    func changeUsingResource(roomID: RoomID, expectedRevision: UInt64, selection: V2AvatarResourceSelection) async throws {
        try await business.changeUsingResource(roomID: roomID, expectedRevision: expectedRevision, selection: .init(key: selection.key, source: selection.source))
    }
    func act(roomID: RoomID, operationID: GroupAvatarOperationID, action: V2GroupAvatarManagementAction) async throws { try await business.act(roomID: roomID, operationID: operationID, action: action) }
    func close() async { await business.close() }
}

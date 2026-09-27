import Foundation
import IMV2ClientKit
import IMV2Core

struct V2GroupAvatarManagementSnapshot: Sendable {
    enum Access: Sendable {
        case authorized(Authority)
        case forbidden
        case unavailable
    }
    struct Authority: Sendable {
        let state: V2GroupAvatarState
        let canManage: Bool
        let deadline: ContinuousClock.Instant
        // nil means uploads are not currently admitted, including an offline
        // capability read. Removing an existing avatar needs no new upload.
        let maximumUploadBytes: Int64?
    }
    let access: Access
    let pending: [V2GroupAvatarIntent]
}

enum V2GroupAvatarManagementAction: Sendable {
    case retry, query, closeIfAbsent, cancel, abandon
    case replace(expectedRevision: UInt64)
}

enum V2GroupAvatarManagementError: Error, Equatable {
    case forbidden, unavailable, revisionChanged, pendingDecision, imageUnsupported, imageTooLarge, invalidDraft
}

protocol V2GroupAvatarManaging: Sendable {
    func load(roomID: RoomID) async throws -> V2GroupAvatarManagementSnapshot
    func pending(roomID: RoomID) async throws -> [V2GroupAvatarIntent]
    func pendingIntent(roomID: RoomID, operationID: GroupAvatarOperationID) async throws -> V2GroupAvatarIntent?
    func change(roomID: RoomID, expectedRevision: UInt64, image: V2StagedConversationAttachment?) async throws
    func act(roomID: RoomID, operationID: GroupAvatarOperationID, action: V2GroupAvatarManagementAction) async throws
}

protocol V2PendingGroupAvatarReading: Sendable {
    func pendingPage(after: V2PendingGroupAvatarPage.Cursor?) async throws -> V2PendingGroupAvatarPage
}

/// Account lifetime orchestration. Only logical commands and copied file tokens
/// enter the journal; readers and transfer engines contain the transport choice.
actor V2GroupAvatarManagementService: V2GroupAvatarManaging, V2PendingGroupAvatarReading {
    private let actorUserID: UserID
    private let deviceID: DeviceID
    private let store: GRDBV2LocalSyncStore
    private let intents: V2GroupAvatarIntentEngine
    private let reader: any V2GroupAvatarPresentationReading
    private let capabilities: any V2ResourceCapabilityReading
    private let directory: URL
    private let now: @Sendable () -> ContinuousClock.Instant
    private let operations = V2ResourceOperationScope(limit: 16)
    private var changingRooms: Set<RoomID> = []
    private var closed = false

    init(actorUserID: UserID, deviceID: DeviceID, store: GRDBV2LocalSyncStore,
         intents: V2GroupAvatarIntentEngine,
         reader: any V2GroupAvatarPresentationReading, capabilities: any V2ResourceCapabilityReading,
         directory: URL, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.actorUserID = actorUserID; self.deviceID = deviceID; self.store = store
        self.intents = intents; self.reader = reader
        self.capabilities = capabilities; self.directory = directory.standardizedFileURL; self.now = now
    }

    func load(roomID: RoomID) async throws -> V2GroupAvatarManagementSnapshot {
        try requireOpen()
        return try await operations.run { try await self.performLoad(roomID: roomID) }
    }

    func pending(roomID: RoomID) async throws -> [V2GroupAvatarIntent] {
        try requireOpen()
        return try await operations.run { try await self.readPending(roomID: roomID) }
    }

    func pendingIntent(roomID: RoomID, operationID: GroupAvatarOperationID) async throws -> V2GroupAvatarIntent? {
        try requireOpen()
        return try await operations.run { try await self.readPendingIntent(roomID: roomID, operationID: operationID) }
    }

    func pendingPage(after: V2PendingGroupAvatarPage.Cursor?) async throws -> V2PendingGroupAvatarPage {
        try requireOpen()
        return try await operations.run { try await self.readPendingPage(after: after) }
    }

    private func readPendingPage(after: V2PendingGroupAvatarPage.Cursor?) async throws -> V2PendingGroupAvatarPage {
        try requireOpen()
        return try await store.pendingGroupAvatarOperations(actorUserID: actorUserID, after: after)
    }

    private func readPendingIntent(roomID: RoomID, operationID: GroupAvatarOperationID) async throws -> V2GroupAvatarIntent? {
        try requireOpen()
        guard let result = try await store.groupAvatarIntent(operationID) else { return nil }
        guard result.actorUserID == actorUserID, result.command.roomID == roomID else { throw V2GroupAvatarIntentError.accountMismatch }
        guard ![.committed, .cancelled].contains(result.stage),
              result.stage != .closed || result.closedDisposition == .awaitingDecision else { return nil }
        return result
    }

    func change(roomID: RoomID, expectedRevision: UInt64, image: V2StagedConversationAttachment?) async throws {
        try requireOpen()
        try await operations.run { try await self.performChange(roomID: roomID, expectedRevision: expectedRevision, image: image) }
    }

    func act(roomID: RoomID, operationID: GroupAvatarOperationID, action: V2GroupAvatarManagementAction) async throws {
        try requireOpen()
        try await operations.run { try await self.performAction(roomID: roomID, operationID: operationID, action: action) }
    }

    func close() async {
        closed = true
        await operations.close()
        // Intent and shared transfer engines have a separate account owner.
    }

    private func requireOpen() throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
    }

    private func readPending(roomID: RoomID) async throws -> [V2GroupAvatarIntent] {
        try requireOpen()
        let result = try await store.pendingGroupAvatarIntents(in: roomID)
        guard result.allSatisfy({ $0.actorUserID == actorUserID }) else { throw V2GroupAvatarIntentError.accountMismatch }
        return result
    }

    private func performLoad(roomID: RoomID) async throws -> V2GroupAvatarManagementSnapshot {
        let access: V2GroupAvatarManagementSnapshot.Access
        do { access = .authorized(try await authority(roomID: roomID)) }
        catch is CancellationError { throw CancellationError() }
        catch V2GroupAvatarReadError.forbidden { access = .forbidden }
        catch V2GroupAvatarManagementError.forbidden { access = .forbidden }
        catch { access = .unavailable }
        // Losing current membership must not hide recovery of one's old command.
        return try await .init(access: access, pending: readPending(roomID: roomID))
    }

    private func authority(roomID: RoomID) async throws -> V2GroupAvatarManagementSnapshot.Authority {
        try requireOpen()
        let started = now()
        let value = try await reader.readGroupAvatar(roomID: roomID)
        try requireOpen()
        guard value.actorUserID == actorUserID, value.deviceID == deviceID, value.state.roomID == roomID,
              value.state.revision >= (try await store.groupAvatarRevision(roomID: roomID)) else {
            throw V2GroupAvatarReadError.invalidResponse
        }
        let deadline = started.advanced(by: .milliseconds(value.validUntilUnixMilliseconds - value.serverNowUnixMilliseconds))
        var maximum: Int64?
        try requireOpen()
        if value.canManage {
            do {
                let supported = try await capabilities.capabilities()
                if supported.allowedUsages.contains(.groupAvatar), supported.uploadModes.contains(.httpPut) {
                    maximum = min(supported.maximumBytes, 10 * 1_024 * 1_024)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { /* New uploads remain disabled; existing commands can recover. */ }
        }
        try requireOpen()
        guard deadline > now(), value.state.revision >= (try await store.groupAvatarRevision(roomID: roomID)) else {
            throw V2GroupAvatarManagementError.unavailable
        }
        return .init(state: value.state, canManage: value.canManage, deadline: deadline, maximumUploadBytes: maximum)
    }

    private func requireManagement(roomID: RoomID, expectedRevision: UInt64) async throws -> V2GroupAvatarManagementSnapshot.Authority {
        let result = try await authority(roomID: roomID)
        guard result.canManage else { throw V2GroupAvatarManagementError.forbidden }
        guard result.state.revision == expectedRevision else { throw V2GroupAvatarManagementError.revisionChanged }
        return result
    }

    private func validateImage(contentType: String, byteCount: Int64, authority: V2GroupAvatarManagementSnapshot.Authority) throws {
        guard let maximum = authority.maximumUploadBytes else { throw V2GroupAvatarManagementError.unavailable }
        guard ["image/jpeg", "image/png"].contains(contentType) else { throw V2GroupAvatarManagementError.imageUnsupported }
        guard byteCount > 0, byteCount <= maximum else { throw V2GroupAvatarManagementError.imageTooLarge }
    }

    private func performChange(roomID: RoomID, expectedRevision: UInt64, image: V2StagedConversationAttachment?) async throws {
        try requireOpen()
        guard changingRooms.insert(roomID).inserted else { throw V2GroupAvatarIntentError.busy }
        defer { changingRooms.remove(roomID) }
        guard try await readPending(roomID: roomID).isEmpty else { throw V2GroupAvatarManagementError.pendingDecision }
        let access = try await requireManagement(roomID: roomID, expectedRevision: expectedRevision)
        let request: V2ResourceUploadRequest?
        let jobID: UUID?, mutation: V2GroupAvatarMutation
        if let image {
            try validateImage(contentType: image.contentType, byteCount: image.byteCount, authority: access)
            guard image.fileURL.standardizedFileURL == directory.appendingPathComponent(image.id.uuidString),
                  try await store.resourceTransfer(id: image.id) == nil else { throw V2GroupAvatarManagementError.invalidDraft }
            let checksum = try V2ResourceFileDigest.sha256(fileURL: image.fileURL, expectedByteCount: image.byteCount)
            let upload = try V2ResourceUploadRequest(operationID: .init(uuid: image.id), mediaID: .init(uuid: image.id),
                usage: .groupAvatar(roomID), contentType: image.contentType, byteCount: image.byteCount,
                checksum: .init(value: checksum), clientModes: [.httpPut])
            try requireOpen()
            request = upload; jobID = image.id; mutation = .set(upload.mediaID)
        } else { request = nil; jobID = nil; mutation = .remove }
        let command = try V2GroupAvatarCommand(operationID: .init(uuid: UUID()), roomID: roomID,
            expectedRevision: expectedRevision, mutation: mutation)
        try requireOpen()
        guard access.deadline > now() else { throw V2GroupAvatarManagementError.unavailable }
        if let request, let jobID {
            _ = try await store.freezeGroupAvatarUploadIntent(actorUserID: actorUserID, command: command,
                uploadJobID: jobID, request: request, localFileToken: jobID.uuidString)
        } else {
            _ = try await store.freezeGroupAvatarIntent(actorUserID: actorUserID, command: command, uploadJobID: nil)
        }
        // Failure now leaves a frozen command for account recovery, never a new ID.
        try? await intents.start(command.operationID)
    }

    private func performAction(roomID: RoomID, operationID: GroupAvatarOperationID, action: V2GroupAvatarManagementAction) async throws {
        try requireOpen()
        guard let original = try await store.groupAvatarIntent(operationID), original.actorUserID == actorUserID,
              original.command.roomID == roomID else { throw V2GroupAvatarIntentError.accountMismatch }
        try requireOpen()
        switch action {
        case .retry: _ = try await intents.retry(operationID)
        case .query: _ = try await intents.resolve(operationID, action: .query)
        case .closeIfAbsent: _ = try await intents.resolve(operationID, action: .closeIfAbsent)
        case .cancel: try await intents.cancel(operationID)
        case .abandon: try await intents.abandonClosed(operationID)
        case .replace(let expectedRevision):
            guard changingRooms.insert(roomID).inserted else { throw V2GroupAvatarIntentError.busy }
            defer { changingRooms.remove(roomID) }
            let access = try await requireManagement(roomID: roomID, expectedRevision: expectedRevision)
            if let jobID = original.uploadJobID {
                guard let job = try await store.resourceTransfer(id: jobID), UUID(uuidString: job.localFileToken) != nil else {
                    throw V2GroupAvatarManagementError.invalidDraft
                }
                try validateImage(contentType: job.request.contentType, byteCount: job.request.byteCount, authority: access)
                let digest = try V2ResourceFileDigest.sha256(fileURL: directory.appendingPathComponent(job.localFileToken), expectedByteCount: job.request.byteCount)
                guard digest == job.request.checksum.value else { throw V2GroupAvatarManagementError.invalidDraft }
            }
            try requireOpen()
            guard access.deadline > now() else { throw V2GroupAvatarManagementError.unavailable }
            let replacement = try await intents.replaceClosed(operationID, expectedRevision: expectedRevision)
            try? await intents.start(replacement)
        }
    }
}

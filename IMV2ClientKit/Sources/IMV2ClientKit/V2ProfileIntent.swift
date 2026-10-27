import Foundation
import IMV2Core

/// Account-owned staged source; upload identity remains stable across recovery.
public struct V2ProfileAvatarUpload: Equatable, Codable, Sendable {
    public let id: UUID
    public let localAssetID: V2LocalResourceAssetID
    public let displayName: String
    public let contentType: String
    public let byteCount: Int64
    public init(id: UUID, localAssetID: V2LocalResourceAssetID, displayName: String, contentType: String, byteCount: Int64) throws {
        guard contentType.hasPrefix("image/"), byteCount > 0, byteCount <= 50 * 1_024 * 1_024,
              displayName.utf8.count <= 1024, contentType.utf8.count <= 256 else { throw V2OperationWorkError.invalidRecord }
        self.id = id; self.localAssetID = localAssetID; self.displayName = displayName; self.contentType = contentType; self.byteCount = byteCount
    }
    private enum CodingKeys: String, CodingKey { case id, localAssetID, displayName, contentType, byteCount }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id), localAssetID: values.decode(V2LocalResourceAssetID.self, forKey: .localAssetID), displayName: values.decode(String.self, forKey: .displayName), contentType: values.decode(String.self, forKey: .contentType), byteCount: values.decode(Int64.self, forKey: .byteCount))
    }

}
public struct V2ProfileAvatarImport: Equatable, Codable, Sendable {
    public let id: UUID
    public let request: V2ResourceImportRequest
    public init(id: UUID, request: V2ResourceImportRequest) throws {
        guard request.targetUsage == .userAvatar else { throw V2OperationWorkError.invalidRecord }
        self.id = id; self.request = request
    }
    private enum CodingKeys: String, CodingKey { case id, request }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id), request: values.decode(V2ResourceImportRequest.self, forKey: .request))
    }
}
public enum V2ProfileAvatarPreparation: Equatable, Codable, Sendable {
    case upload(V2ProfileAvatarUpload), serverImport(V2ProfileAvatarImport)
    public var transferID: V2ManagedResourceTransferID {
        switch self { case .upload(let value): .upload(value.id); case .serverImport(let value): .serverImport(value.id) }
    }
}
public struct V2ProfileIntent: Equatable, Codable, Sendable {
    public let id: UUID
    public let accountID: UserID
    public let operationID: ProfileUpdateOperationID
    public let expectedRevision: V2ProfileRevision
    public let patch: V2ProfilePatch
    public let avatarPreparation: V2ProfileAvatarPreparation?
    public var avatarUpload: V2ProfileAvatarUpload? { if case .upload(let value) = avatarPreparation { value } else { nil } }
    public var avatarImport: V2ProfileAvatarImport? { if case .serverImport(let value) = avatarPreparation { value } else { nil } }
    public let deadline: Date
    public let workID: UUID?
    public init(id: UUID, accountID: UserID, operationID: ProfileUpdateOperationID, expectedRevision: V2ProfileRevision, patch: V2ProfilePatch, avatarUpload: V2ProfileAvatarUpload?, deadline: Date, workID: UUID?) {
        self.init(id: id, accountID: accountID, operationID: operationID, expectedRevision: expectedRevision, patch: patch,
                  avatarPreparation: avatarUpload.map(V2ProfileAvatarPreparation.upload), deadline: deadline, workID: workID)
    }
    public init(id: UUID, accountID: UserID, operationID: ProfileUpdateOperationID, expectedRevision: V2ProfileRevision, patch: V2ProfilePatch, avatarPreparation: V2ProfileAvatarPreparation?, deadline: Date, workID: UUID?) {
        self.id = id; self.accountID = accountID; self.operationID = operationID; self.expectedRevision = expectedRevision
        self.patch = patch; self.avatarPreparation = avatarPreparation; self.deadline = deadline; self.workID = workID
    }
}
public struct V2ProfileIntentStatus: Equatable, Sendable {
    public enum Phase: Sendable { case waitingToSubmit, preparingAvatar, confirming, committed, needsAttention, closed }
    public let intent: V2ProfileIntent
    public let phase: Phase
    public let canReplace: Bool
    public let sourceRetained: Bool
    public let currentSnapshot: V2ProfileView?
    public init(intent: V2ProfileIntent, phase: Phase, currentSnapshot: V2ProfileView?, sourceRetained: Bool, canReplace: Bool = false) {
        self.intent = intent; self.phase = phase; self.currentSnapshot = currentSnapshot; self.canReplace = canReplace
        self.sourceRetained = sourceRetained
    }
}
public protocol V2ProfileAvatarPreparing: Sendable {
    /// Returns only after the durable upload with this exact identity is Ready.
    func ensureReady(_ upload: V2ProfileAvatarUpload) async throws -> V2AvatarReference
}
public protocol V2ProfileIntentManaging: Sendable {
    func currentProfile() async throws -> V2ProfileView
    func localProfile() async throws -> V2ProfileView?
    func refreshProfile() async throws -> V2ProfileView
    func pendingIntent() async throws -> V2ProfileIntent?
    func enqueue(expectedRevision: V2ProfileRevision, patch: V2ProfilePatch, avatarUpload: V2ProfileAvatarUpload?) async throws -> V2ProfileIntent
    func enqueueImportedAvatar(expectedRevision: V2ProfileRevision, patch: V2ProfilePatch, source: V2ProfileAvatarImport) async throws -> V2ProfileIntent
    func resumeOrReapply(intentID: UUID) async throws -> V2ProfileIntent
    func discard(intentID: UUID) async throws
    func observe(intentID: UUID) async -> AsyncThrowingStream<V2ProfileIntentStatus, Error>
}

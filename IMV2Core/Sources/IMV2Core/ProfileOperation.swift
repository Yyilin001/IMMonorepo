import Foundation

public enum V2ProfileDisplayNamePatch: Equatable, Codable, Sendable {
    case unchanged
    case set(String)
}
public enum V2ProfileAvatarPatch: Equatable, Codable, Sendable {
    case unchanged
    case remove
    case set(V2AvatarReference)
}
public enum V2ProfileOperationValidationError: Error, Equatable, Sendable {
    case emptyPatch, invalidDeadline, invalidReceipt
}

public struct V2ProfilePatch: Equatable, Codable, Sendable {
    public let displayName: V2ProfileDisplayNamePatch
    public let avatar: V2ProfileAvatarPatch
    public init(displayName: V2ProfileDisplayNamePatch = .unchanged, avatar: V2ProfileAvatarPatch = .unchanged) throws {
        guard displayName != .unchanged || avatar != .unchanged else { throw V2ProfileOperationValidationError.emptyPatch }
        self.displayName = displayName; self.avatar = avatar
    }
    private enum CodingKeys: String, CodingKey { case displayName, avatar }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(displayName: values.decode(V2ProfileDisplayNamePatch.self, forKey: .displayName), avatar: values.decode(V2ProfileAvatarPatch.self, forKey: .avatar))
    }
}

public struct V2ProfileUpdateCommand: Equatable, Sendable {
    public let actorUserID: UserID
    public let operationID: ProfileUpdateOperationID
    public let expectedRevision: V2ProfileRevision
    public let patch: V2ProfilePatch
    public let firstSubmissionDeadlineMilliseconds: UInt64
    public let fingerprint: V2OperationFingerprint
    public init(actorUserID: UserID, operationID: ProfileUpdateOperationID, expectedRevision: V2ProfileRevision,
                patch: V2ProfilePatch, firstSubmissionDeadlineMilliseconds: UInt64) throws {
        guard firstSubmissionDeadlineMilliseconds > 0, firstSubmissionDeadlineMilliseconds <= UInt64(Int64.max) else {
            throw V2ProfileOperationValidationError.invalidDeadline
        }
        let name: V2ProfileDisplayNamePatch
        switch patch.displayName {
        case .unchanged: name = .unchanged
        case .set(let input):
            let identity = try V2PublicIdentity(userID: actorUserID, handle: .init("profile_update"), displayName: input, accountKind: .regular)
            name = .set(identity.displayName)
        }
        self.actorUserID = actorUserID; self.operationID = operationID; self.expectedRevision = expectedRevision
        self.patch = try .init(displayName: name, avatar: patch.avatar)
        self.firstSubmissionDeadlineMilliseconds = firstSubmissionDeadlineMilliseconds
        var fields: [V2OperationFingerprintField] = [
            .init("actor", .text(actorUserID.rawValue)), .init("operation", .text(operationID.rawValue)),
            .init("expectedRevision", .unsigned(expectedRevision.rawValue)),
            .init("firstSubmissionDeadline", .unsigned(firstSubmissionDeadlineMilliseconds))
        ]
        switch name {
        case .unchanged: fields.append(.init("displayName", .absent))
        case .set(let value): fields.append(.init("displayName", .text(value)))
        }
        switch patch.avatar {
        case .unchanged: fields.append(.init("avatarAction", .text("unchanged")))
        case .remove: fields.append(.init("avatarAction", .text("remove")))
        case .set(let avatar): fields.append(.init("avatarAction", .text("set"))); fields.append(.init("avatar", .text(avatar.mediaID.rawValue)))
        }
        self.fingerprint = try .init(kind: .profileUpdate, fields: fields)
    }
}

public enum V2ProfileOperationRejection: Equatable, Codable, Sendable {
    case revisionConflict(current: V2ProfileRevision)
    case avatarUnavailable
    case expiredUnsubmitted
}
public enum V2ProfileOperationTerminalOutcome: Equatable, Codable, Sendable {
    case committed(revision: V2ProfileRevision, visibilityRevision: V2ProfileRevision)
    case rejected(V2ProfileOperationRejection)
    case closed
}
public struct V2ProfileOperationReceipt: Equatable, Codable, Sendable {
    public let actorUserID: UserID
    public let operationID: ProfileUpdateOperationID
    public let fingerprint: V2OperationFingerprint
    public let outcome: V2ProfileOperationTerminalOutcome
    public let resolvedAtMilliseconds: UInt64
    public init(actorUserID: UserID, operationID: ProfileUpdateOperationID, fingerprint: V2OperationFingerprint,
                outcome: V2ProfileOperationTerminalOutcome, resolvedAtMilliseconds: UInt64) throws {
        guard resolvedAtMilliseconds <= UInt64(Int64.max) else { throw V2ProfileOperationValidationError.invalidReceipt }
        self.actorUserID = actorUserID; self.operationID = operationID; self.fingerprint = fingerprint
        self.outcome = outcome; self.resolvedAtMilliseconds = resolvedAtMilliseconds
    }
    public func validates(actorUserID: UserID, operationID: ProfileUpdateOperationID, fingerprint: V2OperationFingerprint) -> Bool {
        self.actorUserID == actorUserID && self.operationID == operationID && self.fingerprint == fingerprint
    }
    private enum CodingKeys: String, CodingKey { case actorUserID, operationID, fingerprint, outcome, resolvedAtMilliseconds }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(actorUserID: values.decode(UserID.self, forKey: .actorUserID), operationID: values.decode(ProfileUpdateOperationID.self, forKey: .operationID), fingerprint: values.decode(V2OperationFingerprint.self, forKey: .fingerprint), outcome: values.decode(V2ProfileOperationTerminalOutcome.self, forKey: .outcome), resolvedAtMilliseconds: values.decode(UInt64.self, forKey: .resolvedAtMilliseconds))
    }
}
public struct V2ProfileUpdateResult: Equatable, Codable, Sendable {
    public let receipt: V2ProfileOperationReceipt
    public let currentSnapshot: V2ProfileView?
    public init(receipt: V2ProfileOperationReceipt, currentSnapshot: V2ProfileView?) {
        self.receipt = receipt; self.currentSnapshot = currentSnapshot
    }
}
public struct V2ProfileOperationRecoveryRequest: Equatable, Codable, Sendable {
    public let actorUserID: UserID
    public let operationID: ProfileUpdateOperationID
    public let fingerprint: V2OperationFingerprint
    public let action: V2OperationRecoveryRequest.Action
    public init(actorUserID: UserID, operationID: ProfileUpdateOperationID, fingerprint: V2OperationFingerprint, action: V2OperationRecoveryRequest.Action) {
        self.actorUserID = actorUserID; self.operationID = operationID; self.fingerprint = fingerprint; self.action = action
    }
}
public enum V2ProfileOperationRecoveryResult: Equatable, Codable, Sendable {
    case receipt(V2ProfileOperationReceipt, currentSnapshot: V2ProfileView?)
    case unresolved
    case fingerprintConflict
}

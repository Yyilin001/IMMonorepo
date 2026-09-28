import Foundation

/// Zero is the absence of a prior personal fact; persisted mutations start at one.
public struct V2PersonalPreferenceRevision: RawRepresentable, Codable, Equatable, Hashable, Comparable, Sendable {
    public let rawValue: UInt64
    public var signedValue: Int64 { Int64(rawValue) }
    public init?(rawValue: UInt64) {
        guard rawValue <= UInt64(Int64.max) else { return nil }
        self.rawValue = rawValue
    }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(rawValue: try container.decode(UInt64.self)) else {
            throw V2PersonalPreferenceOperationError.invalidReceipt
        }
        self = value
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public static let initial = Self(rawValue: 0)!
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
public enum V2PersonalPreferenceOperationError: Error, Equatable, Sendable {
    case invalidDeadline, invalidScope, invalidReceipt
}
public enum V2PersonalPreferenceValue: Equatable, Codable, Sendable {
    case conversationState(V2ConversationState)
    case messageFavorite(V2MessageFavorite)
}
public enum V2PersonalPreferenceRejection: Equatable, Codable, Sendable {
    case revisionConflict(current: V2PersonalPreferenceRevision)
    case permissionDenied
    case notFound
    case expiredUnsubmitted
}
public enum V2PersonalPreferenceTerminalOutcome: Equatable, Codable, Sendable {
    case committed(V2PersonalPreferenceValue)
    case rejected(V2PersonalPreferenceRejection)
    case closed
}
public struct V2PersonalPreferenceReceipt: Equatable, Codable, Sendable {
    public let identity: V2OperationIdentity
    public let fingerprint: V2OperationFingerprint
    public let outcome: V2PersonalPreferenceTerminalOutcome
    public let resolvedAtMilliseconds: UInt64
    public init(
        identity: V2OperationIdentity, fingerprint: V2OperationFingerprint,
        outcome: V2PersonalPreferenceTerminalOutcome, resolvedAtMilliseconds: UInt64
    ) throws {
        try validatePersonalPreferenceIdentity(identity)
        guard resolvedAtMilliseconds <= UInt64(Int64.max) else {
            throw V2PersonalPreferenceOperationError.invalidReceipt
        }
        if case .committed(let value) = outcome {
            switch (identity.operation, identity.scope, value) {
            case (.conversationPreference, .room(let room), .conversationState(let state)):
                guard room == state.roomID, state.revision.rawValue > 0 else {
                    throw V2PersonalPreferenceOperationError.invalidReceipt
                }
            case (.messageFavorite, .message(let room, let message), .messageFavorite(let favorite)):
                guard room == favorite.roomID, message == favorite.messageID, favorite.revision.rawValue > 0 else {
                    throw V2PersonalPreferenceOperationError.invalidReceipt
                }
            default: throw V2PersonalPreferenceOperationError.invalidReceipt
            }
        }
        self.identity = identity
        self.fingerprint = fingerprint
        self.outcome = outcome
        self.resolvedAtMilliseconds = resolvedAtMilliseconds
    }
    private enum CodingKeys: String, CodingKey { case identity, fingerprint, outcome, resolvedAtMilliseconds }
    public init(from decoder: any Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identity: v.decode(V2OperationIdentity.self, forKey: .identity),
            fingerprint: v.decode(V2OperationFingerprint.self, forKey: .fingerprint),
            outcome: v.decode(V2PersonalPreferenceTerminalOutcome.self, forKey: .outcome),
            resolvedAtMilliseconds: v.decode(UInt64.self, forKey: .resolvedAtMilliseconds))
    }
}
public struct V2PersonalPreferenceRecoveryRequest: Equatable, Codable, Sendable {
    public let identity: V2OperationIdentity
    public let fingerprint: V2OperationFingerprint
    public let action: V2OperationRecoveryRequest.Action
    public var roomID: RoomID {
        switch identity.scope {
        case .room(let room), .message(let room, _): room
        default: preconditionFailure("validated personal preference scope")
        }
    }
    public init(
        identity: V2OperationIdentity, fingerprint: V2OperationFingerprint, action: V2OperationRecoveryRequest.Action
    ) throws {
        try validatePersonalPreferenceIdentity(identity)
        self.identity = identity
        self.fingerprint = fingerprint
        self.action = action
    }
    private enum CodingKeys: String, CodingKey { case identity, fingerprint, action }
    public init(from decoder: any Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identity: v.decode(V2OperationIdentity.self, forKey: .identity),
            fingerprint: v.decode(V2OperationFingerprint.self, forKey: .fingerprint),
            action: v.decode(V2OperationRecoveryRequest.Action.self, forKey: .action))
    }
}
public enum V2PersonalPreferenceRecoveryResult: Equatable, Codable, Sendable {
    case receipt(V2PersonalPreferenceReceipt)
    case unresolved
    case fingerprintConflict
}
private func validatePersonalPreferenceIdentity(_ identity: V2OperationIdentity) throws {
    switch (identity.operation, identity.scope) {
    case (.conversationPreference, .room), (.messageFavorite, .message): return
    default: throw V2PersonalPreferenceOperationError.invalidScope
    }
}

import Foundation

/// State of this actor's normalized reaction key, independent of message content revisions.
public enum V2MessageReactionTargetState: String, Codable, Equatable, Sendable {
    case present, absent
}

public struct V2MessageReactionOperationCommand: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: MessageReactionOperationID
    public let messageID: MessageID
    public let reaction: String
    public let targetState: V2MessageReactionTargetState
    public let expectedReactionRevision: UInt64
    public let firstSubmissionDeadlineMilliseconds: UInt64
    public var identity: V2OperationIdentity { get throws {
        try .init(accountID: actorUserID, scope: .message(roomID, messageID), operation: .reaction(operationID))
    } }
    public var fingerprint: V2OperationFingerprint { get throws {
        try .init(kind: .reaction, fields: [
            .init("identity", .text(identity.storageKey)), .init("reaction", .text(reaction)),
            .init("targetState", .text(targetState.rawValue)),
            .init("expectedReactionRevision", .unsigned(expectedReactionRevision)),
            .init("firstSubmissionDeadline", .unsigned(firstSubmissionDeadlineMilliseconds))
        ])
    } }
    public init(command: V2ChangeMessageReactionCommand, expectedReactionRevision: UInt64,
                firstSubmissionDeadlineMilliseconds: UInt64) throws {
        guard expectedReactionRevision < UInt64(Int64.max) else { throw V2MessageOperationValidationError.invalidReceipt }
        try validateMessageOperationDeadline(firstSubmissionDeadlineMilliseconds)
        roomID = command.roomID; actorUserID = command.actorUserID; operationID = command.operationID
        messageID = command.messageID; reaction = command.reaction
        targetState = command.action == .add ? .present : .absent
        self.expectedReactionRevision = expectedReactionRevision
        self.firstSubmissionDeadlineMilliseconds = firstSubmissionDeadlineMilliseconds
        _ = try identity
    }
    public func domainCommand() throws -> V2ChangeMessageReactionCommand {
        try .init(roomID: roomID, actorUserID: actorUserID, operationID: operationID,
                  messageID: messageID, reaction: reaction, action: targetState == .present ? .add : .remove)
    }
    private enum CodingKeys: String, CodingKey {
        case roomID, actorUserID, operationID, messageID, reaction, targetState
        case expectedReactionRevision, firstSubmissionDeadlineMilliseconds
    }
    public init(from decoder: any Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        let target = try v.decode(V2MessageReactionTargetState.self, forKey: .targetState)
        let command = try V2ChangeMessageReactionCommand(roomID: v.decode(RoomID.self, forKey: .roomID),
            actorUserID: v.decode(UserID.self, forKey: .actorUserID),
            operationID: v.decode(MessageReactionOperationID.self, forKey: .operationID),
            messageID: v.decode(MessageID.self, forKey: .messageID), reaction: v.decode(String.self, forKey: .reaction),
            action: target == .present ? .add : .remove)
        try self.init(command: command, expectedReactionRevision: v.decode(UInt64.self, forKey: .expectedReactionRevision),
                      firstSubmissionDeadlineMilliseconds: v.decode(UInt64.self, forKey: .firstSubmissionDeadlineMilliseconds))
    }
}

/// Currently authorized own-key editing baseline; never evidence of an old operation's execution.
public struct V2MessageReactionSnapshot: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let messageID: MessageID
    public let reaction: String
    public let targetState: V2MessageReactionTargetState
    public let revision: UInt64
    public init(roomID: RoomID, actorUserID: UserID, messageID: MessageID, reaction: String,
                targetState: V2MessageReactionTargetState, revision: UInt64) throws {
        let normalized = try V2ChangeMessageReactionCommand(roomID: roomID, actorUserID: actorUserID,
            operationID: .init(uuid: UUID()), messageID: messageID, reaction: reaction, action: .add).reaction
        guard revision <= UInt64(Int64.max), revision > 0 || targetState == .absent else {
            throw V2MessageOperationValidationError.invalidReceipt
        }
        self.roomID = roomID; self.actorUserID = actorUserID; self.messageID = messageID
        self.reaction = normalized; self.targetState = targetState; self.revision = revision
    }
    private enum CodingKeys: String, CodingKey { case roomID, actorUserID, messageID, reaction, targetState, revision }
    public init(from decoder: any Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(roomID: v.decode(RoomID.self, forKey: .roomID), actorUserID: v.decode(UserID.self, forKey: .actorUserID),
            messageID: v.decode(MessageID.self, forKey: .messageID), reaction: v.decode(String.self, forKey: .reaction),
            targetState: v.decode(V2MessageReactionTargetState.self, forKey: .targetState), revision: v.decode(UInt64.self, forKey: .revision))
    }
}

public struct V2MessageReactionEventProof: Codable, Equatable, Sendable {
    public let roomSequence: UInt64
    public let eventID: EventID
    public init(roomSequence: UInt64, eventID: EventID) throws {
        guard roomSequence > 0, roomSequence <= UInt64(Int64.max) else { throw V2MessageOperationValidationError.invalidReceipt }
        self.roomSequence = roomSequence; self.eventID = eventID
    }
    private enum CodingKeys: String, CodingKey { case roomSequence, eventID }
    public init(from decoder: any Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(roomSequence: v.decode(UInt64.self, forKey: .roomSequence), eventID: v.decode(EventID.self, forKey: .eventID))
    }
}

/// Every newly committed operation advances revision, including an already-satisfied target.
public struct V2MessageReactionCommit: Codable, Equatable, Sendable {
    public let targetState: V2MessageReactionTargetState
    public let revision: UInt64
    public let event: V2MessageReactionEventProof?
    public init(targetState: V2MessageReactionTargetState, revision: UInt64, event: V2MessageReactionEventProof?) throws {
        guard revision > 0, revision <= UInt64(Int64.max) else { throw V2MessageOperationValidationError.invalidReceipt }
        self.targetState = targetState; self.revision = revision; self.event = event
    }
    private enum CodingKeys: String, CodingKey { case targetState, revision, event }
    public init(from decoder: any Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(targetState: v.decode(V2MessageReactionTargetState.self, forKey: .targetState),
            revision: v.decode(UInt64.self, forKey: .revision), event: v.decodeIfPresent(V2MessageReactionEventProof.self, forKey: .event))
    }
}
public enum V2MessageReactionRejection: Codable, Equatable, Sendable {
    case expiredUnsubmitted, permissionDenied, roomNotFound, messageNotFound, messageWithdrawn, reactionLimitReached
    case revisionConflict(current: UInt64)
}
public enum V2MessageReactionTerminalOutcome: Codable, Equatable, Sendable {
    case committed(V2MessageReactionCommit), rejected(V2MessageReactionRejection), closed
}
/// Minimal original result, not permission to display the message or read its current reaction set.
public struct V2MessageReactionReceipt: Codable, Equatable, Sendable {
    public let identity: V2OperationIdentity
    public let fingerprint: V2OperationFingerprint
    public let outcome: V2MessageReactionTerminalOutcome
    public let resolvedAtMilliseconds: UInt64
    public init(identity: V2OperationIdentity, fingerprint: V2OperationFingerprint,
                outcome: V2MessageReactionTerminalOutcome, resolvedAtMilliseconds: UInt64) throws {
        guard identity.kind == .reaction, case .message = identity.scope,
              resolvedAtMilliseconds > 0, resolvedAtMilliseconds <= UInt64(Int64.max) else {
            throw V2MessageOperationValidationError.invalidReceipt
        }
        if case .rejected(.revisionConflict(let current)) = outcome, current > UInt64(Int64.max) {
            throw V2MessageOperationValidationError.invalidReceipt
        }
        self.identity = identity; self.fingerprint = fingerprint; self.outcome = outcome
        self.resolvedAtMilliseconds = resolvedAtMilliseconds
    }
    public func validates(identity: V2OperationIdentity, fingerprint: V2OperationFingerprint) -> Bool {
        self.identity == identity && self.fingerprint == fingerprint
    }
    private enum CodingKeys: String, CodingKey { case identity, fingerprint, outcome, resolvedAtMilliseconds }
    public init(from decoder: any Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(identity: v.decode(V2OperationIdentity.self, forKey: .identity),
            fingerprint: v.decode(V2OperationFingerprint.self, forKey: .fingerprint),
            outcome: v.decode(V2MessageReactionTerminalOutcome.self, forKey: .outcome),
            resolvedAtMilliseconds: v.decode(UInt64.self, forKey: .resolvedAtMilliseconds))
    }
}
public struct V2MessageReactionRecoveryRequest: Codable, Equatable, Sendable {
    public let identity: V2OperationIdentity
    public let fingerprint: V2OperationFingerprint
    public let action: V2OperationRecoveryRequest.Action
    public init(identity: V2OperationIdentity, fingerprint: V2OperationFingerprint, action: V2OperationRecoveryRequest.Action) throws {
        guard identity.kind == .reaction else { throw V2MessageOperationValidationError.invalidKind }
        self.identity = identity; self.fingerprint = fingerprint; self.action = action
    }
    private enum CodingKeys: String, CodingKey { case identity, fingerprint, action }
    public init(from decoder: any Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(identity: v.decode(V2OperationIdentity.self, forKey: .identity),
            fingerprint: v.decode(V2OperationFingerprint.self, forKey: .fingerprint),
            action: v.decode(V2OperationRecoveryRequest.Action.self, forKey: .action))
    }
}
public enum V2MessageReactionRecoveryResult: Codable, Equatable, Sendable {
    case receipt(V2MessageReactionReceipt), deferred(V2MessageOperationRetryHint), unresolved, fingerprintConflict
}

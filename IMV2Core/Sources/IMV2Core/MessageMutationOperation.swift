import Foundation

public enum V2MessageOperationValidationError: Error, Equatable, Sendable {
    case invalidDeadline, invalidReceipt, invalidKind
}

/// Frozen execution envelope; the inner command remains the domain content contract.
public struct V2MessageEditOperationCommand: Equatable, Codable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: MessageEditOperationID
    public let messageID: MessageID
    public let expectedMessageRevision: UInt64
    public let text: String
    public let firstSubmissionDeadlineMilliseconds: UInt64
    public var identity: V2OperationIdentity { get throws {
        try .init(accountID: actorUserID, scope: .message(roomID,messageID), operation: .editMessage(operationID))
    } }
    public var fingerprint: V2OperationFingerprint { get throws {
        try messageMutationFingerprint(identity: identity, revision: expectedMessageRevision,
            text: text, deadline: firstSubmissionDeadlineMilliseconds)
    } }
    public init(command: V2EditMessageCommand, firstSubmissionDeadlineMilliseconds: UInt64) throws {
        try validateMessageOperationDeadline(firstSubmissionDeadlineMilliseconds)
        roomID=command.roomID; actorUserID=command.actorUserID; operationID=command.operationID
        messageID=command.messageID; expectedMessageRevision=command.expectedMessageRevision; text=command.text
        self.firstSubmissionDeadlineMilliseconds=firstSubmissionDeadlineMilliseconds
        _ = try identity
    }
    public func domainCommand(maximumUTF8Bytes: Int) throws -> V2EditMessageCommand {
        try .init(roomID:roomID,actorUserID:actorUserID,operationID:operationID,messageID:messageID,
            expectedMessageRevision:expectedMessageRevision,text:text,maximumUTF8Bytes:maximumUTF8Bytes)
    }
    private enum CodingKeys:String,CodingKey { case roomID,actorUserID,operationID,messageID,expectedMessageRevision,text,firstSubmissionDeadlineMilliseconds }
    public init(from decoder:any Decoder) throws {
        let v=try decoder.container(keyedBy:CodingKeys.self)
        let text=try v.decode(String.self,forKey:.text)
        let command=try V2EditMessageCommand(roomID:v.decode(RoomID.self,forKey:.roomID),actorUserID:v.decode(UserID.self,forKey:.actorUserID),operationID:v.decode(MessageEditOperationID.self,forKey:.operationID),messageID:v.decode(MessageID.self,forKey:.messageID),expectedMessageRevision:v.decode(UInt64.self,forKey:.expectedMessageRevision),text:text,maximumUTF8Bytes:1_048_576)
        try self.init(command:command,firstSubmissionDeadlineMilliseconds:v.decode(UInt64.self,forKey:.firstSubmissionDeadlineMilliseconds))
    }
}
public struct V2MessageWithdrawalOperationCommand: Equatable,Codable,Sendable {
    public let roomID:RoomID
    public let actorUserID:UserID
    public let operationID:MessageWithdrawalOperationID
    public let messageID:MessageID
    public let expectedMessageRevision:UInt64
    public let firstSubmissionDeadlineMilliseconds:UInt64
    public var identity:V2OperationIdentity { get throws { try .init(accountID:actorUserID,scope:.message(roomID,messageID),operation:.withdrawMessage(operationID)) } }
    public var fingerprint:V2OperationFingerprint { get throws { try messageMutationFingerprint(identity:identity,revision:expectedMessageRevision,text:nil,deadline:firstSubmissionDeadlineMilliseconds) } }
    public init(command:V2WithdrawMessageCommand,firstSubmissionDeadlineMilliseconds:UInt64) throws {
        try validateMessageOperationDeadline(firstSubmissionDeadlineMilliseconds)
        roomID=command.roomID;actorUserID=command.actorUserID;operationID=command.operationID;messageID=command.messageID
        expectedMessageRevision=command.expectedMessageRevision;self.firstSubmissionDeadlineMilliseconds=firstSubmissionDeadlineMilliseconds
        _ = try identity
    }
    public func domainCommand() throws -> V2WithdrawMessageCommand { try .init(roomID:roomID,actorUserID:actorUserID,operationID:operationID,messageID:messageID,expectedMessageRevision:expectedMessageRevision) }
    private enum CodingKeys:String,CodingKey { case roomID,actorUserID,operationID,messageID,expectedMessageRevision,firstSubmissionDeadlineMilliseconds }
    public init(from decoder:any Decoder) throws {
        let v=try decoder.container(keyedBy:CodingKeys.self)
        let command=try V2WithdrawMessageCommand(roomID:v.decode(RoomID.self,forKey:.roomID),actorUserID:v.decode(UserID.self,forKey:.actorUserID),operationID:v.decode(MessageWithdrawalOperationID.self,forKey:.operationID),messageID:v.decode(MessageID.self,forKey:.messageID),expectedMessageRevision:v.decode(UInt64.self,forKey:.expectedMessageRevision))
        try self.init(command:command,firstSubmissionDeadlineMilliseconds:v.decode(UInt64.self,forKey:.firstSubmissionDeadlineMilliseconds))
    }
}

/// Minimal historical evidence, never a lease to display an old message body.
public struct V2MessageMutationCommit:Equatable,Codable,Sendable {
    public let messageID:MessageID
    public let messageRevision:UInt64
    public let roomSequence:UInt64
    public let eventID:EventID
    public init(messageID:MessageID,messageRevision:UInt64,roomSequence:UInt64,eventID:EventID) throws {
        guard messageRevision>0,messageRevision<=UInt64(Int64.max),roomSequence>0,roomSequence<=UInt64(Int64.max) else { throw V2MessageOperationValidationError.invalidReceipt }
        self.messageID=messageID;self.messageRevision=messageRevision;self.roomSequence=roomSequence;self.eventID=eventID
    }
    private enum CodingKeys:String,CodingKey { case messageID,messageRevision,roomSequence,eventID }
    public init(from decoder:any Decoder) throws {
        let v=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(messageID:v.decode(MessageID.self,forKey:.messageID),messageRevision:v.decode(UInt64.self,forKey:.messageRevision),roomSequence:v.decode(UInt64.self,forKey:.roomSequence),eventID:v.decode(EventID.self,forKey:.eventID))
    }
}
public enum V2MessageMutationRejection:Equatable,Codable,Sendable {
    case expiredUnsubmitted,permissionDenied,roomNotFound,messageNotFound,alreadyWithdrawn
    case revisionConflict(current:UInt64)
}
public enum V2MessageMutationTerminalOutcome:Equatable,Codable,Sendable {
    case committed(V2MessageMutationCommit),rejected(V2MessageMutationRejection),closed
}
public struct V2MessageMutationReceipt:Equatable,Codable,Sendable {
    public let identity:V2OperationIdentity
    public let fingerprint:V2OperationFingerprint
    public let outcome:V2MessageMutationTerminalOutcome
    public let resolvedAtMilliseconds:UInt64
    public init(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,outcome:V2MessageMutationTerminalOutcome,resolvedAtMilliseconds:UInt64) throws {
        guard identity.kind == .editMessage || identity.kind == .withdrawMessage,
            case .message(_,let target)=identity.scope,
            resolvedAtMilliseconds>0,resolvedAtMilliseconds<=UInt64(Int64.max) else { throw V2MessageOperationValidationError.invalidReceipt }
        if case .committed(let result)=outcome, result.messageID != target { throw V2MessageOperationValidationError.invalidReceipt }
        if case .rejected(.revisionConflict(let revision))=outcome, revision==0 || revision>UInt64(Int64.max) { throw V2MessageOperationValidationError.invalidReceipt }
        self.identity=identity;self.fingerprint=fingerprint;self.outcome=outcome;self.resolvedAtMilliseconds=resolvedAtMilliseconds
    }
    public func validates(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint)->Bool { self.identity==identity && self.fingerprint==fingerprint }
    private enum CodingKeys:String,CodingKey { case identity,fingerprint,outcome,resolvedAtMilliseconds }
    public init(from decoder:any Decoder) throws {
        let v=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(identity:v.decode(V2OperationIdentity.self,forKey:.identity),fingerprint:v.decode(V2OperationFingerprint.self,forKey:.fingerprint),outcome:v.decode(V2MessageMutationTerminalOutcome.self,forKey:.outcome),resolvedAtMilliseconds:v.decode(UInt64.self,forKey:.resolvedAtMilliseconds))
    }
}
public struct V2MessageMutationRecoveryRequest:Equatable,Codable,Sendable {
    public let identity:V2OperationIdentity
    public let fingerprint:V2OperationFingerprint
    public let action:V2OperationRecoveryRequest.Action
    public init(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,action:V2OperationRecoveryRequest.Action) throws {
        guard identity.kind == .editMessage || identity.kind == .withdrawMessage else { throw V2MessageOperationValidationError.invalidKind }
        self.identity=identity;self.fingerprint=fingerprint;self.action=action
    }
    private enum CodingKeys:String,CodingKey { case identity,fingerprint,action }
    public init(from decoder:any Decoder) throws {
        let v=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(identity:v.decode(V2OperationIdentity.self,forKey:.identity),fingerprint:v.decode(V2OperationFingerprint.self,forKey:.fingerprint),action:v.decode(V2OperationRecoveryRequest.Action.self,forKey:.action))
    }
}
public enum V2MessageMutationRecoveryResult:Equatable,Codable,Sendable {
    case deferred(V2MessageOperationRetryHint)
    case receipt(V2MessageMutationReceipt),unresolved,fingerprintConflict
}
func validateMessageOperationDeadline(_ value:UInt64) throws {
    guard value>0,value<=UInt64(Int64.max) else { throw V2MessageOperationValidationError.invalidDeadline }
}
private func messageMutationFingerprint(identity:V2OperationIdentity,revision:UInt64,text:String?,deadline:UInt64) throws -> V2OperationFingerprint {
    try .init(kind:identity.kind,fields:[.init("identity",.text(identity.storageKey)),.init("expectedRevision",.unsigned(revision)),.init("text",text.map { .text($0) } ?? .absent),.init("firstSubmissionDeadline",.unsigned(deadline))])
}

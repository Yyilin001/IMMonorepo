import Foundation

/// Domain v3 still binds the immutable message content. Public v1 binds execution admission.
public struct V2MessageSendOperationCommand:Equatable,Codable,Sendable {
    public let command:V2SendMessageCommand
    public let firstSubmissionDeadlineMilliseconds:UInt64
    public var identity:V2OperationIdentity { get throws { try .init(accountID:command.senderUserID,scope:.room(command.roomID),operation:.sendMessage(command.clientMessageID)) } }
    public var fingerprint:V2OperationFingerprint { get throws {
        try .init(kind:.sendMessage,fields:[.init("identity",.text(identity.storageKey)),.init("domainFingerprintVersion",.unsigned(UInt64(command.fingerprint.version))),.init("domainFingerprint",.bytes(command.fingerprint.digest)),.init("firstSubmissionDeadline",.unsigned(firstSubmissionDeadlineMilliseconds))])
    } }
    public init(command:V2SendMessageCommand,firstSubmissionDeadlineMilliseconds:UInt64) throws {
        try validateMessageOperationDeadline(firstSubmissionDeadlineMilliseconds)
        guard command.forwardedFrom==nil else { throw V2MessageOperationValidationError.invalidKind }
        self.command=command;self.firstSubmissionDeadlineMilliseconds=firstSubmissionDeadlineMilliseconds
        _ = try identity
    }
    private enum CodingKeys:String,CodingKey { case command,firstSubmissionDeadlineMilliseconds }
    public init(from decoder:any Decoder) throws {
        let v=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(command:v.decode(V2SendMessageCommand.self,forKey:.command),firstSubmissionDeadlineMilliseconds:v.decode(UInt64.self,forKey:.firstSubmissionDeadlineMilliseconds))
    }
}
public enum V2MessageSendOperationRejection:String,Equatable,Codable,Sendable {
    case expiredUnsubmitted,permissionDenied,roomNotFound,invalidContent,directPolicyDenied
}
public enum V2MessageSendOperationTerminalOutcome:Equatable,Codable,Sendable {
    /// Acceptance is not delivery, reading, or moderation approval.
    case accepted(V2MessageOperationAcceptance)
    case rejected(V2MessageSendOperationRejection)
}
public struct V2MessageSendOperationReceipt:Equatable,Codable,Sendable {
    public let identity:V2OperationIdentity
    public let fingerprint:V2OperationFingerprint
    public let outcome:V2MessageSendOperationTerminalOutcome
    public let resolvedAtMilliseconds:UInt64
    public init(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,outcome:V2MessageSendOperationTerminalOutcome,resolvedAtMilliseconds:UInt64) throws {
        guard identity.kind == .sendMessage,resolvedAtMilliseconds>0,resolvedAtMilliseconds<=UInt64(Int64.max) else { throw V2MessageOperationValidationError.invalidReceipt }
        self.identity=identity;self.fingerprint=fingerprint;self.outcome=outcome;self.resolvedAtMilliseconds=resolvedAtMilliseconds
    }
    public func validates(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint)->Bool { self.identity==identity && self.fingerprint==fingerprint }
    private enum CodingKeys:String,CodingKey { case identity,fingerprint,outcome,resolvedAtMilliseconds }
    public init(from decoder:any Decoder) throws {
        let v=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(identity:v.decode(V2OperationIdentity.self,forKey:.identity),fingerprint:v.decode(V2OperationFingerprint.self,forKey:.fingerprint),outcome:v.decode(V2MessageSendOperationTerminalOutcome.self,forKey:.outcome),resolvedAtMilliseconds:v.decode(UInt64.self,forKey:.resolvedAtMilliseconds))
    }
}
public struct V2MessageSendOperationRecoveryRequest:Equatable,Codable,Sendable {
    public let identity:V2OperationIdentity
    public let fingerprint:V2OperationFingerprint
    public let domainFingerprint:V2SendMessageFingerprint
    public init(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,domainFingerprint:V2SendMessageFingerprint) throws {
        guard identity.kind == .sendMessage else { throw V2MessageOperationValidationError.invalidKind }
        self.identity=identity;self.fingerprint=fingerprint;self.domainFingerprint=domainFingerprint
    }
    private enum CodingKeys:String,CodingKey { case identity,fingerprint,domainFingerprint }
    public init(from decoder:any Decoder) throws {
        let v=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(identity:v.decode(V2OperationIdentity.self,forKey:.identity),fingerprint:v.decode(V2OperationFingerprint.self,forKey:.fingerprint),domainFingerprint:v.decode(V2SendMessageFingerprint.self,forKey:.domainFingerprint))
    }
}
public enum V2MessageSendOperationRecoveryResult:Equatable,Codable,Sendable {
    case deferred(V2MessageOperationRetryHint)
    case receipt(V2MessageSendOperationReceipt),unresolved,fingerprintConflict
}

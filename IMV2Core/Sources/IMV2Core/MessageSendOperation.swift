import Foundation

/// Domain v3 still binds the immutable message content. Public v1 binds execution admission.
public struct V2MessageSendOperationCommand:Equatable,Codable,Sendable {
    public let command:V2SendMessageCommand
    public let firstSubmissionDeadlineMilliseconds:UInt64
    private let preparedIdentity: V2OperationIdentity
    private let preparedFingerprint: V2OperationFingerprint
    /// Conservative admission estimate for owned command fields and container overhead.
    /// This is a memory budget, not the JSON or protobuf wire size.
    public let estimatedRetainedBytes: Int
    public var identity:V2OperationIdentity { get throws { preparedIdentity } }
    public var fingerprint:V2OperationFingerprint { get throws { preparedFingerprint } }
    public init(command:V2SendMessageCommand,firstSubmissionDeadlineMilliseconds:UInt64) throws {
        try validateMessageOperationDeadline(firstSubmissionDeadlineMilliseconds)
        guard command.forwardedFrom==nil else { throw V2MessageOperationValidationError.invalidKind }
        self.command=command;self.firstSubmissionDeadlineMilliseconds=firstSubmissionDeadlineMilliseconds
        let identity = try V2OperationIdentity(accountID: command.senderUserID, scope: .room(command.roomID), operation: .sendMessage(command.clientMessageID))
        self.preparedIdentity = identity
        self.preparedFingerprint = V2OperationFingerprint(messageSendIdentity: identity.storageKey,
            domain: command.fingerprint, deadline: firstSubmissionDeadlineMilliseconds)
        var budget = 512 + MemoryLayout<V2MessageSendOperationCommand>.stride
        func string(_ value: String) {
            // Allow for UTF-8/UTF-16 storage and per-string allocation overhead.
            let (size, overflow) = value.utf8.count.multipliedReportingOverflow(by: 2)
            let (withOverhead, overheadOverflow) = size.addingReportingOverflow(64)
            let (sum, sumOverflow) = budget.addingReportingOverflow(withOverhead)
            budget = overflow || overheadOverflow || sumOverflow ? Int.max : sum
        }
        string(command.roomID.rawValue); string(command.senderUserID.rawValue)
        string(command.clientMessageID.rawValue); string(command.text)
        for media in command.media { string(media.mediaID.rawValue) }
        for mention in command.mentions {
            if case .user(let user) = mention { string(user.rawValue) }
            else { string("") }
        }
        for entity in command.entities { string(entity.linkURL?.absoluteString ?? "") }
        if let reply = command.replyTo { string(reply.messageID.rawValue) }
        let containers = command.media.count * MemoryLayout<V2MediaReference>.stride
            + command.mentions.count * MemoryLayout<V2MentionTarget>.stride
            + command.entities.count * MemoryLayout<V2MessageEntity>.stride
        let (total, overflow) = budget.addingReportingOverflow(containers)
        self.estimatedRetainedBytes = overflow ? Int.max : total
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

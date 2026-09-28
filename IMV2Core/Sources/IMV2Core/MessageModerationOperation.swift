import Foundation

public enum V2MessageModerationValidationError:Error,Equatable,Sendable { case invalidIntent,invalidAdmission,invalidReceipt }
public enum V2MessageModerationAdmissionTag:V2IdentifierTag {}
public typealias V2MessageModerationAdmissionID=V2Identifier<V2MessageModerationAdmissionTag>

/// Human confirmation binds both the observed message and membership state.
public struct V2MessageModerationIntent:Codable,Equatable,Sendable {
    public let roomID:RoomID
    public let actorUserID:UserID
    public let operationID:ModerationOperationID
    public let messageID:MessageID
    public let reasonCode:V2ModerationReasonCode
    public let expectedMessageRevision:UInt64
    public let expectedMembershipRevision:UInt64
    public let confirmedUntilMilliseconds:UInt64
    public init(roomID:RoomID,actorUserID:UserID,operationID:ModerationOperationID,messageID:MessageID,reasonCode:V2ModerationReasonCode,expectedMessageRevision:UInt64,expectedMembershipRevision:UInt64,confirmedUntilMilliseconds:UInt64) throws {
        guard roomID.uuidValue != nil,actorUserID.uuidValue != nil,operationID.uuidValue != nil,messageID.uuidValue != nil,
              expectedMessageRevision>0,expectedMessageRevision<UInt64(Int64.max),expectedMembershipRevision<UInt64(Int64.max),
              confirmedUntilMilliseconds>0,confirmedUntilMilliseconds<=UInt64(Int64.max) else { throw V2MessageModerationValidationError.invalidIntent }
        self.roomID=roomID;self.actorUserID=actorUserID;self.operationID=operationID;self.messageID=messageID
        self.reasonCode=try .init(reasonCode.rawValue);self.expectedMessageRevision=expectedMessageRevision
        self.expectedMembershipRevision=expectedMembershipRevision;self.confirmedUntilMilliseconds=confirmedUntilMilliseconds
    }
    public var identity:V2OperationIdentity { get throws { try .init(accountID:actorUserID,scope:.room(roomID),operation:.moderation(operationID)) } }
    public var fingerprint:V2OperationFingerprint { get throws {
        try .init(kind:.moderation,fields:[.init("identity",.text(identity.storageKey)),.init("message",.text(messageID.rawValue)),
            .init("action",.text("redactMessage")),.init("reason",.text(reasonCode.rawValue)),
            .init("messageRevision",.unsigned(expectedMessageRevision)),.init("membershipRevision",.unsigned(expectedMembershipRevision)),
            .init("confirmedUntil",.unsigned(confirmedUntilMilliseconds))])
    } }
    private enum CodingKeys:CodingKey { case roomID,actorUserID,operationID,messageID,reasonCode,expectedMessageRevision,expectedMembershipRevision,confirmedUntilMilliseconds }
    public init(from decoder:any Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(roomID:c.decode(RoomID.self,forKey:.roomID),actorUserID:c.decode(UserID.self,forKey:.actorUserID),operationID:c.decode(ModerationOperationID.self,forKey:.operationID),messageID:c.decode(MessageID.self,forKey:.messageID),reasonCode:c.decode(V2ModerationReasonCode.self,forKey:.reasonCode),expectedMessageRevision:c.decode(UInt64.self,forKey:.expectedMessageRevision),expectedMembershipRevision:c.decode(UInt64.self,forKey:.expectedMembershipRevision),confirmedUntilMilliseconds:c.decode(UInt64.self,forKey:.confirmedUntilMilliseconds))
    }
}

/// A gate credential, not a replacement for current owner authorization at commit.
public struct V2MessageModerationAdmission:Codable,Equatable,Sendable {
    public let id:V2MessageModerationAdmissionID
    public let identity:V2OperationIdentity
    public let intentFingerprint:V2OperationFingerprint
    public let actorJoinedRevision:UInt64
    public let issuedAtMilliseconds:UInt64
    public let expiresAtMilliseconds:UInt64
    public init(id:V2MessageModerationAdmissionID,identity:V2OperationIdentity,intentFingerprint:V2OperationFingerprint,actorJoinedRevision:UInt64,issuedAtMilliseconds:UInt64,expiresAtMilliseconds:UInt64) throws {
        guard id.uuidValue != nil,identity.kind == .moderation,case .room=identity.scope,
              actorJoinedRevision<=UInt64(Int64.max),issuedAtMilliseconds>0,expiresAtMilliseconds>issuedAtMilliseconds,
              expiresAtMilliseconds<=UInt64(Int64.max),expiresAtMilliseconds-issuedAtMilliseconds<=120_000 else { throw V2MessageModerationValidationError.invalidAdmission }
        self.id=id;self.identity=identity;self.intentFingerprint=intentFingerprint;self.actorJoinedRevision=actorJoinedRevision
        self.issuedAtMilliseconds=issuedAtMilliseconds;self.expiresAtMilliseconds=expiresAtMilliseconds
    }
    public func validates(intent:V2MessageModerationIntent)->Bool {
        identity==(try? intent.identity) && intentFingerprint==(try? intent.fingerprint)
            && actorJoinedRevision<=intent.expectedMembershipRevision && expiresAtMilliseconds<=intent.confirmedUntilMilliseconds
    }
    private enum CodingKeys:CodingKey { case id,identity,intentFingerprint,actorJoinedRevision,issuedAtMilliseconds,expiresAtMilliseconds }
    public init(from decoder:any Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(id:c.decode(V2MessageModerationAdmissionID.self,forKey:.id),identity:c.decode(V2OperationIdentity.self,forKey:.identity),intentFingerprint:c.decode(V2OperationFingerprint.self,forKey:.intentFingerprint),actorJoinedRevision:c.decode(UInt64.self,forKey:.actorJoinedRevision),issuedAtMilliseconds:c.decode(UInt64.self,forKey:.issuedAtMilliseconds),expiresAtMilliseconds:c.decode(UInt64.self,forKey:.expiresAtMilliseconds))
    }
}
public struct V2MessageModerationCommand:Codable,Equatable,Sendable {
    public let intent:V2MessageModerationIntent
    public let admission:V2MessageModerationAdmission
    public init(intent:V2MessageModerationIntent,admission:V2MessageModerationAdmission) throws {
        guard admission.validates(intent:intent) else { throw V2MessageModerationValidationError.invalidAdmission }
        self.intent=intent;self.admission=admission
    }
    public var identity:V2OperationIdentity { get throws { try intent.identity } }
    /// Admission loss cannot change the original operation's semantic identity.
    public var fingerprint:V2OperationFingerprint { get throws { try intent.fingerprint } }
    private enum CodingKeys:CodingKey { case intent,admission }
    public init(from decoder:any Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(intent:c.decode(V2MessageModerationIntent.self,forKey:.intent),admission:c.decode(V2MessageModerationAdmission.self,forKey:.admission))
    }
}
public enum V2MessageModerationRejection:Codable,Equatable,Sendable {
    case confirmationExpired,invalidConfirmationDeadline,admissionExpired,invalidAdmission,permissionDenied,roomNotFound,messageNotFound
    case membershipChanged(currentRevision:UInt64),messageChanged(currentRevision:UInt64)
}
public enum V2MessageModerationTerminalOutcome:Codable,Equatable,Sendable {
    case redacted(messageID:MessageID,messageRevision:UInt64,roomSequence:UInt64,eventID:EventID)
    case alreadySatisfied(messageID:MessageID,messageRevision:UInt64)
    case rejected(V2MessageModerationRejection),closed
}
public struct V2MessageModerationReceipt:Codable,Equatable,Sendable {
    public let identity:V2OperationIdentity
    public let fingerprint:V2OperationFingerprint
    public let outcome:V2MessageModerationTerminalOutcome
    public let resolvedAtMilliseconds:UInt64
    public init(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,outcome:V2MessageModerationTerminalOutcome,resolvedAtMilliseconds:UInt64) throws {
        guard identity.kind == .moderation,case .room=identity.scope,resolvedAtMilliseconds>0,resolvedAtMilliseconds<=UInt64(Int64.max) else { throw V2MessageModerationValidationError.invalidReceipt }
        switch outcome {
        case .redacted(let message,let revision,let sequence,let event):
            guard message.uuidValue != nil,event.uuidValue != nil,revision>0,revision<=UInt64(Int64.max),sequence>0,sequence<=UInt64(Int64.max) else { throw V2MessageModerationValidationError.invalidReceipt }
        case .alreadySatisfied(let message,let revision):
            guard message.uuidValue != nil,revision>0,revision<=UInt64(Int64.max) else { throw V2MessageModerationValidationError.invalidReceipt }
        case .rejected(.membershipChanged(let revision)):
            guard revision<=UInt64(Int64.max) else { throw V2MessageModerationValidationError.invalidReceipt }
        case .rejected(.messageChanged(let revision)):
            guard revision>0,revision<=UInt64(Int64.max) else { throw V2MessageModerationValidationError.invalidReceipt }
        default:break
        }
        self.identity=identity;self.fingerprint=fingerprint;self.outcome=outcome;self.resolvedAtMilliseconds=resolvedAtMilliseconds
    }
    public func validates(intent:V2MessageModerationIntent)->Bool {
        guard identity==(try? intent.identity),fingerprint==(try? intent.fingerprint) else { return false }
        switch outcome {
        case .redacted(let message,let revision,_,_):return message==intent.messageID && revision==intent.expectedMessageRevision+1
        case .alreadySatisfied(let message,let revision):return message==intent.messageID && revision==intent.expectedMessageRevision
        default:return true
        }
    }
    private enum CodingKeys:CodingKey { case identity,fingerprint,outcome,resolvedAtMilliseconds }
    public init(from decoder:any Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(identity:c.decode(V2OperationIdentity.self,forKey:.identity),fingerprint:c.decode(V2OperationFingerprint.self,forKey:.fingerprint),outcome:c.decode(V2MessageModerationTerminalOutcome.self,forKey:.outcome),resolvedAtMilliseconds:c.decode(UInt64.self,forKey:.resolvedAtMilliseconds))
    }
}
public enum V2MessageModerationAdmissionResult:Codable,Equatable,Sendable {
    case admitted(V2MessageModerationAdmission),currentUnavailable(V2MessageModerationRejection),terminal(V2MessageModerationReceipt),fingerprintConflict
}
public struct V2MessageModerationRecoveryRequest:Codable,Equatable,Sendable {
    public let intent:V2MessageModerationIntent
    public let action:V2OperationRecoveryRequest.Action
    public init(intent:V2MessageModerationIntent,action:V2OperationRecoveryRequest.Action) { self.intent=intent;self.action=action }
}
public enum V2MessageModerationRecoveryResult:Codable,Equatable,Sendable {
    case receipt(V2MessageModerationReceipt),deferred(V2MessageOperationRetryHint),unresolved,fingerprintConflict
}
public struct V2MessageModerationBaseline:Codable,Equatable,Sendable {
    public let roomID:RoomID
    public let messageID:MessageID
    public let messageRevision:UInt64
    public let membershipRevision:UInt64
    public let isRedacted:Bool
    public init(roomID:RoomID,messageID:MessageID,messageRevision:UInt64,membershipRevision:UInt64,isRedacted:Bool) throws {
        guard roomID.uuidValue != nil,messageID.uuidValue != nil,messageRevision>0,messageRevision<UInt64(Int64.max),membershipRevision<UInt64(Int64.max) else { throw V2MessageModerationValidationError.invalidIntent }
        self.roomID=roomID;self.messageID=messageID;self.messageRevision=messageRevision;self.membershipRevision=membershipRevision;self.isRedacted=isRedacted
    }
    private enum CodingKeys:CodingKey { case roomID,messageID,messageRevision,membershipRevision,isRedacted }
    public init(from decoder:any Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(roomID:c.decode(RoomID.self,forKey:.roomID),messageID:c.decode(MessageID.self,forKey:.messageID),messageRevision:c.decode(UInt64.self,forKey:.messageRevision),membershipRevision:c.decode(UInt64.self,forKey:.membershipRevision),isRedacted:c.decode(Bool.self,forKey:.isRedacted))
    }
}

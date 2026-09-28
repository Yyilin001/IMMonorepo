import Foundation

public enum V2MemberAdministrationValidationError:Error,Equatable,Sendable { case invalidIntent,invalidAdmission,invalidReceipt }
public enum V2MemberAdministrationAdmissionTag:V2IdentifierTag {}
public typealias V2MemberAdministrationAdmissionID=V2Identifier<V2MemberAdministrationAdmissionTag>
public enum V2MemberAdministrationAction:Codable,Equatable,Sendable {
    case mute(untilMilliseconds:UInt64)
    case remove
}
/// The user's observed revision and original confirmation deadline never rebase in preparation.
public struct V2MemberAdministrationIntent:Codable,Equatable,Sendable {
    public let roomID:RoomID
    public let actorUserID:UserID
    public let operationID:ModerationOperationID
    public let targetUserID:UserID
    public let action:V2MemberAdministrationAction
    public let reasonCode:V2ModerationReasonCode
    public let expectedMembershipRevision:UInt64
    public let confirmedUntilMilliseconds:UInt64
    public init(roomID:RoomID,actorUserID:UserID,operationID:ModerationOperationID,targetUserID:UserID,
                action:V2MemberAdministrationAction,reasonCode:V2ModerationReasonCode,
                expectedMembershipRevision:UInt64,confirmedUntilMilliseconds:UInt64) throws {
        guard actorUserID != targetUserID,expectedMembershipRevision<UInt64(Int64.max),
              confirmedUntilMilliseconds>0,confirmedUntilMilliseconds<=UInt64(Int64.max) else { throw V2MemberAdministrationValidationError.invalidIntent }
        if case .mute(let until)=action { guard until>0,until<=UInt64(Int64.max) else { throw V2MemberAdministrationValidationError.invalidIntent } }
        self.roomID=roomID;self.actorUserID=actorUserID;self.operationID=operationID;self.targetUserID=targetUserID;self.action=action
        self.reasonCode=try .init(reasonCode.rawValue);self.expectedMembershipRevision=expectedMembershipRevision;self.confirmedUntilMilliseconds=confirmedUntilMilliseconds
    }
    public var identity:V2OperationIdentity { get throws {
        try .init(accountID:actorUserID,scope:.room(roomID),operation:kind == .memberMute ? .memberMute(operationID):.moderatedMemberRemoval(operationID))
    } }
    public var kind:V2OperationKind { if case .mute=action { return .memberMute };return .moderatedMemberRemoval }
    public var fingerprint:V2OperationFingerprint { get throws {
        let actionName:String,until:UInt64
        switch action { case .mute(let value):actionName="mute";until=value;case .remove:actionName="remove";until=0 }
        return try .init(kind:kind,fields:[.init("identity",.text(identity.storageKey)),.init("target",.text(targetUserID.rawValue)),
            .init("action",.text(actionName)),.init("muteUntil",.unsigned(until)),.init("reason",.text(reasonCode.rawValue)),
            .init("expectedMembershipRevision",.unsigned(expectedMembershipRevision)),.init("confirmedUntil",.unsigned(confirmedUntilMilliseconds))])
    } }
    private enum CodingKeys:String,CodingKey { case roomID,actorUserID,operationID,targetUserID,action,reasonCode,expectedMembershipRevision,confirmedUntilMilliseconds }
    public init(from decoder:any Decoder) throws {
        let v=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(roomID:v.decode(RoomID.self,forKey:.roomID),actorUserID:v.decode(UserID.self,forKey:.actorUserID),operationID:v.decode(ModerationOperationID.self,forKey:.operationID),targetUserID:v.decode(UserID.self,forKey:.targetUserID),action:v.decode(V2MemberAdministrationAction.self,forKey:.action),reasonCode:v.decode(V2ModerationReasonCode.self,forKey:.reasonCode),expectedMembershipRevision:v.decode(UInt64.self,forKey:.expectedMembershipRevision),confirmedUntilMilliseconds:v.decode(UInt64.self,forKey:.confirmedUntilMilliseconds))
    }
}

/// An owner-issued context, not a promise that permission remains valid at submission.
public struct V2MemberAdministrationAdmission:Codable,Equatable,Sendable {
    public let id:V2MemberAdministrationAdmissionID
    public let identity:V2OperationIdentity
    public let intentFingerprint:V2OperationFingerprint
    public let membershipRevision:UInt64
    public let targetJoinedRevision:UInt64
    public let issuedAtMilliseconds:UInt64
    public let expiresAtMilliseconds:UInt64
    public init(id:V2MemberAdministrationAdmissionID,identity:V2OperationIdentity,intentFingerprint:V2OperationFingerprint,
                membershipRevision:UInt64,targetJoinedRevision:UInt64,issuedAtMilliseconds:UInt64,expiresAtMilliseconds:UInt64) throws {
        guard [.memberMute,.moderatedMemberRemoval].contains(identity.kind),case .room=identity.scope,id.uuidValue != nil,
              membershipRevision<UInt64(Int64.max),targetJoinedRevision<=membershipRevision,
              issuedAtMilliseconds>0,expiresAtMilliseconds>issuedAtMilliseconds,expiresAtMilliseconds<=UInt64(Int64.max),
              expiresAtMilliseconds-issuedAtMilliseconds<=120_000 else { throw V2MemberAdministrationValidationError.invalidAdmission }
        self.id=id;self.identity=identity;self.intentFingerprint=intentFingerprint;self.membershipRevision=membershipRevision
        self.targetJoinedRevision=targetJoinedRevision;self.issuedAtMilliseconds=issuedAtMilliseconds;self.expiresAtMilliseconds=expiresAtMilliseconds
    }
    public func validates(intent:V2MemberAdministrationIntent)->Bool {
        identity == (try? intent.identity) && intentFingerprint == (try? intent.fingerprint) && membershipRevision==intent.expectedMembershipRevision && expiresAtMilliseconds<=intent.confirmedUntilMilliseconds
    }
    private enum CodingKeys:String,CodingKey { case id,identity,intentFingerprint,membershipRevision,targetJoinedRevision,issuedAtMilliseconds,expiresAtMilliseconds }
    public init(from decoder:any Decoder) throws {
        let v=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(id:v.decode(V2MemberAdministrationAdmissionID.self,forKey:.id),identity:v.decode(V2OperationIdentity.self,forKey:.identity),intentFingerprint:v.decode(V2OperationFingerprint.self,forKey:.intentFingerprint),membershipRevision:v.decode(UInt64.self,forKey:.membershipRevision),targetJoinedRevision:v.decode(UInt64.self,forKey:.targetJoinedRevision),issuedAtMilliseconds:v.decode(UInt64.self,forKey:.issuedAtMilliseconds),expiresAtMilliseconds:v.decode(UInt64.self,forKey:.expiresAtMilliseconds))
    }
}
public enum V2MemberAdministrationAdmissionUnavailable:Codable,Equatable,Sendable {
    case confirmationExpired,invalidConfirmationDeadline,permissionDenied,roomNotFound,targetNotMember
    case membershipChanged(currentRevision:UInt64)
}
public enum V2MemberAdministrationAdmissionResult:Codable,Equatable,Sendable {
    case admitted(V2MemberAdministrationAdmission)
    case currentUnavailable(V2MemberAdministrationAdmissionUnavailable)
    case fingerprintConflict
}
public struct V2MemberAdministrationCommand:Codable,Equatable,Sendable {
    public let intent:V2MemberAdministrationIntent
    public let admission:V2MemberAdministrationAdmission
    public init(intent:V2MemberAdministrationIntent,admission:V2MemberAdministrationAdmission) throws {
        guard admission.validates(intent:intent) else { throw V2MemberAdministrationValidationError.invalidAdmission }
        self.intent=intent;self.admission=admission
    }
    public var identity:V2OperationIdentity { get throws { try intent.identity } }
    public var fingerprint:V2OperationFingerprint { get throws {
        try .init(kind:intent.kind,fields:[.init("intent",.bytes(intent.fingerprint.digest)),.init("admissionID",.text(admission.id.rawValue)),
            .init("membershipRevision",.unsigned(admission.membershipRevision)),.init("targetJoinedRevision",.unsigned(admission.targetJoinedRevision)),
            .init("issuedAt",.unsigned(admission.issuedAtMilliseconds)),.init("expiresAt",.unsigned(admission.expiresAtMilliseconds))])
    } }
    private enum CodingKeys:String,CodingKey { case intent,admission }
    public init(from decoder:any Decoder) throws {
        let v=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(intent:v.decode(V2MemberAdministrationIntent.self,forKey:.intent),admission:v.decode(V2MemberAdministrationAdmission.self,forKey:.admission))
    }
}
public enum V2MemberAdministrationApplied:Codable,Equatable,Sendable {
    case muted(untilMilliseconds:UInt64,membershipRevision:UInt64,roomSequence:UInt64,eventID:EventID)
    case removed(membershipRevision:UInt64,roomSequence:UInt64,eventID:EventID)
}
public enum V2MemberAdministrationRejection:Codable,Equatable,Sendable {
    case admissionExpired,invalidAdmission,permissionDenied,roomNotFound,targetNotMember,invalidMuteExpiry
    case membershipChanged(currentRevision:UInt64)
}
public enum V2MemberAdministrationTerminalOutcome:Codable,Equatable,Sendable {
    case applied(V2MemberAdministrationApplied),rejected(V2MemberAdministrationRejection),closed
    case alreadySatisfied(muteUntilMilliseconds:UInt64,membershipRevision:UInt64)
}
public struct V2MemberAdministrationReceipt:Codable,Equatable,Sendable {
    public let identity:V2OperationIdentity
    public let fingerprint:V2OperationFingerprint
    public let outcome:V2MemberAdministrationTerminalOutcome
    public let resolvedAtMilliseconds:UInt64
    public init(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,outcome:V2MemberAdministrationTerminalOutcome,resolvedAtMilliseconds:UInt64) throws {
        guard [.memberMute,.moderatedMemberRemoval].contains(identity.kind),case .room=identity.scope,
              resolvedAtMilliseconds>0,resolvedAtMilliseconds<=UInt64(Int64.max) else { throw V2MemberAdministrationValidationError.invalidReceipt }
        switch outcome {
        case .applied(.muted(let until,let revision,let sequence,_)):
            guard identity.kind == .memberMute,until>0,until<=UInt64(Int64.max),revision<=UInt64(Int64.max),sequence>0,sequence<=UInt64(Int64.max) else { throw V2MemberAdministrationValidationError.invalidReceipt }
        case .applied(.removed(let revision,let sequence,_)):
            guard identity.kind == .moderatedMemberRemoval,revision>0,revision<=UInt64(Int64.max),sequence>0,sequence<=UInt64(Int64.max) else { throw V2MemberAdministrationValidationError.invalidReceipt }
        case .rejected(.membershipChanged(let revision)):
            guard revision<=UInt64(Int64.max) else { throw V2MemberAdministrationValidationError.invalidReceipt }
        case .alreadySatisfied(let until,let revision):
            guard identity.kind == .memberMute,until>0,until<=UInt64(Int64.max),revision<=UInt64(Int64.max) else { throw V2MemberAdministrationValidationError.invalidReceipt }
        default:break
        }
        self.identity=identity;self.fingerprint=fingerprint;self.outcome=outcome;self.resolvedAtMilliseconds=resolvedAtMilliseconds
    }
    public func validates(command:V2MemberAdministrationCommand)->Bool {
        guard identity == (try? command.identity),fingerprint == (try? command.fingerprint) else { return false }
        switch outcome {
        case .applied(.muted(let until,let revision,_,_)):
            guard case .mute(let requested)=command.intent.action else { return false }
            return until==requested && revision==command.intent.expectedMembershipRevision
        case .applied(.removed(let revision,_,_)):return command.intent.action == .remove && revision==command.intent.expectedMembershipRevision+1
        case .alreadySatisfied(let until,let revision):
            guard case .mute(let requested)=command.intent.action else { return false }
            return until>=requested && revision==command.intent.expectedMembershipRevision
        default:return true
        }
    }
    private enum CodingKeys:String,CodingKey { case identity,fingerprint,outcome,resolvedAtMilliseconds }
    public init(from decoder:any Decoder) throws {
        let v=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(identity:v.decode(V2OperationIdentity.self,forKey:.identity),fingerprint:v.decode(V2OperationFingerprint.self,forKey:.fingerprint),outcome:v.decode(V2MemberAdministrationTerminalOutcome.self,forKey:.outcome),resolvedAtMilliseconds:v.decode(UInt64.self,forKey:.resolvedAtMilliseconds))
    }
}
public struct V2MemberAdministrationRecoveryRequest:Codable,Equatable,Sendable {
    public let identity:V2OperationIdentity
    public let fingerprint:V2OperationFingerprint
    public let action:V2OperationRecoveryRequest.Action
    public init(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,action:V2OperationRecoveryRequest.Action) throws {
        guard [.memberMute,.moderatedMemberRemoval].contains(identity.kind),case .room=identity.scope else { throw V2MemberAdministrationValidationError.invalidIntent }
        self.identity=identity;self.fingerprint=fingerprint;self.action=action
    }
    private enum CodingKeys:String,CodingKey { case identity,fingerprint,action }
    public init(from decoder:any Decoder) throws {
        let v=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(identity:v.decode(V2OperationIdentity.self,forKey:.identity),fingerprint:v.decode(V2OperationFingerprint.self,forKey:.fingerprint),action:v.decode(V2OperationRecoveryRequest.Action.self,forKey:.action))
    }
}
public enum V2MemberAdministrationRecoveryResult:Codable,Equatable,Sendable {
    case receipt(V2MemberAdministrationReceipt),deferred(V2MessageOperationRetryHint),unresolved,fingerprintConflict
}

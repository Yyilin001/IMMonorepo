import Foundation

public enum V2MembershipOperationValidationError:Error,Equatable,Sendable { case invalidIntent,invalidAdmission,invalidCommand,invalidReceipt }
public enum V2MembershipAdmissionTag:V2IdentifierTag {}
public typealias V2MembershipAdmissionID=V2Identifier<V2MembershipAdmissionTag>

/// One explicit add/remove confirmation. Handle resolution does not renew its deadline.
public struct V2MembershipIntent:Codable,Equatable,Sendable {
    public let roomID:RoomID
    public let actorUserID:UserID
    public let operationID:MembershipOperationID
    public let targetUserID:UserID
    public let action:V2RoomMembershipAction
    public let expectedMembershipRevision:UInt64
    public let confirmedUntilMilliseconds:UInt64
    public init(roomID:RoomID,actorUserID:UserID,operationID:MembershipOperationID,targetUserID:UserID,action:V2RoomMembershipAction,expectedMembershipRevision:UInt64,confirmedUntilMilliseconds:UInt64) throws {
        guard (actorUserID != targetUserID || action == .remove),expectedMembershipRevision<UInt64(Int64.max),confirmedUntilMilliseconds>0,confirmedUntilMilliseconds<=UInt64(Int64.max) else { throw V2MembershipOperationValidationError.invalidIntent }
        self.roomID=roomID;self.actorUserID=actorUserID;self.operationID=operationID;self.targetUserID=targetUserID;self.action=action;self.expectedMembershipRevision=expectedMembershipRevision;self.confirmedUntilMilliseconds=confirmedUntilMilliseconds
    }
    public var identity:V2OperationIdentity { get throws { try .init(accountID:actorUserID,scope:.room(roomID),operation:.membership(operationID)) } }
    public var fingerprint:V2OperationFingerprint { get throws { try .init(kind:.membership,fields:[.init("identity",.text(identity.storageKey)),.init("target",.text(targetUserID.rawValue)),.init("action",.text(action.rawValue)),.init("expectedMembershipRevision",.unsigned(expectedMembershipRevision)),.init("confirmedUntil",.unsigned(confirmedUntilMilliseconds))]) } }
    private enum CodingKeys:String,CodingKey { case roomID,actorUserID,operationID,targetUserID,action,expectedMembershipRevision,confirmedUntilMilliseconds }
    public init(from decoder:any Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(roomID:c.decode(RoomID.self,forKey:.roomID),actorUserID:c.decode(UserID.self,forKey:.actorUserID),operationID:c.decode(MembershipOperationID.self,forKey:.operationID),targetUserID:c.decode(UserID.self,forKey:.targetUserID),action:c.decode(V2RoomMembershipAction.self,forKey:.action),expectedMembershipRevision:c.decode(UInt64.self,forKey:.expectedMembershipRevision),confirmedUntilMilliseconds:c.decode(UInt64.self,forKey:.confirmedUntilMilliseconds))
    }
}

/// Add binds absence; remove binds the precise active membership incarnation.
public struct V2MembershipAdmission:Codable,Equatable,Sendable {
    public let id:V2MembershipAdmissionID
    public let identity:V2OperationIdentity
    public let intentFingerprint:V2OperationFingerprint
    public let action:V2RoomMembershipAction
    public let membershipRevision:UInt64
    public let targetJoinedRevision:UInt64?
    public let issuedAtMilliseconds:UInt64
    public let expiresAtMilliseconds:UInt64
    public init(id:V2MembershipAdmissionID,identity:V2OperationIdentity,intentFingerprint:V2OperationFingerprint,action:V2RoomMembershipAction,membershipRevision:UInt64,targetJoinedRevision:UInt64?,issuedAtMilliseconds:UInt64,expiresAtMilliseconds:UInt64) throws {
        guard identity.kind == .membership,case .room=identity.scope,id.uuidValue != nil,membershipRevision<UInt64(Int64.max),issuedAtMilliseconds>0,expiresAtMilliseconds>issuedAtMilliseconds,expiresAtMilliseconds<=UInt64(Int64.max),expiresAtMilliseconds-issuedAtMilliseconds<=120_000 else { throw V2MembershipOperationValidationError.invalidAdmission }
        switch action {
        case .add:guard targetJoinedRevision == nil else { throw V2MembershipOperationValidationError.invalidAdmission }
        case .remove:guard let joined=targetJoinedRevision,joined<=membershipRevision else { throw V2MembershipOperationValidationError.invalidAdmission }
        }
        self.id=id;self.identity=identity;self.intentFingerprint=intentFingerprint;self.action=action;self.membershipRevision=membershipRevision;self.targetJoinedRevision=targetJoinedRevision;self.issuedAtMilliseconds=issuedAtMilliseconds;self.expiresAtMilliseconds=expiresAtMilliseconds
    }
    public func validates(intent:V2MembershipIntent)->Bool { identity == (try? intent.identity) && intentFingerprint == (try? intent.fingerprint) && action == intent.action && membershipRevision == intent.expectedMembershipRevision && expiresAtMilliseconds<=intent.confirmedUntilMilliseconds }
    private enum CodingKeys:String,CodingKey { case id,identity,intentFingerprint,action,membershipRevision,targetJoinedRevision,issuedAtMilliseconds,expiresAtMilliseconds }
    public init(from decoder:any Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(id:c.decode(V2MembershipAdmissionID.self,forKey:.id),identity:c.decode(V2OperationIdentity.self,forKey:.identity),intentFingerprint:c.decode(V2OperationFingerprint.self,forKey:.intentFingerprint),action:c.decode(V2RoomMembershipAction.self,forKey:.action),membershipRevision:c.decode(UInt64.self,forKey:.membershipRevision),targetJoinedRevision:c.decodeIfPresent(UInt64.self,forKey:.targetJoinedRevision),issuedAtMilliseconds:c.decode(UInt64.self,forKey:.issuedAtMilliseconds),expiresAtMilliseconds:c.decode(UInt64.self,forKey:.expiresAtMilliseconds))
    }
}
public enum V2MembershipAdmissionUnavailable:Codable,Equatable,Sendable {
    case confirmationExpired,invalidConfirmationDeadline,permissionDenied,roomNotFound,targetUnavailable,targetAlreadyMember,targetNotMember
    case membershipChanged(currentRevision:UInt64)
}
public enum V2MembershipAdmissionResult:Codable,Equatable,Sendable { case admitted(V2MembershipAdmission),currentUnavailable(V2MembershipAdmissionUnavailable),fingerprintConflict }
public struct V2MembershipOperationCommand:Codable,Equatable,Sendable {
    public let intent:V2MembershipIntent
    public let admission:V2MembershipAdmission
    public init(intent:V2MembershipIntent,admission:V2MembershipAdmission) throws { guard admission.validates(intent:intent) else { throw V2MembershipOperationValidationError.invalidCommand };self.intent=intent;self.admission=admission }
    public var identity:V2OperationIdentity { get throws { try intent.identity } }
    public var fingerprint:V2OperationFingerprint { get throws { try .init(kind:.membership,fields:[.init("intent",.bytes(intent.fingerprint.digest)),.init("admissionID",.text(admission.id.rawValue)),.init("action",.text(admission.action.rawValue)),.init("membershipRevision",.unsigned(admission.membershipRevision)),.init("joined",admission.targetJoinedRevision.map{.unsigned($0)} ?? .absent),.init("issuedAt",.unsigned(admission.issuedAtMilliseconds)),.init("expiresAt",.unsigned(admission.expiresAtMilliseconds))]) } }
    private enum CodingKeys:String,CodingKey { case intent,admission }
    public init(from decoder:any Decoder) throws { let c=try decoder.container(keyedBy:CodingKeys.self);try self.init(intent:c.decode(V2MembershipIntent.self,forKey:.intent),admission:c.decode(V2MembershipAdmission.self,forKey:.admission)) }
}
public struct V2MembershipApplied:Codable,Equatable,Sendable {
    public let membershipRevision:UInt64
    public let roomSequence:UInt64
    public let eventID:EventID
    public init(membershipRevision:UInt64,roomSequence:UInt64,eventID:EventID) throws {
        guard membershipRevision>0,membershipRevision<=UInt64(Int64.max),roomSequence>0,roomSequence<=UInt64(Int64.max) else { throw V2MembershipOperationValidationError.invalidReceipt }
        self.membershipRevision=membershipRevision;self.roomSequence=roomSequence;self.eventID=eventID
    }
    private enum CodingKeys:String,CodingKey { case membershipRevision,roomSequence,eventID }
    public init(from decoder:any Decoder) throws { let c=try decoder.container(keyedBy:CodingKeys.self);try self.init(membershipRevision:c.decode(UInt64.self,forKey:.membershipRevision),roomSequence:c.decode(UInt64.self,forKey:.roomSequence),eventID:c.decode(EventID.self,forKey:.eventID)) }
}
public enum V2MembershipOperationRejection:Codable,Equatable,Sendable {
    case admissionExpired,invalidAdmission,permissionDenied,roomNotFound,targetUnavailable,targetAlreadyMember,targetNotMember,memberLimitReached
    case membershipChanged(currentRevision:UInt64)
}
public enum V2MembershipTerminalOutcome:Codable,Equatable,Sendable { case changed(V2MembershipApplied),rejected(V2MembershipOperationRejection),closed }
public struct V2MembershipReceipt:Codable,Equatable,Sendable {
    public let identity:V2OperationIdentity
    public let fingerprint:V2OperationFingerprint
    public let outcome:V2MembershipTerminalOutcome
    public let resolvedAtMilliseconds:UInt64
    public init(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,outcome:V2MembershipTerminalOutcome,resolvedAtMilliseconds:UInt64) throws {
        guard identity.kind == .membership,case .room=identity.scope,resolvedAtMilliseconds>0,resolvedAtMilliseconds<=UInt64(Int64.max) else { throw V2MembershipOperationValidationError.invalidReceipt }
        if case .rejected(.membershipChanged(let current))=outcome { guard current<=UInt64(Int64.max) else { throw V2MembershipOperationValidationError.invalidReceipt } }
        self.identity=identity;self.fingerprint=fingerprint;self.outcome=outcome;self.resolvedAtMilliseconds=resolvedAtMilliseconds
    }
    public func validates(command:V2MembershipOperationCommand)->Bool {
        guard identity == (try? command.identity),fingerprint == (try? command.fingerprint) else { return false }
        if case .changed(let applied)=outcome { return applied.membershipRevision==command.intent.expectedMembershipRevision+1 };return true
    }
    private enum CodingKeys:String,CodingKey { case identity,fingerprint,outcome,resolvedAtMilliseconds }
    public init(from decoder:any Decoder) throws { let c=try decoder.container(keyedBy:CodingKeys.self);try self.init(identity:c.decode(V2OperationIdentity.self,forKey:.identity),fingerprint:c.decode(V2OperationFingerprint.self,forKey:.fingerprint),outcome:c.decode(V2MembershipTerminalOutcome.self,forKey:.outcome),resolvedAtMilliseconds:c.decode(UInt64.self,forKey:.resolvedAtMilliseconds)) }
}
public struct V2MembershipRecoveryRequest:Codable,Equatable,Sendable {
    public let identity:V2OperationIdentity
    public let fingerprint:V2OperationFingerprint
    public let action:V2OperationRecoveryRequest.Action
    public init(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,action:V2OperationRecoveryRequest.Action) throws {
        guard identity.kind == .membership,case .room=identity.scope else { throw V2MembershipOperationValidationError.invalidIntent };self.identity=identity;self.fingerprint=fingerprint;self.action=action
    }
    private enum CodingKeys:String,CodingKey { case identity,fingerprint,action }
    public init(from decoder:any Decoder) throws { let c=try decoder.container(keyedBy:CodingKeys.self);try self.init(identity:c.decode(V2OperationIdentity.self,forKey:.identity),fingerprint:c.decode(V2OperationFingerprint.self,forKey:.fingerprint),action:c.decode(V2OperationRecoveryRequest.Action.self,forKey:.action)) }
}
public enum V2MembershipRecoveryResult:Codable,Equatable,Sendable { case receipt(V2MembershipReceipt),deferred(V2MessageOperationRetryHint),unresolved,fingerprintConflict }

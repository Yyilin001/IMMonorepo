import Foundation

public enum V2SocialOperationValidationError:Error,Equatable,Sendable { case invalidCommand,invalidSnapshot,invalidReceipt }
public enum V2SocialOperationAction:Codable,Equatable,Sendable {
    case relationship(V2RelationshipAction)
    case userBlock(V2UserBlockAction)
    public var kind:V2OperationKind { switch self { case .relationship:.relationship;case .userBlock:.userBlock } }
}
/// A frozen target and baseline. A later visible state is not proof of this operation.
public struct V2SocialOperationCommand:Codable,Equatable,Sendable {
    public let identity:V2OperationIdentity
    public let action:V2SocialOperationAction
    public let expectedRevision:UInt64
    public let firstSubmissionDeadlineMilliseconds:UInt64
    public var actorUserID:UserID { identity.accountID }
    public var targetUserID:UserID { if case .userPair(_,let target)=identity.scope { target } else { preconditionFailure("Validated social scope") } }
    public init(identity:V2OperationIdentity,action:V2SocialOperationAction,expectedRevision:UInt64,firstSubmissionDeadlineMilliseconds:UInt64) throws {
        guard identity.kind==action.kind,case .userPair(let actor,let target)=identity.scope,actor==identity.accountID,actor != target,actor.uuidValue != nil,target.uuidValue != nil,UUID(uuidString:identity.operation.rawOperationID) != nil,expectedRevision<UInt64(Int64.max),firstSubmissionDeadlineMilliseconds>0,firstSubmissionDeadlineMilliseconds<=UInt64(Int64.max) else { throw V2SocialOperationValidationError.invalidCommand }
        self.identity=identity;self.action=action;self.expectedRevision=expectedRevision;self.firstSubmissionDeadlineMilliseconds=firstSubmissionDeadlineMilliseconds
    }
    public var fingerprint:V2OperationFingerprint { get throws {
        let actionValue:String=switch action { case .relationship(let value):value.rawValue;case .userBlock(let value):value.rawValue }
        return try .init(kind:identity.kind,fields:[.init("identity",.text(identity.storageKey)),.init("action",.text(actionValue)),.init("expectedRevision",.unsigned(expectedRevision)),.init("firstSubmissionDeadline",.unsigned(firstSubmissionDeadlineMilliseconds))])
    } }
    private enum CodingKeys:CodingKey { case identity,action,expectedRevision,firstSubmissionDeadlineMilliseconds }
    public init(from decoder:any Decoder) throws { let c=try decoder.container(keyedBy:CodingKeys.self);try self.init(identity:c.decode(V2OperationIdentity.self,forKey:.identity),action:c.decode(V2SocialOperationAction.self,forKey:.action),expectedRevision:c.decode(UInt64.self,forKey:.expectedRevision),firstSubmissionDeadlineMilliseconds:c.decode(UInt64.self,forKey:.firstSubmissionDeadlineMilliseconds)) }
}
/// Recipient-bound own baseline. `isBlocked` describes only actor -> target.
public struct V2SocialOperationSnapshot:Codable,Equatable,Sendable {
    public let actorUserID:UserID
    public let targetUserID:UserID
    public let relationshipState:V2RelationshipState
    public let requestedByUserID:UserID?
    public let relationshipRevision:UInt64
    public let isBlocked:Bool
    public let blockRevision:UInt64
    public init(actorUserID:UserID,targetUserID:UserID,relationshipState:V2RelationshipState,requestedByUserID:UserID?,relationshipRevision:UInt64,isBlocked:Bool,blockRevision:UInt64) throws {
        guard actorUserID != targetUserID,actorUserID.uuidValue != nil,targetUserID.uuidValue != nil,relationshipRevision<=UInt64(Int64.max),blockRevision<=UInt64(Int64.max) else { throw V2SocialOperationValidationError.invalidSnapshot }
        if relationshipState == .pending { guard requestedByUserID==actorUserID || requestedByUserID==targetUserID else { throw V2SocialOperationValidationError.invalidSnapshot } }
        else { guard requestedByUserID == nil else { throw V2SocialOperationValidationError.invalidSnapshot } }
        self.actorUserID=actorUserID;self.targetUserID=targetUserID;self.relationshipState=relationshipState;self.requestedByUserID=requestedByUserID;self.relationshipRevision=relationshipRevision;self.isBlocked=isBlocked;self.blockRevision=blockRevision
    }
    private enum CodingKeys:CodingKey { case actorUserID,targetUserID,relationshipState,requestedByUserID,relationshipRevision,isBlocked,blockRevision }
    public init(from decoder:any Decoder) throws { let c=try decoder.container(keyedBy:CodingKeys.self);try self.init(actorUserID:c.decode(UserID.self,forKey:.actorUserID),targetUserID:c.decode(UserID.self,forKey:.targetUserID),relationshipState:c.decode(V2RelationshipState.self,forKey:.relationshipState),requestedByUserID:c.decodeIfPresent(UserID.self,forKey:.requestedByUserID),relationshipRevision:c.decode(UInt64.self,forKey:.relationshipRevision),isBlocked:c.decode(Bool.self,forKey:.isBlocked),blockRevision:c.decode(UInt64.self,forKey:.blockRevision)) }
}
public enum V2SocialOperationRejection:Codable,Equatable,Sendable { case firstSubmissionExpired,invalidDeadline,permissionDenied,invalidState,revisionConflict(currentRevision:UInt64) }
public enum V2SocialOperationApplied:Codable,Equatable,Sendable { case relationship(state:V2RelationshipState,revision:UInt64);case userBlock(isBlocked:Bool,revision:UInt64) }
public enum V2SocialOperationTerminalOutcome:Codable,Equatable,Sendable { case applied(V2SocialOperationApplied),rejected(V2SocialOperationRejection),closed }
public struct V2SocialOperationReceipt:Codable,Equatable,Sendable {
    public let identity:V2OperationIdentity
    public let fingerprint:V2OperationFingerprint
    public let outcome:V2SocialOperationTerminalOutcome
    public let resolvedAtMilliseconds:UInt64
    public init(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,outcome:V2SocialOperationTerminalOutcome,resolvedAtMilliseconds:UInt64) throws {
        guard [.relationship,.userBlock].contains(identity.kind),case .userPair(let actor,let target)=identity.scope,actor==identity.accountID,actor.uuidValue != nil,target.uuidValue != nil,UUID(uuidString:identity.operation.rawOperationID) != nil,resolvedAtMilliseconds>0,resolvedAtMilliseconds<=UInt64(Int64.max) else { throw V2SocialOperationValidationError.invalidReceipt }
        switch outcome {
        case .applied(.relationship(_,let revision)):guard identity.kind == .relationship,revision>0,revision<=UInt64(Int64.max) else { throw V2SocialOperationValidationError.invalidReceipt }
        case .applied(.userBlock(_,let revision)):guard identity.kind == .userBlock,revision>0,revision<=UInt64(Int64.max) else { throw V2SocialOperationValidationError.invalidReceipt }
        case .rejected(.revisionConflict(let revision)):guard revision<=UInt64(Int64.max) else { throw V2SocialOperationValidationError.invalidReceipt }
        default:break
        }
        self.identity=identity;self.fingerprint=fingerprint;self.outcome=outcome;self.resolvedAtMilliseconds=resolvedAtMilliseconds
    }
    public func validates(command:V2SocialOperationCommand)->Bool {
        guard identity==command.identity,fingerprint==(try? command.fingerprint) else { return false }
        switch (outcome,command.action) {
        case (.applied(.relationship(let state,let revision)),.relationship(let action)):
            let expected:V2RelationshipState=switch action { case .request:.pending;case .accept:.accepted;case .reject,.remove:.none }
            return state==expected && revision==command.expectedRevision+1
        case (.applied(.userBlock(let blocked,let revision)),.userBlock(let action)):return blocked==(action == .block) && revision==command.expectedRevision+1
        case (.rejected,_),(.closed,_):return true
        default:return false
        }
    }
    private enum CodingKeys:CodingKey { case identity,fingerprint,outcome,resolvedAtMilliseconds }
    public init(from decoder:any Decoder) throws { let c=try decoder.container(keyedBy:CodingKeys.self);try self.init(identity:c.decode(V2OperationIdentity.self,forKey:.identity),fingerprint:c.decode(V2OperationFingerprint.self,forKey:.fingerprint),outcome:c.decode(V2SocialOperationTerminalOutcome.self,forKey:.outcome),resolvedAtMilliseconds:c.decode(UInt64.self,forKey:.resolvedAtMilliseconds)) }
}
public struct V2SocialOperationRecoveryRequest:Codable,Equatable,Sendable {
    public let identity:V2OperationIdentity
    public let fingerprint:V2OperationFingerprint
    public let action:V2OperationRecoveryRequest.Action
    public init(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,action:V2OperationRecoveryRequest.Action) throws {
        guard [.relationship,.userBlock].contains(identity.kind),case .userPair(let actor,let target)=identity.scope,actor==identity.accountID,actor.uuidValue != nil,target.uuidValue != nil,UUID(uuidString:identity.operation.rawOperationID) != nil else { throw V2SocialOperationValidationError.invalidCommand };self.identity=identity;self.fingerprint=fingerprint;self.action=action
    }
    private enum CodingKeys:CodingKey { case identity,fingerprint,action }
    public init(from decoder:any Decoder) throws { let c=try decoder.container(keyedBy:CodingKeys.self);try self.init(identity:c.decode(V2OperationIdentity.self,forKey:.identity),fingerprint:c.decode(V2OperationFingerprint.self,forKey:.fingerprint),action:c.decode(V2OperationRecoveryRequest.Action.self,forKey:.action)) }
}
public enum V2SocialOperationRecoveryResult:Codable,Equatable,Sendable { case receipt(V2SocialOperationReceipt),deferred(V2MessageOperationRetryHint),unresolved,fingerprintConflict }

import Foundation

public enum V2AccountPreferenceValidationError:Error,Equatable,Sendable { case invalidCommand,invalidSnapshot,invalidReceipt }
public enum V2AccountPreferenceValue:Codable,Equatable,Sendable {
    case strangerMessage(V2StrangerMessagePermission)
    case userAdd(V2UserAddPermission)
    case readReceipt(allowsDirectReadReceipts:Bool,allowsGroupReadReceipts:Bool)
    case liveActivity(allowsOnlinePresence:Bool,allowsTypingIndicators:Bool)
    public var kind:V2OperationKind { switch self { case .strangerMessage:.strangerMessagePreference;case .userAdd:.userAddPreference;case .readReceipt:.readReceiptPreference;case .liveActivity:.liveActivityPreference } }
    var fields:[V2OperationFingerprintField] {
        switch self {
        case .strangerMessage(let permission):[.init("permission",.text(permission.rawValue))]
        case .userAdd(let permission):[.init("permission",.text(permission.rawValue))]
        case .readReceipt(let direct,let group):[.init("allowsDirectReadReceipts",.flag(direct)),.init("allowsGroupReadReceipts",.flag(group))]
        case .liveActivity(let online,let typing):[.init("allowsOnlinePresence",.flag(online)),.init("allowsTypingIndicators",.flag(typing))]
        }
    }
}
public struct V2AccountPreferenceCommand:Codable,Equatable,Sendable {
    public let identity:V2OperationIdentity
    public let value:V2AccountPreferenceValue
    public let expectedRevision:UInt64
    public let firstSubmissionDeadlineMilliseconds:UInt64
    public init(identity:V2OperationIdentity,value:V2AccountPreferenceValue,expectedRevision:UInt64,firstSubmissionDeadlineMilliseconds:UInt64) throws {
        guard identity.kind==value.kind,case .account(let owner)=identity.scope,owner==identity.accountID,owner.uuidValue != nil,UUID(uuidString:identity.operation.rawOperationID) != nil,expectedRevision<UInt64(Int64.max),firstSubmissionDeadlineMilliseconds>0,firstSubmissionDeadlineMilliseconds<=UInt64(Int64.max) else { throw V2AccountPreferenceValidationError.invalidCommand }
        self.identity=identity;self.value=value;self.expectedRevision=expectedRevision;self.firstSubmissionDeadlineMilliseconds=firstSubmissionDeadlineMilliseconds
    }
    public var fingerprint:V2OperationFingerprint { get throws { try .init(kind:identity.kind,fields:[.init("identity",.text(identity.storageKey)),.init("expectedRevision",.unsigned(expectedRevision)),.init("firstSubmissionDeadline",.unsigned(firstSubmissionDeadlineMilliseconds))]+value.fields) } }
    private enum CodingKeys:CodingKey { case identity,value,expectedRevision,firstSubmissionDeadlineMilliseconds }
    public init(from decoder:any Decoder) throws { let c=try decoder.container(keyedBy:CodingKeys.self);try self.init(identity:c.decode(V2OperationIdentity.self,forKey:.identity),value:c.decode(V2AccountPreferenceValue.self,forKey:.value),expectedRevision:c.decode(UInt64.self,forKey:.expectedRevision),firstSubmissionDeadlineMilliseconds:c.decode(UInt64.self,forKey:.firstSubmissionDeadlineMilliseconds)) }
}
public struct V2AccountPreferenceSnapshot:Codable,Equatable,Sendable {
    public let ownerUserID:UserID
    public let value:V2AccountPreferenceValue
    public let revision:UInt64
    public init(ownerUserID:UserID,value:V2AccountPreferenceValue,revision:UInt64) throws { guard ownerUserID.uuidValue != nil,revision<=UInt64(Int64.max) else { throw V2AccountPreferenceValidationError.invalidSnapshot };self.ownerUserID=ownerUserID;self.value=value;self.revision=revision }
    private enum CodingKeys:CodingKey { case ownerUserID,value,revision }
    public init(from decoder:any Decoder) throws { let c=try decoder.container(keyedBy:CodingKeys.self);try self.init(ownerUserID:c.decode(UserID.self,forKey:.ownerUserID),value:c.decode(V2AccountPreferenceValue.self,forKey:.value),revision:c.decode(UInt64.self,forKey:.revision)) }
}
public enum V2AccountPreferenceRejection:Codable,Equatable,Sendable { case firstSubmissionExpired,invalidDeadline,permissionDenied,revisionConflict(currentRevision:UInt64) }
public enum V2AccountPreferenceTerminalOutcome:Codable,Equatable,Sendable { case applied(value:V2AccountPreferenceValue,revision:UInt64),rejected(V2AccountPreferenceRejection),closed }
public struct V2AccountPreferenceReceipt:Codable,Equatable,Sendable {
    public let identity:V2OperationIdentity
    public let fingerprint:V2OperationFingerprint
    public let outcome:V2AccountPreferenceTerminalOutcome
    public let resolvedAtMilliseconds:UInt64
    public init(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,outcome:V2AccountPreferenceTerminalOutcome,resolvedAtMilliseconds:UInt64) throws {
        guard [.strangerMessagePreference,.userAddPreference,.readReceiptPreference,.liveActivityPreference].contains(identity.kind),case .account(let owner)=identity.scope,owner==identity.accountID,owner.uuidValue != nil,UUID(uuidString:identity.operation.rawOperationID) != nil,resolvedAtMilliseconds>0,resolvedAtMilliseconds<=UInt64(Int64.max) else { throw V2AccountPreferenceValidationError.invalidReceipt }
        switch outcome { case .applied(let value,let revision):guard value.kind==identity.kind,revision>0,revision<=UInt64(Int64.max) else { throw V2AccountPreferenceValidationError.invalidReceipt };case .rejected(.revisionConflict(let revision)):guard revision<=UInt64(Int64.max) else { throw V2AccountPreferenceValidationError.invalidReceipt };default:break }
        self.identity=identity;self.fingerprint=fingerprint;self.outcome=outcome;self.resolvedAtMilliseconds=resolvedAtMilliseconds
    }
    public func validates(command:V2AccountPreferenceCommand)->Bool {
        guard identity==command.identity,fingerprint==(try? command.fingerprint) else { return false }
        switch outcome { case .applied(let value,let revision):return value==command.value && revision==command.expectedRevision+1;case .rejected,.closed:return true }
    }
    private enum CodingKeys:CodingKey { case identity,fingerprint,outcome,resolvedAtMilliseconds }
    public init(from decoder:any Decoder) throws { let c=try decoder.container(keyedBy:CodingKeys.self);try self.init(identity:c.decode(V2OperationIdentity.self,forKey:.identity),fingerprint:c.decode(V2OperationFingerprint.self,forKey:.fingerprint),outcome:c.decode(V2AccountPreferenceTerminalOutcome.self,forKey:.outcome),resolvedAtMilliseconds:c.decode(UInt64.self,forKey:.resolvedAtMilliseconds)) }
}
public struct V2AccountPreferenceRecoveryRequest:Codable,Equatable,Sendable {
    public let identity:V2OperationIdentity
    public let fingerprint:V2OperationFingerprint
    public let action:V2OperationRecoveryRequest.Action
    public init(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,action:V2OperationRecoveryRequest.Action) throws {
        guard [.strangerMessagePreference,.userAddPreference,.readReceiptPreference,.liveActivityPreference].contains(identity.kind),case .account(let owner)=identity.scope,owner==identity.accountID,owner.uuidValue != nil,UUID(uuidString:identity.operation.rawOperationID) != nil else { throw V2AccountPreferenceValidationError.invalidCommand };self.identity=identity;self.fingerprint=fingerprint;self.action=action
    }
    private enum CodingKeys:CodingKey { case identity,fingerprint,action }
    public init(from decoder:any Decoder) throws { let c=try decoder.container(keyedBy:CodingKeys.self);try self.init(identity:c.decode(V2OperationIdentity.self,forKey:.identity),fingerprint:c.decode(V2OperationFingerprint.self,forKey:.fingerprint),action:c.decode(V2OperationRecoveryRequest.Action.self,forKey:.action)) }
}
public enum V2AccountPreferenceRecoveryResult:Codable,Equatable,Sendable { case receipt(V2AccountPreferenceReceipt),deferred(V2MessageOperationRetryHint),unresolved,fingerprintConflict }

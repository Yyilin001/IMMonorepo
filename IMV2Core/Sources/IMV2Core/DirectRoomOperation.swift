import Foundation

public enum V2DirectRoomOperationValidationError:Error,Equatable,Sendable { case invalidCommand,invalidReceipt,invalidProof }
/// Opening a conversation retains this ID even when submission is uncertain.
public struct V2DirectRoomOperationCommand:Codable,Equatable,Sendable {
    public let actorUserID:UserID
    public let operationID:DirectRoomOperationID
    public let targetUserID:UserID
    public let firstSubmissionDeadlineMilliseconds:UInt64
    public init(actorUserID:UserID,operationID:DirectRoomOperationID,targetUserID:UserID,firstSubmissionDeadlineMilliseconds:UInt64) throws {
        guard actorUserID != targetUserID,actorUserID.uuidValue != nil,targetUserID.uuidValue != nil,operationID.uuidValue != nil,firstSubmissionDeadlineMilliseconds>0,firstSubmissionDeadlineMilliseconds<=UInt64(Int64.max) else { throw V2DirectRoomOperationValidationError.invalidCommand }
        self.actorUserID=actorUserID;self.operationID=operationID;self.targetUserID=targetUserID;self.firstSubmissionDeadlineMilliseconds=firstSubmissionDeadlineMilliseconds
    }
    public var identity:V2OperationIdentity { get throws { try .init(accountID:actorUserID,scope:.userPair(actorUserID,targetUserID),operation:.directRoom(operationID)) } }
    public var fingerprint:V2OperationFingerprint { get throws { try .init(kind:.directRoom,fields:[.init("identity",.text(identity.storageKey)),.init("firstSubmissionDeadline",.unsigned(firstSubmissionDeadlineMilliseconds))]) } }
    private enum CodingKeys:CodingKey { case actorUserID,operationID,targetUserID,firstSubmissionDeadlineMilliseconds }
    public init(from decoder:any Decoder) throws { let c=try decoder.container(keyedBy:CodingKeys.self);try self.init(actorUserID:c.decode(UserID.self,forKey:.actorUserID),operationID:c.decode(DirectRoomOperationID.self,forKey:.operationID),targetUserID:c.decode(UserID.self,forKey:.targetUserID),firstSubmissionDeadlineMilliseconds:c.decode(UInt64.self,forKey:.firstSubmissionDeadlineMilliseconds)) }
}
public enum V2DirectRoomOperationRejection:Codable,Equatable,Sendable { case firstSubmissionExpired,invalidDeadline,permissionDenied }
public enum V2DirectRoomOperationTerminalOutcome:Codable,Equatable,Sendable { case opened(roomID:RoomID,createdAtMilliseconds:UInt64),rejected(V2DirectRoomOperationRejection),closed }
/// Minimal original proof. It grants neither target-profile nor message-body access.
public struct V2DirectRoomOperationReceipt:Codable,Equatable,Sendable {
    public let identity:V2OperationIdentity
    public let fingerprint:V2OperationFingerprint
    public let outcome:V2DirectRoomOperationTerminalOutcome
    public let resolvedAtMilliseconds:UInt64
    public init(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,outcome:V2DirectRoomOperationTerminalOutcome,resolvedAtMilliseconds:UInt64) throws {
        guard identity.kind == .directRoom,case .userPair(let actor,let target)=identity.scope,actor==identity.accountID,actor.uuidValue != nil,target.uuidValue != nil,UUID(uuidString:identity.operation.rawOperationID) != nil,resolvedAtMilliseconds>0,resolvedAtMilliseconds<=UInt64(Int64.max) else { throw V2DirectRoomOperationValidationError.invalidReceipt }
        if case .opened(let room,let created)=outcome { guard room.uuidValue != nil,created>0,created<=UInt64(Int64.max) else { throw V2DirectRoomOperationValidationError.invalidReceipt } }
        self.identity=identity;self.fingerprint=fingerprint;self.outcome=outcome;self.resolvedAtMilliseconds=resolvedAtMilliseconds
    }
    public func validates(command:V2DirectRoomOperationCommand)->Bool { identity==(try? command.identity) && fingerprint==(try? command.fingerprint) }
    private enum CodingKeys:CodingKey { case identity,fingerprint,outcome,resolvedAtMilliseconds }
    public init(from decoder:any Decoder) throws { let c=try decoder.container(keyedBy:CodingKeys.self);try self.init(identity:c.decode(V2OperationIdentity.self,forKey:.identity),fingerprint:c.decode(V2OperationFingerprint.self,forKey:.fingerprint),outcome:c.decode(V2DirectRoomOperationTerminalOutcome.self,forKey:.outcome),resolvedAtMilliseconds:c.decode(UInt64.self,forKey:.resolvedAtMilliseconds)) }
}
/// A durable owner handoff. Its room is still unavailable until the terminal proof is returned.
public struct V2DirectRoomProcessingProof:Codable,Equatable,Sendable {
    public let identity:V2OperationIdentity
    public let fingerprint:V2OperationFingerprint
    public init(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint) throws {
        _ = try V2DirectRoomOperationReceipt(identity:identity,fingerprint:fingerprint,outcome:.closed,resolvedAtMilliseconds:1)
        self.identity=identity;self.fingerprint=fingerprint
    }
    public func validates(command:V2DirectRoomOperationCommand)->Bool { identity==(try? command.identity) && fingerprint==(try? command.fingerprint) }
    private enum CodingKeys:CodingKey { case identity,fingerprint }
    public init(from decoder:any Decoder) throws { let c=try decoder.container(keyedBy:CodingKeys.self);try self.init(identity:c.decode(V2OperationIdentity.self,forKey:.identity),fingerprint:c.decode(V2OperationFingerprint.self,forKey:.fingerprint)) }
}
public struct V2DirectRoomOperationRecoveryRequest:Codable,Equatable,Sendable {
    public let identity:V2OperationIdentity
    public let fingerprint:V2OperationFingerprint
    public let action:V2OperationRecoveryRequest.Action
    public init(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,action:V2OperationRecoveryRequest.Action) throws {
        _ = try V2DirectRoomProcessingProof(identity:identity,fingerprint:fingerprint)
        self.identity=identity;self.fingerprint=fingerprint;self.action=action
    }
    private enum CodingKeys:CodingKey { case identity,fingerprint,action }
    public init(from decoder:any Decoder) throws { let c=try decoder.container(keyedBy:CodingKeys.self);try self.init(identity:c.decode(V2OperationIdentity.self,forKey:.identity),fingerprint:c.decode(V2OperationFingerprint.self,forKey:.fingerprint),action:c.decode(V2OperationRecoveryRequest.Action.self,forKey:.action)) }
}
public enum V2DirectRoomOperationResult:Codable,Equatable,Sendable { case receipt(V2DirectRoomOperationReceipt),processing(V2DirectRoomProcessingProof),deferred(V2MessageOperationRetryHint),unresolved,fingerprintConflict }

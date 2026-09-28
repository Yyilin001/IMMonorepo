import Foundation

public enum V2GroupCapabilityValidationError: Error, Equatable, Sendable { case invalidIntent, invalidAdmission, invalidReceipt }
public enum V2GroupCapabilityAdmissionTag: V2IdentifierTag {}
public typealias V2GroupCapabilityAdmissionID = V2Identifier<V2GroupCapabilityAdmissionTag>
/// Pin uses the observed authoritative room event sequence as a conservative
/// CAS baseline. Unrelated room events can conflict; no intermediate pin change is hidden.
public enum V2GroupCapabilityAction: Codable, Equatable, Sendable {
    case pin(messageID: MessageID, isPinned: Bool, expectedRoomSequence: UInt64)
    case announcement(body: String, expectedRevision: UInt64)
    case rolePermissions(role: V2RoomMembershipRole, permissions: Set<V2GroupPermission>, expectedRevision: UInt64)
    case memberRole(targetUserID: UserID, role: V2RoomMembershipRole, expectedMembershipRevision: UInt64)
    public var kind: V2OperationKind {
        switch self { case .pin: .pinnedMessage; case .announcement: .groupAnnouncement; case .rolePermissions: .groupPermission; case .memberRole: .groupRole }
    }
    public var observedRevision: UInt64 {
        switch self { case .pin(_,_,let v), .announcement(_,let v), .rolePermissions(_,_,let v), .memberRole(_,_,let v): v }
    }
}
public struct V2GroupCapabilityIntent: Codable, Equatable, Sendable {
    public let identity: V2OperationIdentity
    public let action: V2GroupCapabilityAction
    public let confirmedUntilMilliseconds: UInt64
    public var roomID: RoomID {
        switch identity.scope { case .room(let room), .message(let room,_): room; default: preconditionFailure("validated room scope") }
    }
    public init(identity: V2OperationIdentity, action: V2GroupCapabilityAction, confirmedUntilMilliseconds: UInt64) throws {
        guard identity.kind == action.kind, identity.accountID.uuidValue != nil,
              UUID(uuidString:identity.operation.rawOperationID) != nil,
              confirmedUntilMilliseconds > 0, confirmedUntilMilliseconds <= UInt64(Int64.max),
              action.observedRevision < UInt64(Int64.max) else { throw V2GroupCapabilityValidationError.invalidIntent }
        switch action {
        case .pin(let message,_,_):
            guard case .message(let room,let scopedMessage)=identity.scope,room.uuidValue != nil,message.uuidValue != nil,scopedMessage == message else { throw V2GroupCapabilityValidationError.invalidIntent }
        case .announcement(let body,let revision):
            guard case .room(let room)=identity.scope,room.uuidValue != nil,!body.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  body.utf8.count <= V2GroupAnnouncementCommand.maximumUTF8Bytes,revision < UInt64(Int64.max) else { throw V2GroupCapabilityValidationError.invalidIntent }
        case .rolePermissions(let role,_,let revision):
            guard case .room(let room)=identity.scope,room.uuidValue != nil,role != .owner,revision > 0 else { throw V2GroupCapabilityValidationError.invalidIntent }
        case .memberRole(let target,let role,_):
            guard case .room(let room)=identity.scope,room.uuidValue != nil,target.uuidValue != nil,target != identity.accountID,
                  role != .owner else { throw V2GroupCapabilityValidationError.invalidIntent }
        }
        self.identity=identity;self.action=action;self.confirmedUntilMilliseconds=confirmedUntilMilliseconds
    }
    public var fingerprint: V2OperationFingerprint { get throws {
        var fields: [V2OperationFingerprintField] = [.init("identity",.text(identity.storageKey)),.init("confirmedUntil",.unsigned(confirmedUntilMilliseconds)),.init("observedRevision",.unsigned(action.observedRevision))]
        switch action {
        case .pin(let id,let value,_): fields += [.init("message",.text(id.rawValue)),.init("isPinned",.flag(value))]
        case .announcement(let body,_): fields += [.init("body",.text(body))]
        case .rolePermissions(let role,let permissions,_): fields += [.init("role",.text(role.rawValue)),.init("permissions",.orderedText(permissions.map(\.rawValue).sorted()))]
        case .memberRole(let target,let role,_): fields += [.init("target",.text(target.rawValue)),.init("role",.text(role.rawValue))]
        }
        return try .init(kind:identity.kind,fields:fields)
    } }
    private enum CodingKeys: CodingKey { case identity,action,confirmedUntilMilliseconds }
    public init(from decoder:any Decoder) throws {
        let v=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(identity:v.decode(V2OperationIdentity.self,forKey:.identity),action:v.decode(V2GroupCapabilityAction.self,forKey:.action),confirmedUntilMilliseconds:v.decode(UInt64.self,forKey:.confirmedUntilMilliseconds))
    }
}
public struct V2GroupCapabilityAdmission: Codable, Equatable, Sendable {
    public let id: V2GroupCapabilityAdmissionID
    public let identity: V2OperationIdentity
    public let intentFingerprint: V2OperationFingerprint
    public let issuedAtMilliseconds: UInt64
    public let expiresAtMilliseconds: UInt64
    public let targetJoinedRevision: UInt64?
    public init(id:V2GroupCapabilityAdmissionID,identity:V2OperationIdentity,intentFingerprint:V2OperationFingerprint,issuedAtMilliseconds:UInt64,expiresAtMilliseconds:UInt64,targetJoinedRevision:UInt64? = nil) throws {
        guard id.uuidValue != nil,[V2OperationKind.pinnedMessage,.groupAnnouncement,.groupPermission,.groupRole].contains(identity.kind),
              issuedAtMilliseconds>0,expiresAtMilliseconds>issuedAtMilliseconds,expiresAtMilliseconds<=UInt64(Int64.max),expiresAtMilliseconds-issuedAtMilliseconds<=120_000 else { throw V2GroupCapabilityValidationError.invalidAdmission }
        guard (identity.kind == .groupRole) == (targetJoinedRevision != nil),targetJoinedRevision.map({ $0<=UInt64(Int64.max) }) ?? true else { throw V2GroupCapabilityValidationError.invalidAdmission }
        self.targetJoinedRevision=targetJoinedRevision
        self.id=id;self.identity=identity;self.intentFingerprint=intentFingerprint;self.issuedAtMilliseconds=issuedAtMilliseconds;self.expiresAtMilliseconds=expiresAtMilliseconds
    }
    public func validates(intent:V2GroupCapabilityIntent)->Bool {
        guard identity==intent.identity,intentFingerprint==(try? intent.fingerprint),expiresAtMilliseconds<=intent.confirmedUntilMilliseconds else { return false }
        if case .memberRole(_,_,let revision)=intent.action { return targetJoinedRevision.map { $0<=revision } ?? false }
        return targetJoinedRevision==nil
    }
    private enum CodingKeys:CodingKey { case id,identity,intentFingerprint,issuedAtMilliseconds,expiresAtMilliseconds,targetJoinedRevision }
    public init(from decoder:any Decoder) throws {
        let v=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(id:v.decode(V2GroupCapabilityAdmissionID.self,forKey:.id),identity:v.decode(V2OperationIdentity.self,forKey:.identity),intentFingerprint:v.decode(V2OperationFingerprint.self,forKey:.intentFingerprint),issuedAtMilliseconds:v.decode(UInt64.self,forKey:.issuedAtMilliseconds),expiresAtMilliseconds:v.decode(UInt64.self,forKey:.expiresAtMilliseconds),targetJoinedRevision:v.decodeIfPresent(UInt64.self,forKey:.targetJoinedRevision))
    }
}
public struct V2GroupCapabilityCommand: Codable, Equatable, Sendable {
    public let intent: V2GroupCapabilityIntent
    public let admission: V2GroupCapabilityAdmission
    public var identity:V2OperationIdentity { intent.identity }
    public init(intent:V2GroupCapabilityIntent,admission:V2GroupCapabilityAdmission) throws {
        guard admission.validates(intent:intent) else { throw V2GroupCapabilityValidationError.invalidAdmission };self.intent=intent;self.admission=admission
    }
    public var fingerprint:V2OperationFingerprint { get throws {
        try .init(kind:identity.kind,fields:[.init("intent",.bytes(intent.fingerprint.digest)),.init("admission",.text(admission.id.rawValue)),.init("issued",.unsigned(admission.issuedAtMilliseconds)),.init("expires",.unsigned(admission.expiresAtMilliseconds)),.init("targetJoinedRevision",admission.targetJoinedRevision.map(V2OperationFingerprintField.Value.unsigned) ?? .absent)])
    } }
    private enum CodingKeys:CodingKey { case intent,admission }
    public init(from decoder:any Decoder) throws {
        let v=try decoder.container(keyedBy:CodingKeys.self);try self.init(intent:v.decode(V2GroupCapabilityIntent.self,forKey:.intent),admission:v.decode(V2GroupCapabilityAdmission.self,forKey:.admission))
    }
}
public enum V2GroupCapabilityRejection: Codable, Equatable, Sendable {
    case invalidAdmission,admissionExpired,permissionDenied,roomNotFound,notGroupRoom,messageNotFound,messageWithdrawn,targetNotMember,targetChanged
    case revisionChanged(currentRevision:UInt64)
}
public enum V2GroupCapabilityAdmissionUnavailable: Codable, Equatable, Sendable {
    case confirmationExpired,invalidConfirmationDeadline
    case current(V2GroupCapabilityRejection)
}
public enum V2GroupCapabilityAdmissionResult: Codable, Equatable, Sendable {
    case admitted(V2GroupCapabilityAdmission),currentUnavailable(V2GroupCapabilityAdmissionUnavailable),fingerprintConflict
}
public enum V2GroupCapabilityValue: Codable, Equatable, Sendable {
    case pinned(messageID:MessageID,isPinned:Bool,roomSequence:UInt64)
    case announcement(body:String,revision:UInt64,roomSequence:UInt64)
    case rolePermissions(role:V2RoomMembershipRole,permissions:Set<V2GroupPermission>,revision:UInt64,roomSequence:UInt64)
    case memberRole(targetUserID:UserID,role:V2RoomMembershipRole,membershipRevision:UInt64,roomSequence:UInt64)
    public var kind:V2OperationKind { switch self { case .pinned:.pinnedMessage;case .announcement:.groupAnnouncement;case .rolePermissions:.groupPermission;case .memberRole:.groupRole } }
    public var roomSequence:UInt64 { switch self { case .pinned(_,_,let value),.announcement(_,_,let value),.rolePermissions(_,_,_,let value),.memberRole(_,_,_,let value):value } }
}
public enum V2GroupCapabilityTerminalOutcome: Codable, Equatable, Sendable { case applied(V2GroupCapabilityValue),alreadySatisfied(V2GroupCapabilityValue),rejected(V2GroupCapabilityRejection),closed }
public struct V2GroupCapabilityReceipt: Codable, Equatable, Sendable {
    public let identity:V2OperationIdentity
    public let fingerprint:V2OperationFingerprint
    public let outcome:V2GroupCapabilityTerminalOutcome
    public let resolvedAtMilliseconds:UInt64
    public init(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,outcome:V2GroupCapabilityTerminalOutcome,resolvedAtMilliseconds:UInt64) throws {
        guard [V2OperationKind.pinnedMessage,.groupAnnouncement,.groupPermission,.groupRole].contains(identity.kind),resolvedAtMilliseconds>0,resolvedAtMilliseconds<=UInt64(Int64.max) else { throw V2GroupCapabilityValidationError.invalidReceipt }
        if case .applied(let value)=outcome { guard value.roomSequence>0 else { throw V2GroupCapabilityValidationError.invalidReceipt } }
        switch outcome {
        case .applied(let value),.alreadySatisfied(let value):
            guard value.kind==identity.kind else { throw V2GroupCapabilityValidationError.invalidReceipt }
            switch value {
            case .pinned(let message,_,let sequence):
                guard case .message(_,let scopedMessage)=identity.scope,message==scopedMessage,sequence<=UInt64(Int64.max) else { throw V2GroupCapabilityValidationError.invalidReceipt }
            case .announcement(let body,let revision,let sequence):
                guard !body.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,body.utf8.count<=V2GroupAnnouncementCommand.maximumUTF8Bytes,
                    revision>0,revision<=UInt64(Int64.max),sequence<=UInt64(Int64.max) else { throw V2GroupCapabilityValidationError.invalidReceipt }
            case .rolePermissions(let role,_,let revision,let sequence):
                guard role != .owner,revision>0,revision<=UInt64(Int64.max),sequence<=UInt64(Int64.max) else { throw V2GroupCapabilityValidationError.invalidReceipt }
            case .memberRole(let target,let role,let revision,let sequence):
                guard target.uuidValue != nil,target != identity.accountID,role != .owner,revision<=UInt64(Int64.max),sequence<=UInt64(Int64.max) else { throw V2GroupCapabilityValidationError.invalidReceipt }
            }
        case .rejected(.revisionChanged(let revision)): guard revision<=UInt64(Int64.max) else { throw V2GroupCapabilityValidationError.invalidReceipt }
        default:break
        }
        self.identity=identity;self.fingerprint=fingerprint;self.outcome=outcome;self.resolvedAtMilliseconds=resolvedAtMilliseconds
    }
    public func validates(command:V2GroupCapabilityCommand)->Bool {
        guard identity==command.identity,fingerprint==(try? command.fingerprint) else { return false }
        let value:V2GroupCapabilityValue,applied:Bool
        switch outcome { case .applied(let v):value=v;applied=true;case .alreadySatisfied(let v):value=v;applied=false;default:return true }
        switch (command.intent.action,value) {
        case (.pin(let message,let desired,let expected),.pinned(let result,let actual,let sequence)):
            return result==message && desired==actual && sequence==(applied ? expected+1:expected)
        case (.announcement(let body,let expected),.announcement(let actual,let revision,let sequence)):
            return body==actual && revision==(applied ? expected+1:expected) && sequence>0
        case (.rolePermissions(let role,let permissions,let expected),.rolePermissions(let actualRole,let actualPermissions,let revision,let sequence)):
            return role==actualRole && permissions==actualPermissions && revision==(applied ? expected+1:expected) && sequence>0
        case (.memberRole(let target,let role,let expected),.memberRole(let actualTarget,let actualRole,let revision,_)):
            return target==actualTarget && role==actualRole && revision==(applied ? expected+1:expected)
        default:return false
        }
    }
    private enum CodingKeys:CodingKey { case identity,fingerprint,outcome,resolvedAtMilliseconds }
    public init(from decoder:any Decoder) throws {
        let v=try decoder.container(keyedBy:CodingKeys.self);try self.init(identity:v.decode(V2OperationIdentity.self,forKey:.identity),fingerprint:v.decode(V2OperationFingerprint.self,forKey:.fingerprint),outcome:v.decode(V2GroupCapabilityTerminalOutcome.self,forKey:.outcome),resolvedAtMilliseconds:v.decode(UInt64.self,forKey:.resolvedAtMilliseconds))
    }
}
public struct V2GroupCapabilityRecoveryRequest: Codable, Equatable, Sendable {
    public let identity:V2OperationIdentity
    public let fingerprint:V2OperationFingerprint
    public let action:V2OperationRecoveryRequest.Action
    public init(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,action:V2OperationRecoveryRequest.Action) throws {
        guard [V2OperationKind.pinnedMessage,.groupAnnouncement,.groupPermission,.groupRole].contains(identity.kind),identity.accountID.uuidValue != nil,UUID(uuidString:identity.operation.rawOperationID) != nil else { throw V2GroupCapabilityValidationError.invalidIntent }
        self.identity=identity;self.fingerprint=fingerprint;self.action=action
    }
    private enum CodingKeys:CodingKey { case identity,fingerprint,action }
    public init(from decoder:any Decoder) throws {
        let v=try decoder.container(keyedBy:CodingKeys.self);try self.init(identity:v.decode(V2OperationIdentity.self,forKey:.identity),fingerprint:v.decode(V2OperationFingerprint.self,forKey:.fingerprint),action:v.decode(V2OperationRecoveryRequest.Action.self,forKey:.action))
    }
}
public enum V2GroupCapabilityRecoveryResult: Codable, Equatable, Sendable { case receipt(V2GroupCapabilityReceipt),deferred(V2MessageOperationRetryHint),unresolved,fingerprintConflict }
public struct V2PinnedMessageBaseline: Codable, Equatable, Sendable {
    public let roomID:RoomID;public let messageID:MessageID;public let isPinned:Bool;public let roomSequence:UInt64
    public init(roomID:RoomID,messageID:MessageID,isPinned:Bool,roomSequence:UInt64) throws {
        guard roomID.uuidValue != nil,messageID.uuidValue != nil,roomSequence<=UInt64(Int64.max) else { throw V2GroupCapabilityValidationError.invalidIntent }
        self.roomID=roomID;self.messageID=messageID;self.isPinned=isPinned;self.roomSequence=roomSequence
    }
}

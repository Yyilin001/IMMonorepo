import Crypto
import Foundation

public enum V2GroupInvitationOperationValidationError: Error, Equatable, Sendable { case invalidIntent, invalidAdmission, invalidReceipt, invalidSecretBinding }
public enum V2GroupInvitationAdmissionTag: V2IdentifierTag {}
public typealias V2GroupInvitationAdmissionID = V2Identifier<V2GroupInvitationAdmissionTag>

public enum V2GroupInvitationOperationAction: Codable, Equatable, Sendable {
    case create(lifetimeSeconds: UInt64, maximumApprovedUses: Int, expectedMembershipRevision: UInt64)
    case revoke(inviteID: GroupInviteID, expectedMembershipRevision: UInt64)
    case submit(inviteID: GroupInviteID, tokenDigest: Data, note: String?)
    case cancel(requestID: GroupJoinRequestID)
    case decide(requestID: GroupJoinRequestID, decision: V2GroupJoinDecision, expectedMembershipRevision: UInt64)
    public var kind: V2OperationKind {
        switch self { case .create,.revoke: .groupInvite; case .submit,.cancel: .groupJoinRequest; case .decide: .groupJoinDecision }
    }
    public var observedMembershipRevision: UInt64? {
        switch self { case .create(_,_,let revision),.revoke(_,let revision),.decide(_,_,let revision): revision; default: nil }
    }
}
public struct V2GroupInvitationOperationIntent: Codable, Equatable, Sendable {
    public let identity: V2OperationIdentity
    public let action: V2GroupInvitationOperationAction
    public let confirmedUntilMilliseconds: UInt64
    public var roomID: RoomID { if case .room(let room) = identity.scope { return room }; preconditionFailure("validated room scope") }
    public init(identity: V2OperationIdentity, action: V2GroupInvitationOperationAction, confirmedUntilMilliseconds: UInt64) throws {
        guard identity.kind == action.kind, identity.accountID.uuidValue != nil, UUID(uuidString: identity.operation.rawOperationID) != nil,
              case .room(let room) = identity.scope, room.uuidValue != nil,
              confirmedUntilMilliseconds > 0, confirmedUntilMilliseconds <= UInt64(Int64.max),
              action.observedMembershipRevision.map({ $0 < UInt64(Int64.max) }) ?? true else { throw V2GroupInvitationOperationValidationError.invalidIntent }
        var normalized = action
        switch action {
        case .create(let lifetime,let uses,_):
            guard (300...2_592_000).contains(lifetime), (1...1_000).contains(uses) else { throw V2GroupInvitationOperationValidationError.invalidIntent }
        case .revoke(let invite,_): guard invite.uuidValue != nil else { throw V2GroupInvitationOperationValidationError.invalidIntent }
        case .submit(let invite,let digest,let note):
            let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard invite.uuidValue != nil, digest.count == 32, (trimmed?.utf8.count ?? 0) <= 500 else { throw V2GroupInvitationOperationValidationError.invalidIntent }
            normalized = .submit(inviteID: invite, tokenDigest: digest, note: trimmed?.isEmpty == false ? trimmed : nil)
        case .cancel(let request),.decide(let request,_,_): guard request.uuidValue != nil else { throw V2GroupInvitationOperationValidationError.invalidIntent }
        }
        self.identity = identity; self.action = normalized; self.confirmedUntilMilliseconds = confirmedUntilMilliseconds
    }
    /// Admission is a gate credential, not part of the semantic business identity.
    /// This makes query/close possible before an admission response has arrived.
    public var fingerprint: V2OperationFingerprint { get throws {
        var fields: [V2OperationFingerprintField] = [.init("identity",.text(identity.storageKey)),.init("deadline",.unsigned(confirmedUntilMilliseconds))]
        switch action {
        case .create(let lifetime,let uses,let revision): fields += [.init("action",.text("create")),.init("lifetime",.unsigned(lifetime)),.init("uses",.unsigned(UInt64(uses))),.init("membership",.unsigned(revision))]
        case .revoke(let invite,let revision): fields += [.init("action",.text("revoke")),.init("invite",.text(invite.rawValue)),.init("membership",.unsigned(revision))]
        case .submit(let invite,let digest,let note): fields += [.init("action",.text("submit")),.init("invite",.text(invite.rawValue)),.init("tokenDigest",.bytes(digest)),.init("note",note.map { .text($0) } ?? .absent)]
        case .cancel(let request): fields += [.init("action",.text("cancel")),.init("request",.text(request.rawValue))]
        case .decide(let request,let decision,let revision): fields += [.init("action",.text("decide")),.init("request",.text(request.rawValue)),.init("decision",.text(decision.rawValue)),.init("membership",.unsigned(revision))]
        }
        return try .init(kind: identity.kind, fields: fields)
    } }
    private enum CodingKeys: CodingKey { case identity,action,confirmedUntilMilliseconds }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(identity: c.decode(V2OperationIdentity.self,forKey:.identity), action: c.decode(V2GroupInvitationOperationAction.self,forKey:.action), confirmedUntilMilliseconds: c.decode(UInt64.self,forKey:.confirmedUntilMilliseconds))
    }
}
public struct V2GroupInvitationAdmission: Codable, Equatable, Sendable {
    public let id: V2GroupInvitationAdmissionID
    public let identity: V2OperationIdentity
    public let intentFingerprint: V2OperationFingerprint
    public let membershipRevision: UInt64
    public let issuedAtMilliseconds: UInt64
    public let expiresAtMilliseconds: UInt64
    public init(id: V2GroupInvitationAdmissionID, identity: V2OperationIdentity, intentFingerprint: V2OperationFingerprint, membershipRevision: UInt64, issuedAtMilliseconds: UInt64, expiresAtMilliseconds: UInt64) throws {
        guard id.uuidValue != nil, [.groupInvite,.groupJoinRequest,.groupJoinDecision].contains(identity.kind), case .room(let room) = identity.scope, room.uuidValue != nil,
              identity.accountID.uuidValue != nil, UUID(uuidString: identity.operation.rawOperationID) != nil,
              membershipRevision < UInt64(Int64.max), issuedAtMilliseconds > 0, expiresAtMilliseconds > issuedAtMilliseconds,
              expiresAtMilliseconds <= UInt64(Int64.max), expiresAtMilliseconds - issuedAtMilliseconds <= 120_000 else { throw V2GroupInvitationOperationValidationError.invalidAdmission }
        self.id = id; self.identity = identity; self.intentFingerprint = intentFingerprint; self.membershipRevision = membershipRevision
        self.issuedAtMilliseconds = issuedAtMilliseconds; self.expiresAtMilliseconds = expiresAtMilliseconds
    }
    public func validates(intent: V2GroupInvitationOperationIntent) -> Bool {
        identity == intent.identity && intentFingerprint == (try? intent.fingerprint) && expiresAtMilliseconds <= intent.confirmedUntilMilliseconds && (intent.action.observedMembershipRevision.map { $0 == membershipRevision } ?? true)
    }
    private enum CodingKeys: CodingKey { case id,identity,intentFingerprint,membershipRevision,issuedAtMilliseconds,expiresAtMilliseconds }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id:c.decode(V2GroupInvitationAdmissionID.self,forKey:.id),identity:c.decode(V2OperationIdentity.self,forKey:.identity),intentFingerprint:c.decode(V2OperationFingerprint.self,forKey:.intentFingerprint),membershipRevision:c.decode(UInt64.self,forKey:.membershipRevision),issuedAtMilliseconds:c.decode(UInt64.self,forKey:.issuedAtMilliseconds),expiresAtMilliseconds:c.decode(UInt64.self,forKey:.expiresAtMilliseconds))
    }
}
public struct V2GroupInvitationOperationCommand: Codable, Equatable, Sendable {
    public let intent: V2GroupInvitationOperationIntent
    public let admission: V2GroupInvitationAdmission
    public var identity: V2OperationIdentity { intent.identity }
    public var fingerprint: V2OperationFingerprint { get throws { try intent.fingerprint } }
    public init(intent: V2GroupInvitationOperationIntent, admission: V2GroupInvitationAdmission) throws {
        guard admission.validates(intent: intent) else { throw V2GroupInvitationOperationValidationError.invalidAdmission }
        self.intent = intent; self.admission = admission
    }
    private enum CodingKeys: CodingKey { case intent,admission }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(intent:c.decode(V2GroupInvitationOperationIntent.self,forKey:.intent),admission:c.decode(V2GroupInvitationAdmission.self,forKey:.admission))
    }
}
/// The bearer is separate from every fingerprint, admission and permanent proof.
public struct V2GroupInvitationSecretAuthorization: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let rawValue: String
    public init(secret: V2GroupInviteSecret) { rawValue = secret.rawValue }
    public var description: String { "<redacted-invitation-authorization>" }
    public var debugDescription: String { description }
    public var tokenDigest: Data { Data(SHA256.hash(data: Data(rawValue.utf8))) }
    public func validates(intent: V2GroupInvitationOperationIntent) -> Bool {
        guard case .submit(_,let digest,_) = intent.action else { return false }; return digest == tokenDigest
    }
    private enum CodingKeys: CodingKey { case rawValue }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(secret: try V2GroupInviteSecret(c.decode(String.self,forKey:.rawValue)))
    }
}
public struct V2GroupInvitationAdmissionRequest: Codable, Equatable, Sendable {
    public let intent: V2GroupInvitationOperationIntent
    public let secretAuthorization: V2GroupInvitationSecretAuthorization?
    public init(intent: V2GroupInvitationOperationIntent, secretAuthorization: V2GroupInvitationSecretAuthorization? = nil) throws {
        if case .submit = intent.action { guard secretAuthorization?.validates(intent:intent) == true else { throw V2GroupInvitationOperationValidationError.invalidSecretBinding } }
        else { guard secretAuthorization == nil else { throw V2GroupInvitationOperationValidationError.invalidSecretBinding } }
        self.intent = intent; self.secretAuthorization = secretAuthorization
    }
    private enum CodingKeys: CodingKey { case intent,secretAuthorization }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(intent:c.decode(V2GroupInvitationOperationIntent.self,forKey:.intent),secretAuthorization:c.decodeIfPresent(V2GroupInvitationSecretAuthorization.self,forKey:.secretAuthorization))
    }
}
public struct V2GroupInvitationSubmission: Codable, Equatable, Sendable {
    public let command: V2GroupInvitationOperationCommand
    public let secretAuthorization: V2GroupInvitationSecretAuthorization?
    public init(command: V2GroupInvitationOperationCommand, secretAuthorization: V2GroupInvitationSecretAuthorization? = nil) throws {
        _ = try V2GroupInvitationAdmissionRequest(intent: command.intent, secretAuthorization: secretAuthorization)
        self.command = command; self.secretAuthorization = secretAuthorization
    }
    private enum CodingKeys: CodingKey { case command,secretAuthorization }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(command:c.decode(V2GroupInvitationOperationCommand.self,forKey:.command),secretAuthorization:c.decodeIfPresent(V2GroupInvitationSecretAuthorization.self,forKey:.secretAuthorization))
    }
}
public enum V2GroupInvitationOperationRejection: Codable, Equatable, Sendable {
    case admissionExpired, invalidAdmission, permissionDenied, roomNotFound, inviteUnavailable, requestNotFound, requestAlreadyDecided, alreadyMember, applicantUnavailable, memberLimitReached
    case membershipChanged(currentRevision: UInt64)
}
public enum V2GroupInvitationAdmissionResult: Codable, Equatable, Sendable {
    case admitted(V2GroupInvitationAdmission)
    case currentUnavailable(V2GroupInvitationOperationRejection)
    case fingerprintConflict
    case terminal(V2GroupInvitationOperationReceipt)
}
public enum V2GroupInvitationOperationValue: Codable, Equatable, Sendable {
    case inviteCreated(inviteID: GroupInviteID, createdAtMilliseconds: UInt64, expiresAtMilliseconds: UInt64, maximumApprovedUses: Int)
    case inviteRevoked(inviteID: GroupInviteID)
    case requestSubmitted(requestID: GroupJoinRequestID, inviteID: GroupInviteID)
    case requestCancelled(requestID: GroupJoinRequestID)
    case requestDecided(requestID: GroupJoinRequestID, decision: V2GroupJoinDecision, membershipRevision: UInt64?)
}
public enum V2GroupInvitationOperationTerminalOutcome: Codable, Equatable, Sendable {
    case applied(V2GroupInvitationOperationValue)
    case alreadySatisfied(V2GroupInvitationOperationValue)
    case rejected(V2GroupInvitationOperationRejection)
    case closed
}
public struct V2GroupInvitationOperationReceipt: Codable, Equatable, Sendable {
    public let identity: V2OperationIdentity
    public let fingerprint: V2OperationFingerprint
    public let outcome: V2GroupInvitationOperationTerminalOutcome
    public let resolvedAtMilliseconds: UInt64
    public init(intent: V2GroupInvitationOperationIntent, outcome: V2GroupInvitationOperationTerminalOutcome, resolvedAtMilliseconds: UInt64) throws {
        self.identity = intent.identity; self.fingerprint = try intent.fingerprint; self.outcome = outcome; self.resolvedAtMilliseconds = resolvedAtMilliseconds
        guard validates(intent: intent) else { throw V2GroupInvitationOperationValidationError.invalidReceipt }
    }
    public func validates(intent: V2GroupInvitationOperationIntent) -> Bool {
        guard identity == intent.identity, fingerprint == (try? intent.fingerprint), resolvedAtMilliseconds > 0, resolvedAtMilliseconds <= UInt64(Int64.max) else { return false }
        switch outcome {
        case .closed: return true
        case .rejected(.membershipChanged(let revision)): return revision <= UInt64(Int64.max)
        case .rejected: return true
        case .applied(let value),.alreadySatisfied(let value):
            switch (intent.action,value) {
            case (.create(let lifetime,let uses,_),.inviteCreated(let invite,let created,let expires,let returnedUses)):
                return invite.uuidValue != nil && created > 0 && created <= UInt64(Int64.max) && expires <= UInt64(Int64.max) && expires > created && expires - created == lifetime * 1_000 && returnedUses == uses
            case (.revoke(let invite,_),.inviteRevoked(let returned)): return invite == returned
            case (.submit(let invite,_,_),.requestSubmitted(let request,let returnedInvite)): return request.uuidValue != nil && returnedInvite == invite
            case (.cancel(let request),.requestCancelled(let returned)): return request == returned
            case (.decide(let request,let decision,let expected),.requestDecided(let returned,let returnedDecision,let revision)):
                if decision == .reject { return request == returned && decision == returnedDecision && revision == nil }
                return request == returned && decision == returnedDecision && revision == expected + 1
            default: return false
            }
        }
    }
}
public struct V2GroupInvitationRecoveryRequest: Codable, Equatable, Sendable {
    public let intent: V2GroupInvitationOperationIntent
    public let action: V2OperationRecoveryRequest.Action
    public init(intent: V2GroupInvitationOperationIntent, action: V2OperationRecoveryRequest.Action) { self.intent = intent; self.action = action }
}
public enum V2GroupInvitationOperationRecoveryResult: Codable, Equatable, Sendable {
    case receipt(V2GroupInvitationOperationReceipt)
    case unresolved
    case fingerprintConflict
    case deferred(V2MessageOperationRetryHint)
}
public struct V2GroupInvitationOperationBaseline: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let membershipRevision: UInt64
    public init(roomID: RoomID, membershipRevision: UInt64) throws {
        guard roomID.uuidValue != nil, membershipRevision < UInt64(Int64.max) else { throw V2GroupInvitationOperationValidationError.invalidIntent }
        self.roomID = roomID; self.membershipRevision = membershipRevision
    }
    private enum CodingKeys: CodingKey { case roomID,membershipRevision }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(roomID:c.decode(RoomID.self,forKey:.roomID),membershipRevision:c.decode(UInt64.self,forKey:.membershipRevision))
    }
}

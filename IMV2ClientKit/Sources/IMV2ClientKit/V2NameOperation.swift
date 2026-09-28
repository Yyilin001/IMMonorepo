import Foundation
import IMV2Core

/// Only fields authored by this account. This value never grants a display lease for another user's profile.
public enum V2NameTarget: Equatable, Codable, Sendable {
    case contact(UserID)
    case group(RoomID)
    var orderingKey: String {
        switch self { case .contact(let id): "contactAlias/\(id.rawValue)"; case .group(let id): "groupNickname/\(id.rawValue)" }
    }
    var kind: V2OperationKind { switch self { case .contact: .contactAlias; case .group: .groupNickname } }
}
public struct V2NameSnapshot: Equatable, Codable, Sendable {
    public let target: V2NameTarget
    public let name: String?
    public let revision: V2ProfileRevision?
    public init(target: V2NameTarget, name: String?, revision: V2ProfileRevision?) {
        self.target = target; self.name = name; self.revision = revision
    }
}

enum V2FrozenNameOperation: Equatable, Codable, Sendable {
    case contact(V2ContactAliasUpdateCommand)
    case group(V2GroupNicknameUpdateCommand)
    init(accountID: UserID, target: V2NameTarget, name: String?, revision: V2ProfileRevision?, id: UUID, deadline: Date) throws {
        guard let milliseconds = UInt64(exactly: (deadline.timeIntervalSince1970 * 1000).rounded(.towardZero)) else { throw V2OperationWorkError.invalidRecord }
        switch target {
        case .contact(let target): self = .contact(try .init(ownerUserID: accountID, targetUserID: target,
            operationID: .init(id.uuidString), expectedRevision: revision, remarkName: name, firstSubmissionDeadlineMilliseconds: milliseconds))
        case .group(let room): self = .group(try .init(actorUserID: accountID, roomID: room,
            operationID: .init(id.uuidString), expectedRevision: revision, nickname: name, firstSubmissionDeadlineMilliseconds: milliseconds))
        }
    }
    var identity: V2OperationIdentity { switch self { case .contact(let c): c.identity; case .group(let c): c.identity } }
    var fingerprint: V2OperationFingerprint { switch self { case .contact(let c): c.fingerprint; case .group(let c): c.fingerprint } }
    var target: V2NameTarget { switch self { case .contact(let c): .contact(c.targetUserID); case .group(let c): .group(c.roomID) } }
    var name: String? { switch self { case .contact(let c): c.remarkName; case .group(let c): c.nickname } }
    var revision: V2ProfileRevision? { switch self { case .contact(let c): c.expectedRevision; case .group(let c): c.expectedRevision } }
    func validate(_ receipt: V2NameReceipt) throws {
        guard receipt.identity == identity, receipt.fingerprint == fingerprint else { throw V2OperationWorkError.identityConflict }
        switch (self, receipt) {
        case (.contact(let c), .contact(let r)):
            if case .committed(let value) = r.outcome {
                guard value.remarkName == c.remarkName, value.revision.rawValue > 0,
                      value.revision.rawValue - 1 == (c.expectedRevision?.rawValue ?? 0) else { throw V2OperationWorkError.identityConflict }
            }
        case (.group(let c), .group(let r)):
            if case .committed(let value) = r.outcome {
                guard value.groupNickname == c.nickname, value.revision.rawValue > 0,
                      value.revision.rawValue - 1 == (c.expectedRevision?.rawValue ?? 0) else { throw V2OperationWorkError.identityConflict }
            }
        default: throw V2OperationWorkError.identityConflict
        }
    }
}
enum V2NameReceipt: Codable, Sendable {
    case contact(V2ContactAliasUpdateReceipt)
    case group(V2GroupNicknameUpdateReceipt)
    var identity: V2OperationIdentity { switch self { case .contact(let r): r.identity; case .group(let r): r.identity } }
    var fingerprint: V2OperationFingerprint { switch self { case .contact(let r): r.fingerprint; case .group(let r): r.fingerprint } }
    var state: V2OperationExecutionState {
        switch self {
        case .contact(let r): switch r.outcome { case .committed: .committed; case .closed: .closed; case .rejected(.revisionConflict): .conflicted; case .rejected: .rejected }
        case .group(let r): switch r.outcome { case .committed: .committed; case .closed: .closed; case .rejected(.revisionConflict): .conflicted; case .rejected: .rejected }
        }
    }
    var snapshot: V2NameSnapshot? {
        switch self {
        case .contact(let r): if case .committed(let v) = r.outcome { return .init(target: .contact(v.targetUserID), name: v.remarkName, revision: v.revision) }
        case .group(let r): if case .committed(let v) = r.outcome { return .init(target: .group(v.roomID), name: v.groupNickname, revision: v.revision) }
        }
        return nil
    }
}
public struct V2NameIntentSnapshot: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let target: V2NameTarget
    public let name: String?
    public let work: V2OperationWork
}

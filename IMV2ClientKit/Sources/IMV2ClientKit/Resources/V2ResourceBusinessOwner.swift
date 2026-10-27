import Foundation
import IMV2Core

public enum V2ResourceBusinessOwner: Hashable, Sendable {
    case profileIntent(UUID)
    case groupAvatar(RoomID, GroupAvatarOperationID)
    var kind: String { switch self { case .profileIntent: "profile"; case .groupAvatar: "group" } }
    var token: String { switch self { case .profileIntent(let id): id.uuidString; case .groupAvatar(_, let id): id.rawValue } }
}
public struct V2ResourceBusinessOwnerEntry: Equatable, Identifiable, Sendable {
    public var id: V2ResourceBusinessOwner { owner }
    public let owner: V2ResourceBusinessOwner
    public let createdAt: Date
}
public struct V2ResourceBusinessOwnerCursor: Equatable, Sendable {
    let transfer: V2ManagedResourceTransferID
    let createdAt: Date
    let kind: String
    let token: String
}
public struct V2ResourceBusinessOwnerQuery: Equatable, Sendable {
    public let transfer: V2ManagedResourceTransferID
    public let before: V2ResourceBusinessOwnerCursor?
    public let limit: Int
    public init(transfer: V2ManagedResourceTransferID, before: V2ResourceBusinessOwnerCursor? = nil, limit: Int = 25) throws {
        guard (1...100).contains(limit), before.map({ $0.transfer == transfer }) ?? true else { throw V2ResourceStorageError.invalidRecord }
        self.transfer = transfer; self.before = before; self.limit = limit
    }
}
public struct V2ResourceBusinessOwnerPage: Equatable, Sendable {
    public let entries: [V2ResourceBusinessOwnerEntry]
    public let nextCursor: V2ResourceBusinessOwnerCursor?
}
public enum V2ResourceBusinessOwnerSnapshot: Equatable, Sendable {
    case available(V2ResourceBusinessOwnerPage), unavailable
}
public struct V2ResourceProfileDispositionPlan: Equatable, Identifiable, Sendable {
    public enum Effect: Equatable, Sendable { case withdrawUnsubmittedChange, releaseFinishedSource }
    public let id: UUID
    public let transfer: V2ManagedResourceTransferID
    public var effect: Effect { intent.workID == nil ? .withdrawUnsubmittedChange : .releaseFinishedSource }
    let incarnation: UUID
    let owner: UUID
    let intent: V2ProfileIntent
}

import Foundation
import IMV2Core

/// A queued intent has no expected revision until it reaches the head of its key.
public enum V2PersonalPreferenceTarget: Equatable, Codable, Sendable {
    case conversation(roomID: RoomID, isPinned: Bool, isArchived: Bool, muteUntil: Date?)
    case favorite(roomID: RoomID, messageID: MessageID, isFavorited: Bool)
    var kind: V2OperationKind {
        switch self { case .conversation: .conversationPreference; case .favorite: .messageFavorite }
    }
    var orderingKey: String {
        switch self {
        case .conversation(let room, _, _, _): "conversationPreference/\(room.rawValue)"
        case .favorite(let room, let message, _): "messageFavorite/\(room.rawValue)/\(message.rawValue)"
        }
    }
    func freeze(id: UUID, revision: V2PersonalPreferenceRevision, deadline: Date) throws -> V2FrozenPersonalPreference {
        guard let milliseconds = UInt64(exactly: (deadline.timeIntervalSince1970 * 1000).rounded(.towardZero)) else { throw V2OperationWorkError.invalidRecord }
        switch self {
        case .conversation(let room, let pinned, let archived, let mute):
            return .conversation(try .init(operationID: .init(id.uuidString), roomID: room, isPinned: pinned, isArchived: archived,
                muteUntil: mute, expectedRevision: revision, firstSubmissionDeadlineMilliseconds: milliseconds))
        case .favorite(let room, let message, let favorite):
            return .favorite(try .init(operationID: .init(id.uuidString), roomID: room, messageID: message, isFavorited: favorite,
                expectedRevision: revision, firstSubmissionDeadlineMilliseconds: milliseconds))
        }
    }
}

enum V2FrozenPersonalPreference: Equatable, Codable, Sendable {
    case conversation(V2ConversationStateCommand)
    case favorite(V2MessageFavoriteCommand)
    func identity(accountID: UserID) throws -> V2OperationIdentity {
        switch self { case .conversation(let command): try command.identity(actorUserID: accountID)
        case .favorite(let command): try command.identity(actorUserID: accountID) }
    }
    func fingerprint(accountID: UserID) throws -> V2OperationFingerprint {
        switch self { case .conversation(let command): try command.fingerprint(actorUserID: accountID)
        case .favorite(let command): try command.fingerprint(actorUserID: accountID) }
    }
    var expectedRevision: V2PersonalPreferenceRevision {
        switch self { case .conversation(let command): command.expectedRevision; case .favorite(let command): command.expectedRevision }
    }
    func validate(_ receipt: V2PersonalPreferenceReceipt, accountID: UserID) throws {
        guard receipt.identity == (try identity(accountID: accountID)), receipt.fingerprint == (try fingerprint(accountID: accountID)) else { throw V2OperationWorkError.identityConflict }
        switch (self, receipt.outcome) {
        case (.conversation(let command), .committed(.conversationState(let state))):
            guard state.isPinned == command.isPinned, state.isArchived == command.isArchived, state.muteUntil == command.muteUntil,
                  state.revision.rawValue > 0, state.revision.rawValue - 1 == command.expectedRevision.rawValue else { throw V2OperationWorkError.identityConflict }
        case (.favorite(let command), .committed(.messageFavorite(let state))):
            guard state.isFavorited == command.isFavorited, state.revision.rawValue > 0,
                  state.revision.rawValue - 1 == command.expectedRevision.rawValue else { throw V2OperationWorkError.identityConflict }
        case (_, .committed): throw V2OperationWorkError.identityConflict
        default: break
        }
    }
}

import Foundation
import IMV2Core
import IMV2ServerContracts

/// The persistence boundary preserves the separate replay, source-read,
/// pair-identity, and completion transactions used by a forward operation.
package protocol V2ForwardPersistence: Sendable {
    func replayedResults(actor: UserID, operation: MessageForwardOperationID,
                         sources: [V2ForwardMessageReference], targets: [RoomID],
                         ownerRoutes: [RoomID: V2RoomShardRoute]?) async throws -> [ForwardPairKey: V2ForwardMessageResult]
    func readSources(references: [V2ForwardMessageReference], actorUserID: UserID,
                     ownerRoutes: [RoomID: V2RoomShardRoute]?) async throws -> [ForwardSource]
    func clientMessageID(actor: UserID, operation: MessageForwardOperationID, source: MessageID,
                         target: RoomID, sourceRoomID: RoomID, sourceRevision: V2MessageRevision,
                         ownerRoutes: [RoomID: V2RoomShardRoute]?) async throws -> ClientMessageID
    func markResult(actor: UserID, operation: MessageForwardOperationID, source: MessageID,
                    target: RoomID, sourceRoomID: RoomID, message: MessageID,
                    ownerRoutes: [RoomID: V2RoomShardRoute]?) async throws
}

package struct ForwardSource: Sendable {
    package let reference: V2ForwardMessageReference
    package var messageID: MessageID { reference.messageID }
    package let outcome: ForwardSourceOutcome
    package init(reference: V2ForwardMessageReference, outcome: ForwardSourceOutcome) {
        self.reference = reference
        self.outcome = outcome
    }
}

package enum ForwardSourceOutcome: Sendable {
    case content(ForwardSourceContent)
    case unavailable(String)
}

package struct ForwardSourceContent: Sendable {
    package let senderUserID: UserID
    package let sourceRevision: V2MessageRevision
    package let text: String
    package let media: [V2MediaReference]
    package let entities: [V2MessageEntity]
    package init(senderUserID: UserID, sourceRevision: V2MessageRevision, text: String,
                 media: [V2MediaReference], entities: [V2MessageEntity]) {
        self.senderUserID = senderUserID
        self.sourceRevision = sourceRevision
        self.text = text
        self.media = media
        self.entities = entities
    }
}

package struct ForwardPairKey: Hashable, Sendable {
    package let source: MessageID
    package let target: RoomID
    package init(source: MessageID, target: RoomID) {
        self.source = source
        self.target = target
    }
}

package enum V2ForwardStoreError: Error {
    case notVisible, corrupt, sourceRevisionConflict
}

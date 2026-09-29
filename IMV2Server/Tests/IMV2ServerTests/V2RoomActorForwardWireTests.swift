@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("V2 room actor forward wire")
struct V2RoomActorForwardWireTests {
    @Test func exportKeepsExactBytesAndAllBindingFields() throws {
        let intent = V2ForwardExportIntent(version: 1, exportID: UUID(),
            actorUserID: UUID(), operationID: UUID(), sourceRoomID: UUID(),
            sourceMessageID: UUID(), sourceRevision: 7, sourceSenderUserID: UUID(),
            sourceShardID: "owner-a", sourceEpoch: 0, targetRoomID: UUID(),
            targetClientMessageID: UUID(), targetShardID: "owner-b", targetEpoch: 5,
            text: "forward body", entities: [], media: [.init(mediaID: UUID(),
                uploadSessionID: UUID(), contentType: "image/png", byteCount: 1024)])
        let domain = try V2ForwardExport(intent: intent)
        let wire = V2ActorForwardExportWire(domain: domain)
        let decoded = try JSONDecoder().decode(V2ActorForwardExportWire.self,
            from: JSONEncoder().encode(wire))
        #expect(decoded == wire)
        #expect(try decoded.toDomain() == domain)
        #expect(decoded.intent.sourceRevision == 7)
        #expect(decoded.intent.sourceEpoch == 0)
        #expect(decoded.intent.targetEpoch == 5)
        #expect(decoded.intent.media.count == 1)

        let forgedIntent = V2ActorForwardExportIntentWire(version: 1,
            exportID: intent.exportID, actorUserID: intent.actorUserID,
            operationID: intent.operationID, sourceRoomID: intent.sourceRoomID,
            sourceMessageID: intent.sourceMessageID, sourceRevision: 8,
            sourceSenderUserID: intent.sourceSenderUserID,
            sourceShardID: intent.sourceShardID, sourceEpoch: intent.sourceEpoch,
            targetRoomID: intent.targetRoomID,
            targetClientMessageID: intent.targetClientMessageID,
            targetShardID: intent.targetShardID, targetEpoch: intent.targetEpoch,
            text: intent.text, entities: intent.entities, media: wire.intent.media)
        let forged = V2ActorForwardExportWire(payload: wire.payload, digest: wire.digest,
            intent: forgedIntent)
        #expect(throws: V2ForwardExportError.corruptPersistenceState) { try forged.toDomain() }
    }

    @Test func invalidResultNeverConstructsDomainValue() throws {
        let source = try MessageID(UUID().uuidString)
        let target = try RoomID(UUID().uuidString)
        let message = try MessageID(UUID().uuidString)
        let invalid = V2ActorForwardMessageResultWire(sourceMessageID: source,
            targetRoomID: target, messageID: message, roomSequence: 0, errorCode: nil)
        #expect(throws: V2ForwardMessageResultValidationError.invalidSequence) {
            try invalid.toDomain()
        }
        let mixed = V2ActorForwardMessageResultWire(sourceMessageID: source,
            targetRoomID: target, messageID: message, roomSequence: 1,
            errorCode: "UNAVAILABLE")
        #expect(throws: V2ForwardMessageResultValidationError.invalidShape) {
            try mixed.toDomain()
        }
    }
}

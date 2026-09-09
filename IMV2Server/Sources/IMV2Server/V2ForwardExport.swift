import Crypto
import Foundation
import IMV2Core

/// A source-owner authorization, not a target acceptance receipt. Delivery must
/// transport these exact bytes; hashing a re-encoded JSON object is not valid.
public struct V2ForwardExport: Equatable, Sendable {
    public let payload: Data
    public let digest: Data
    public let intent: V2ForwardExportIntent

    init(intent: V2ForwardExportIntent) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(intent)
        try self.init(payload: payload, digest: Data(SHA256.hash(data: payload)))
    }

    init(payload: Data, digest: Data) throws {
        guard !payload.isEmpty, payload.count <= 1_048_576,
              digest.count == 32, Data(SHA256.hash(data: payload)) == digest
        else { throw V2ForwardExportError.corruptPersistenceState }
        let intent = try JSONDecoder().decode(V2ForwardExportIntent.self, from: payload)
        guard intent.version == 1, intent.sourceRevision > 0,
              intent.sourceEpoch >= 0, intent.targetEpoch >= 0,
              !intent.sourceShardID.isEmpty, !intent.targetShardID.isEmpty,
              intent.media.count <= V2MessageCommandLimits.maxMediaAttachments,
              Set(intent.media.map(\.mediaID)).count == intent.media.count,
              intent.media.allSatisfy({ $0.byteCount > 0 && !$0.contentType.isEmpty && $0.contentType.utf8.count <= 127 })
        else { throw V2ForwardExportError.corruptPersistenceState }
        try V2RichMessageContent.validate(text: intent.text, entities: intent.entities)
        self.payload = payload
        self.digest = digest
        self.intent = intent
    }
}

/// No download URL or provider credential is part of a durable export. The
/// digest binds this manifest's metadata, not the still-to-be-imported bytes.
public struct V2ForwardExportMedia: Codable, Equatable, Sendable {
    public let mediaID: UUID
    public let uploadSessionID: UUID
    public let contentType: String
    public let byteCount: Int64
}

public struct V2ForwardExportIntent: Codable, Equatable, Sendable {
    public let version: Int
    public let exportID: UUID
    public let actorUserID: UUID
    public let operationID: UUID
    public let sourceRoomID: UUID
    public let sourceMessageID: UUID
    public let sourceRevision: Int64
    public let sourceSenderUserID: UUID
    public let sourceShardID: String
    public let sourceEpoch: Int64
    public let targetRoomID: UUID
    public let targetClientMessageID: UUID
    public let targetShardID: String
    public let targetEpoch: Int64
    public let text: String
    public let entities: [V2MessageEntity]
    public let media: [V2ForwardExportMedia]
}

public enum V2ForwardExportError: Error, Equatable, Sendable {
    case invalidRequest
    case sourceUnavailable
    case sourceChanged
    case mediaUnavailable
    case ownerChanged
    case idempotencyConflict
    case capacityExceeded
    case corruptPersistenceState
}

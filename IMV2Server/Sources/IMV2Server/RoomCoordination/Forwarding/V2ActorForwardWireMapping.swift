import Foundation
import IMV2ActorContracts
import IMV2Core

extension V2ActorForwardMessageResultWire {
    init(domain: V2ForwardMessageResult) {
        self.init(sourceMessageID: domain.sourceMessageID, targetRoomID: domain.targetRoomID,
                  messageID: domain.messageID, roomSequence: domain.roomSequence,
                  errorCode: domain.errorCode)
    }

    func toDomain() throws -> V2ForwardMessageResult {
        try .init(sourceMessageID: sourceMessageID, targetRoomID: targetRoomID,
                  messageID: messageID, roomSequence: roomSequence, errorCode: errorCode)
    }
}

extension V2ActorForwardExportWire {
    init(domain: V2ForwardExport) {
        self.init(payload: domain.payload, digest: domain.digest,
                  intent: .init(domain: domain.intent))
    }

    func toDomain() throws -> V2ForwardExport {
        let validated = try V2ForwardExport(payload: payload, digest: digest)
        guard validated.intent == intent.toDomain() else {
            throw V2ForwardExportError.corruptPersistenceState
        }
        return validated
    }
}

extension V2ActorForwardExportIntentWire {
    init(domain: V2ForwardExportIntent) {
        self.init(version: domain.version, exportID: domain.exportID,
                  actorUserID: domain.actorUserID, operationID: domain.operationID,
                  sourceRoomID: domain.sourceRoomID, sourceMessageID: domain.sourceMessageID,
                  sourceRevision: domain.sourceRevision,
                  sourceSenderUserID: domain.sourceSenderUserID,
                  sourceShardID: domain.sourceShardID, sourceEpoch: domain.sourceEpoch,
                  targetRoomID: domain.targetRoomID,
                  targetClientMessageID: domain.targetClientMessageID,
                  targetShardID: domain.targetShardID, targetEpoch: domain.targetEpoch,
                  text: domain.text, entities: domain.entities,
                  media: domain.media.map(V2ActorForwardExportMediaWire.init(domain:)))
    }

    func toDomain() -> V2ForwardExportIntent {
        .init(version: version, exportID: exportID, actorUserID: actorUserID,
              operationID: operationID, sourceRoomID: sourceRoomID,
              sourceMessageID: sourceMessageID, sourceRevision: sourceRevision,
              sourceSenderUserID: sourceSenderUserID, sourceShardID: sourceShardID,
              sourceEpoch: sourceEpoch, targetRoomID: targetRoomID,
              targetClientMessageID: targetClientMessageID, targetShardID: targetShardID,
              targetEpoch: targetEpoch, text: text, entities: entities,
              media: media.map { $0.toDomain() })
    }
}

extension V2ActorForwardExportMediaWire {
    init(domain: V2ForwardExportMedia) {
        self.init(mediaID: domain.mediaID, uploadSessionID: domain.uploadSessionID,
                  contentType: domain.contentType, byteCount: domain.byteCount)
    }

    func toDomain() -> V2ForwardExportMedia {
        .init(mediaID: mediaID, uploadSessionID: uploadSessionID,
              contentType: contentType, byteCount: byteCount)
    }
}

extension V2ActorForwardImportOutcomeWire {
    init(domain: V2ForwardImportOutcome) {
        switch domain {
        case .accepted(let id, let sequence): self = .accepted(messageID: id, roomSequence: sequence)
        case .rejected(let code): self = .rejected(code: code)
        case .pending(let reason): self = .pending(.init(domain: reason))
        }
    }

    func toDomain() throws -> V2ForwardImportOutcome {
        switch self {
        case .accepted(let id, let sequence):
            guard sequence > 0, sequence <= UInt64(Int64.max) else {
                throw V2ForwardInboxError.corruptPersistenceState
            }
            return .accepted(messageID: id, roomSequence: sequence)
        case .rejected(let code): return .rejected(code: code)
        case .pending(let reason): return .pending(reason.toDomain())
        }
    }
}

extension V2ActorForwardImportPendingReasonWire {
    init(domain: V2ForwardImportPendingReason) {
        switch domain {
        case .media: self = .media
        case .admission: self = .admission
        case .finalization: self = .finalization
        }
    }

    func toDomain() -> V2ForwardImportPendingReason {
        switch self {
        case .media: .media
        case .admission: .admission
        case .finalization: .finalization
        }
    }
}

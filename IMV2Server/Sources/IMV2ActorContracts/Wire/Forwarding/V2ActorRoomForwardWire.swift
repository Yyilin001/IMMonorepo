import Foundation
import IMV2Core

/// 一对分别提交的源与目标。分发必须使用协调器规范的双房间预留，
/// 不能使用普通房间轮次。
public struct V2ActorForwardPairWire: Codable, Equatable, Sendable {
    public let actorUserID: UserID
    public let operationID: MessageForwardOperationID
    public let source: V2ForwardMessageReference
    public let targetRoomID: RoomID

    public init(actorUserID: UserID, operationID: MessageForwardOperationID,
                source: V2ForwardMessageReference, targetRoomID: RoomID) {
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.source = source
        self.targetRoomID = targetRoomID
    }
}

/// 可信协调器的源房间导出请求。源位置来自有效令牌；
/// 目标路由是持久化的控制侧选择。
public struct V2ActorPrepareForwardExportWire: Codable, Equatable, Sendable {
    public let actorUserID: UserID
    public let operationID: MessageForwardOperationID
    public let source: V2ForwardMessageReference
    public let targetRoomID: RoomID
    public let targetShardID: String
    public let targetEpoch: Int64

    public init(actorUserID: UserID, operationID: MessageForwardOperationID,
                source: V2ForwardMessageReference, targetRoomID: RoomID,
                targetShardID: String, targetEpoch: Int64) {
        self.actorUserID = actorUserID; self.operationID = operationID
        self.source = source; self.targetRoomID = targetRoomID
        self.targetShardID = targetShardID; self.targetEpoch = targetEpoch
    }
}

/// 只有可信投递工作器才能提交此目标方生成的回执。
public struct V2ActorRecordForwardReceiptWire: Codable, Equatable, Sendable {
    public let sourceRoomID: RoomID
    public let actorUserID: UserID
    public let exportID: UUID
    public let payloadDigest: Data
    public let outcome: V2ActorForwardImportOutcomeWire

    public init(sourceRoomID: RoomID, actorUserID: UserID, exportID: UUID, payloadDigest: Data,
                outcome: V2ActorForwardImportOutcomeWire) {
        self.sourceRoomID = sourceRoomID; self.actorUserID = actorUserID; self.exportID = exportID
        self.payloadDigest = payloadDigest; self.outcome = outcome
    }
}

/// 可信目标导入：其摘要绑定精确的规范导出字节。
public struct V2ActorForwardExportWire: Codable, Equatable, Sendable {
    public let payload: Data
    public let digest: Data
    public let intent: V2ActorForwardExportIntentWire

    public init(payload: Data, digest: Data, intent: V2ActorForwardExportIntentWire) {
        self.payload = payload
        self.digest = digest
        self.intent = intent
    }
}

public struct V2ActorForwardExportMediaWire: Codable, Equatable, Sendable {
    public let mediaID: UUID
    public let uploadSessionID: UUID
    public let contentType: String
    public let byteCount: Int64

    public init(mediaID: UUID, uploadSessionID: UUID, contentType: String, byteCount: Int64) {
        self.mediaID = mediaID
        self.uploadSessionID = uploadSessionID
        self.contentType = contentType
        self.byteCount = byteCount
    }
}

public struct V2ActorForwardExportIntentWire: Codable, Equatable, Sendable {
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
    public let media: [V2ActorForwardExportMediaWire]

    public init(version: Int, exportID: UUID, actorUserID: UUID, operationID: UUID,
                sourceRoomID: UUID, sourceMessageID: UUID, sourceRevision: Int64,
                sourceSenderUserID: UUID, sourceShardID: String, sourceEpoch: Int64,
                targetRoomID: UUID, targetClientMessageID: UUID, targetShardID: String,
                targetEpoch: Int64, text: String, entities: [V2MessageEntity],
                media: [V2ActorForwardExportMediaWire]) {
        self.version = version; self.exportID = exportID; self.actorUserID = actorUserID
        self.operationID = operationID; self.sourceRoomID = sourceRoomID
        self.sourceMessageID = sourceMessageID; self.sourceRevision = sourceRevision
        self.sourceSenderUserID = sourceSenderUserID; self.sourceShardID = sourceShardID
        self.sourceEpoch = sourceEpoch; self.targetRoomID = targetRoomID
        self.targetClientMessageID = targetClientMessageID; self.targetShardID = targetShardID
        self.targetEpoch = targetEpoch; self.text = text; self.entities = entities
        self.media = media
    }
}

public enum V2RoomForwardCommand: Codable, Equatable, Sendable {
    case sameOwnerPair(V2ActorForwardPairWire)
    case prepareExport(V2ActorPrepareForwardExportWire)
    case recoverExport(V2ActorForwardPairWire, action: V2OperationRecoveryRequest.Action)
    case recordReceipt(V2ActorRecordForwardReceiptWire)
    case importExport(V2ActorForwardExportWire)

    public var roomID: RoomID {
        switch self {
        case .sameOwnerPair(let value): value.targetRoomID
        case .prepareExport(let value): value.source.roomID
        case .recoverExport(let value, _): value.source.roomID
        case .recordReceipt(let value): value.sourceRoomID
        case .importExport(let value): RoomID(uuid: value.intent.targetRoomID)
        }
    }

    public var actorUserID: UserID {
        switch self {
        case .sameOwnerPair(let value): value.actorUserID
        case .prepareExport(let value): value.actorUserID
        case .recoverExport(let value, _): value.actorUserID
        case .recordReceipt(let value): value.actorUserID
        case .importExport(let value): UserID(uuid: value.intent.actorUserID)
        }
    }

    public var retryPolicy: V2RoomReplayPolicy { .durableIdempotent }
    public var requiresReservation: Bool {
        if case .sameOwnerPair = self { return true }
        return false
    }
}

public struct V2ActorForwardMessageResultWire: Codable, Equatable, Sendable {
    public let sourceMessageID: MessageID
    public let targetRoomID: RoomID
    public let messageID: MessageID?
    public let roomSequence: UInt64?
    public let errorCode: String?

    public init(sourceMessageID: MessageID, targetRoomID: RoomID, messageID: MessageID?,
                roomSequence: UInt64?, errorCode: String?) {
        self.sourceMessageID = sourceMessageID; self.targetRoomID = targetRoomID
        self.messageID = messageID; self.roomSequence = roomSequence; self.errorCode = errorCode
    }
}

public enum V2ActorForwardImportOutcomeWire: Codable, Equatable, Sendable {
    case accepted(messageID: MessageID, roomSequence: UInt64)
    case rejected(code: String)
    case pending(V2ActorForwardImportPendingReasonWire)
}

public enum V2ActorForwardImportPendingReasonWire: String, Codable, Equatable, Sendable {
    case media, admission, finalization
}

public enum V2RoomForwardResult: Codable, Equatable, Sendable {
    case failure(V2ActorForwardFailureWire)
    case pair(V2ActorForwardMessageResultWire)
    case preparedExport(V2ActorForwardExportWire)
    case terminalExport(V2ActorForwardImportOutcomeWire)
    case unresolvedExport
    case receiptRecorded
    case imported(V2ActorForwardImportOutcomeWire)
}

/// 仅表示业务失败。租约或所有者变更、SQL 完成结果不明
/// 由运行时失败信封传递，不能转成业务拒绝。
public enum V2ActorForwardFailureWire: Codable, Equatable, Sendable {
    case export(V2ActorForwardExportFailureWire)
    case inbox(V2ActorForwardInboxFailureWire)
}
public enum V2ActorForwardExportFailureWire: String, Codable, Equatable, Sendable {
    case invalidRequest, sourceUnavailable, sourceChanged, mediaUnavailable
    case idempotencyConflict, capacityExceeded, payloadCompacted
}
public enum V2ActorForwardInboxFailureWire: String, Codable, Equatable, Sendable {
    case targetNotFound, idempotencyConflict, capacityExceeded
}

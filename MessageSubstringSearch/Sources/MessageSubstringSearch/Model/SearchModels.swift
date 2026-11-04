import Foundation

public enum SearchTextMode: String, Codable, Sendable { case literal, asciiCaseInsensitive, compatibilityCaseInsensitive }
public enum ContentCoverage: String, Codable, Sendable { case fullText, previewOnly }

public struct SearchField: Codable, Equatable, Sendable {
    public let id: String
    public let text: String
    public init(id: String = "body", text: String) { self.id = id; self.text = text }
}

/// ID 必须在本账号内稳定唯一；来源版本必须可以比较，不能用回调到达时间冒充。
public struct SearchDocument: Codable, Equatable, Sendable {
    public let id: String
    public let groupID: String
    public let version: Int64
    public let timestamp: Int64
    public let kind: String
    public let coverage: ContentCoverage
    public let fields: [SearchField]
    public init(id: String, groupID: String, version: Int64, timestamp: Int64,
                kind: String = "text", coverage: ContentCoverage = .fullText, fields: [SearchField]) {
        self.id = id; self.groupID = groupID; self.version = version; self.timestamp = timestamp
        self.kind = kind; self.coverage = coverage; self.fields = fields
    }
}

public enum IndexOperation: Codable, Equatable, Sendable {
    case upsert(SearchDocument)
    case delete(documentID: String, version: Int64)
    /// 同一来源内的全局版本屏障；比清空版本旧的消息不会复活。
    case clearGroup(groupID: String, version: Int64)
}

public struct IndexChange: Codable, Equatable, Sendable {
    public let eventID: String
    public let operation: IndexOperation
    public init(eventID: String, operation: IndexOperation) { self.eventID = eventID; self.operation = operation }
}

/// 不解释来源游标；CAS 防止并发生产者越过未持久接收的来源范围。
public struct SourceCheckpoint: Sendable {
    public let expected: String
    public let next: String
    public init(expected: String, next: String) { self.expected = expected; self.next = next }
}

public struct IndexReceipt: Codable, Equatable, Sendable {
    public let sequence: Int64
    public let storeID: String
}

public enum SourceCoverage: Codable, Equatable, Sendable {
    case unknown
    case catchingUp
    /// 仅用于来源明确保证该游标之前的历史/变更已完整读取的情况。
    case caughtUp(through: String)
}

public struct SearchConfiguration: Sendable {
    public var path: String
    public var scopeID: String
    public var sourceEpoch: String
    public var mode: SearchTextMode = .asciiCaseInsensitive
    /// 显式允许恢复库中已提交的模式，用于模式切换时崩溃后判断实际提交状态。
    public var useStoredTextMode = false
    public var automaticallyProcess = true
    public var maximumBatchCount = 100
    public var maximumBatchBytes = 2 * 1_048_576
    public var maximumDocumentBytes = 1_048_576
    public var maximumQueryCharacters = 128
    public var chunkCharacters = 512
    public var maximumQueuedBytes = 8 * 1_048_576
    public var maximumInboxBytes = 64 * 1_048_576
    public var maximumInboxCount = 10_000
    public var processingBatchCount = 100
    public var processingBatchBytes = 256 * 1024
    public var maximumResults = 5_000
    public var snapshotLifetimeSeconds: Double = 60
    public var queryTimeoutSeconds: Double = 0.3
    public var metricsEnabled = true
    public var statementCacheCapacity = 64

    public init(path: String, scopeID: String, sourceEpoch: String) {
        self.path = path; self.scopeID = scopeID; self.sourceEpoch = sourceEpoch
    }

    func validate() throws {
        guard !path.isEmpty, path != ":memory:", !path.utf8.contains(0), !scopeID.isEmpty, !sourceEpoch.isEmpty,
              maximumBatchCount > 0, maximumBatchBytes > 0, maximumDocumentBytes > 0, (0...256).contains(statementCacheCapacity),
              (1...4096).contains(maximumQueryCharacters), chunkCharacters >= maximumQueryCharacters,
              maximumQueuedBytes > 0, maximumInboxBytes > 0, maximumInboxCount > 0,
              processingBatchCount > 0, processingBatchBytes > 0,
              (1...100_000).contains(maximumResults), snapshotLifetimeSeconds.isFinite,
              snapshotLifetimeSeconds > 0, queryTimeoutSeconds.isFinite, queryTimeoutSeconds > 0 else {
            throw SearchIndexError.invalidArgument("invalid configuration; a dedicated file is required")
        }
    }
}

public enum SearchIndexError: Error, Equatable, Sendable {
    case invalidArgument(String)
    case incompatibleIndex
    case alreadyOpen
    case staleCursor
    case emptyQuery
    case closed
    case backpressure
    case timeout
    case checkpointConflict
    case conflictingEvent(String)
    case failedEvent(sequence: Int64, code: String)
    case unsupportedCapability(String)
    case sqlite(code: Int32, message: String)
}

public struct SearchRequest: Equatable, Sendable {
    public var text: String
    public var groupID: String?
    public var kind: String?
    public var fromTimestamp: Int64?
    public var throughTimestamp: Int64?
    public var pageSize: Int
    public init(_ text: String, groupID: String? = nil, kind: String? = nil,
                fromTimestamp: Int64? = nil, throughTimestamp: Int64? = nil, pageSize: Int = 50) {
        self.text = text; self.groupID = groupID; self.kind = kind
        self.fromTimestamp = fromTimestamp; self.throughTimestamp = throughTimestamp; self.pageSize = pageSize
    }
}

public struct SearchCursor: Sendable {
    let snapshotID: UUID
    let offset: Int
}

public struct TextRange: Codable, Equatable, Sendable {
    public let location: Int
    public let length: Int
}

public struct SearchHit: Sendable {
    public let document: SearchDocument
    public let fieldID: String
    public let contentHash: String
    /// 原文 UTF-16 范围；仅适用于上面 document 的该字段版本。
    public let ranges: [TextRange]
}

public struct IndexStatus: Codable, Sendable {
    public let sourceCoverage: SourceCoverage
    public let textMode: SearchTextMode
    public let documentCount: Int64
    public let previewOnlyCount: Int64
    public let pendingCount: Int64
    public let pendingBytes: Int64
    public let failedCount: Int64
    public let oldestPendingSeconds: Double
    public let acceptedSequence: Int64
    public let indexedSequence: Int64
    public let acceptedSourceCheckpoint: String
    public let indexedSourceCheckpoint: String
    public let generation: Int64
    public let rebuilding: Bool
    public let databaseBytes: Int64
    public let walBytes: Int64
    /// 此处只说明“已接收事件”处理完成，不能推断来源历史已全部覆盖。
    public var acceptedEventsIndexed: Bool { pendingCount == 0 && failedCount == 0 }
    public var sourceAndIndexCaughtUp: Bool {
        guard case .caughtUp(let cursor) = sourceCoverage else { return false }
        return acceptedEventsIndexed && acceptedSourceCheckpoint == cursor && indexedSourceCheckpoint == cursor
    }
}

public struct SearchPage: Sendable {
    public let hits: [SearchHit]
    public let nextCursor: SearchCursor?
    public let resultsTruncated: Bool
    public let status: IndexStatus
}

public struct SQLiteCapabilities: Codable, Sendable {
    public let version: String
    public let sourceID: String
    public let compileOptions: [String]
    public let fts5: Bool
}

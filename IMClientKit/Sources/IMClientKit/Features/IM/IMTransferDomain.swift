import Foundation

public struct TransferTaskID: Codable, Equatable, Hashable, Sendable {
    public let sessionIdentifier: String
    public let taskIdentifier: Int

    public init(sessionIdentifier: String, taskIdentifier: Int) {
        self.sessionIdentifier = sessionIdentifier
        self.taskIdentifier = taskIdentifier
    }

    public var backgroundTransferReference: IMMessageBackgroundTransferReference {
        IMMessageBackgroundTransferReference(
            sessionIdentifier: sessionIdentifier,
            taskIdentifier: taskIdentifier
        )
    }
}

public enum TransferKind: String, Codable, Equatable, Sendable {
    case upload
    case download
}

public enum TransferIntent: String, Codable, Equatable, Sendable {
    case messageMediaUpload
    case messageMediaDownload
    case demoFileTransfer
}

public extension TransferIntent {
    static let mediaUpload = Self.messageMediaUpload
    static let mediaDownload = Self.messageMediaDownload
    static let fileDemoUpload = Self.demoFileTransfer
    static let fileDemoDownload = Self.demoFileTransfer
}

public enum TransferState: Codable, Equatable, Sendable {
    case running(progress: IMMessageLocalDownloadProgressSnapshot?)
    case waitingForConnectivity(progress: IMMessageLocalDownloadProgressSnapshot?)
    case completed
    case cancelled(progress: IMMessageLocalDownloadProgressSnapshot?)
    case failed(
        message: String,
        shouldPreserveSession: Bool,
        shouldMarkServerOffline: Bool
    )
}

public struct TransferSnapshot: Codable, Equatable, Sendable {
    public let taskID: TransferTaskID
    public let kind: TransferKind
    public let intent: TransferIntent
    public let state: TransferState
    public let destinationURL: URL?
    public let sourceFilePath: String?
    public let uploadID: String?

    public init(
        taskID: TransferTaskID,
        kind: TransferKind,
        intent: TransferIntent,
        state: TransferState,
        destinationURL: URL?,
        sourceFilePath: String? = nil,
        uploadID: String? = nil
    ) {
        self.taskID = taskID
        self.kind = kind
        self.intent = intent
        self.state = state
        self.destinationURL = destinationURL
        self.sourceFilePath = sourceFilePath
        self.uploadID = uploadID
    }
}

public struct TransferStore: Sendable {
    private var snapshotsByTaskID: [TransferTaskID: TransferSnapshot] = [:]

    public init() { }

    public mutating func replace(with snapshots: [TransferSnapshot]) {
        snapshotsByTaskID = Dictionary(
            uniqueKeysWithValues: snapshots.map { ($0.taskID, $0) }
        )
    }

    public mutating func replace(with backgroundSnapshots: [BackgroundTransferSnapshot]) {
        merge(backgroundSnapshots)
    }

    @discardableResult
    public mutating func apply(_ backgroundSnapshot: BackgroundTransferSnapshot) -> TransferSnapshot {
        let snapshot = backgroundSnapshot.imTransferSnapshot
        snapshotsByTaskID[snapshot.taskID] = snapshot
        return snapshot
    }

    public mutating func merge(_ backgroundSnapshots: [BackgroundTransferSnapshot]) {
        for snapshot in backgroundSnapshots {
            let transferSnapshot = snapshot.imTransferSnapshot
            snapshotsByTaskID[transferSnapshot.taskID] = transferSnapshot
        }
    }

    public func snapshots(kind: TransferKind? = nil) -> [TransferSnapshot] {
        snapshotsByTaskID.values
            .filter { kind == nil || $0.kind == kind }
            .sorted {
                if $0.taskID.sessionIdentifier == $1.taskID.sessionIdentifier {
                    return $0.taskID.taskIdentifier < $1.taskID.taskIdentifier
                }
                return $0.taskID.sessionIdentifier < $1.taskID.sessionIdentifier
            }
    }

    public func snapshot(for taskID: TransferTaskID) -> TransferSnapshot? {
        snapshotsByTaskID[taskID]
    }
}

public typealias IMTransferTaskID = TransferTaskID
public typealias IMTransferKind = TransferKind
public typealias IMTransferIntent = TransferIntent
public typealias IMTransferState = TransferState
public typealias IMTransferSnapshot = TransferSnapshot
public typealias IMTransferStore = TransferStore

public extension BackgroundTransferSnapshot {
    var imTransferSnapshot: TransferSnapshot {
        let transferKind: TransferKind = switch kind {
        case .upload:
            .upload
        case .download:
            .download
        }
        let intent: TransferIntent
        switch transferKind {
        case .upload:
            intent = .messageMediaUpload
        case .download:
            intent = .messageMediaDownload
        }

        let progressSnapshot = progress.map(IMMessageLocalDownloadProgressSnapshot.init)
        let transferState: TransferState = switch state {
        case .running:
            .running(progress: progressSnapshot)
        case .waitingForConnectivity:
            .waitingForConnectivity(progress: progressSnapshot)
        case .completed:
            .completed
        case .cancelled:
            .cancelled(progress: progressSnapshot)
        case .failed(let failure):
            .failed(
                message: failure.message,
                shouldPreserveSession: failure.shouldPreserveSession,
                shouldMarkServerOffline: failure.shouldMarkServerOffline
            )
        }

        return TransferSnapshot(
            taskID: TransferTaskID(
                sessionIdentifier: sessionIdentifier,
                taskIdentifier: taskIdentifier
            ),
            kind: transferKind,
            intent: intent,
            state: transferState,
            destinationURL: destinationURL
        )
    }
}

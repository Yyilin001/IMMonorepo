import Foundation

public struct IMTransferTaskID: Codable, Equatable, Hashable, Sendable {
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

public enum IMTransferKind: String, Codable, Equatable, Sendable {
    case upload
    case download
}

public enum IMTransferState: Codable, Equatable, Sendable {
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

public struct IMTransferSnapshot: Codable, Equatable, Sendable {
    public let taskID: IMTransferTaskID
    public let kind: IMTransferKind
    public let state: IMTransferState
    public let destinationURL: URL?

    public init(
        taskID: IMTransferTaskID,
        kind: IMTransferKind,
        state: IMTransferState,
        destinationURL: URL?
    ) {
        self.taskID = taskID
        self.kind = kind
        self.state = state
        self.destinationURL = destinationURL
    }
}

public struct IMTransferStore: Sendable {
    private var snapshotsByTaskID: [IMTransferTaskID: IMTransferSnapshot] = [:]

    public init() { }

    public mutating func replace(with backgroundSnapshots: [BackgroundTransferSnapshot]) {
        snapshotsByTaskID = Dictionary(
            uniqueKeysWithValues: backgroundSnapshots.map {
                let snapshot = $0.imTransferSnapshot
                return (snapshot.taskID, snapshot)
            }
        )
    }

    @discardableResult
    public mutating func apply(_ backgroundSnapshot: BackgroundTransferSnapshot) -> IMTransferSnapshot {
        let snapshot = backgroundSnapshot.imTransferSnapshot
        snapshotsByTaskID[snapshot.taskID] = snapshot
        return snapshot
    }

    public func snapshots(kind: IMTransferKind? = nil) -> [IMTransferSnapshot] {
        snapshotsByTaskID.values
            .filter { kind == nil || $0.kind == kind }
            .sorted {
                if $0.taskID.sessionIdentifier == $1.taskID.sessionIdentifier {
                    return $0.taskID.taskIdentifier < $1.taskID.taskIdentifier
                }
                return $0.taskID.sessionIdentifier < $1.taskID.sessionIdentifier
            }
    }

    public func snapshot(for taskID: IMTransferTaskID) -> IMTransferSnapshot? {
        snapshotsByTaskID[taskID]
    }
}

public extension BackgroundTransferSnapshot {
    var imTransferSnapshot: IMTransferSnapshot {
        let kind: IMTransferKind = switch kind {
        case .upload:
            .upload
        case .download:
            .download
        }

        let progressSnapshot = progress.map(IMMessageLocalDownloadProgressSnapshot.init)
        let state: IMTransferState = switch state {
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

        return IMTransferSnapshot(
            taskID: IMTransferTaskID(
                sessionIdentifier: sessionIdentifier,
                taskIdentifier: taskIdentifier
            ),
            kind: kind,
            state: state,
            destinationURL: destinationURL
        )
    }
}

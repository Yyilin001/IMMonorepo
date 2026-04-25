import Foundation

public struct TransferProjectionState {
    public init() {}

    public func localDownloadState(
        from snapshot: IMTransferSnapshot,
        destinationFilePath: String,
        existing: IMMessageLocalDownloadState?
    ) -> IMMessageLocalDownloadState {
        let status: IMMessageLocalDownloadStatus = switch snapshot.state {
        case .running(let progress):
            .downloading(
                progress: progress,
                backgroundTransfer: snapshot.taskID.backgroundTransferReference
            )
        case .waitingForConnectivity(let progress):
            .waitingForConnectivity(
                progress: progress,
                backgroundTransfer: snapshot.taskID.backgroundTransferReference
            )
        case .completed:
            .downloaded
        case .cancelled(let progress):
            .paused(progress: progress ?? existing?.pausedProgress)
        case .failed(let message, _, _):
            .failed(message: message)
        }

        return IMMessageLocalDownloadState(
            destinationFilePath: destinationFilePath,
            status: status,
            taskID: snapshot.taskID
        )
    }

    public func backgroundStatusMessage(for snapshot: IMTransferSnapshot, verb: String) -> String {
        switch snapshot.state {
        case .running(let progress):
            if let progress {
                return progressMessage(prefix: "后台\(verb)中", progress: progress.progress)
            }
            return "后台\(verb)恢复中..."
        case .waitingForConnectivity(let progress):
            if let progress {
                return progressMessage(prefix: "后台\(verb)等待网络", progress: progress.progress)
            }
            return "后台\(verb)等待网络..."
        case .completed:
            return "后台\(verb)完成。"
        case .cancelled:
            return "后台\(verb)已取消。"
        case .failed(let message, _, _):
            return message
        }
    }

    private func progressMessage(prefix: String, progress: FileTransferProgress) -> String {
        if let total = progress.totalBytes, total > 0 {
            let percentage = Int((Double(progress.transferredBytes) / Double(total)) * 100)
            return "\(prefix)：\(percentage)% (\(progress.transferredBytes)/\(total) 字节)"
        }
        return "\(prefix)：已传输 \(progress.transferredBytes) 字节"
    }
}

private extension IMMessageLocalDownloadState {
    var pausedProgress: IMMessageLocalDownloadProgressSnapshot? {
        switch status {
        case .downloading(let progress, _), .waitingForConnectivity(let progress, _), .paused(let progress):
            return progress
        case .downloaded, .failed:
            return nil
        }
    }
}

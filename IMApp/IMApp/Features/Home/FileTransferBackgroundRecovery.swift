import Foundation
import IMClientKit

@MainActor
extension FileTransferManager {
    func observeBackgroundTransfers() {
        let updates = backgroundTransferMonitor.updates()
        applyRecoveredBackgroundTransfers(backgroundTransferMonitor.currentSnapshots())

        backgroundTransferUpdatesTask = Task { [weak self] in
            guard let self else {
                return
            }

            for await snapshot in updates {
                await self.applyBackgroundTransferUpdate(snapshot)
            }
        }
    }

    func applyRecoveredBackgroundTransfers(
        _ snapshots: [BackgroundTransferSnapshot],
        excludingTaskID: IMTransferTaskID? = nil
    ) {
        let recoverableSnapshots: [BackgroundTransferSnapshot]
        if let excludingTaskID {
            recoverableSnapshots = snapshots.filter { snapshot in
                snapshot.sessionIdentifier != excludingTaskID.sessionIdentifier
                    || snapshot.taskIdentifier != excludingTaskID.taskIdentifier
            }
        } else {
            recoverableSnapshots = snapshots
        }

        transferStore.replace(with: recoverableSnapshots)

        if uploadTask == nil, uploadOperation == nil {
            trackedBackgroundUpload = transferStore.snapshots(kind: .upload).first
            if let snapshot = trackedBackgroundUpload {
                isUploading = true
                uploadProgress = snapshot.imBackgroundProgress
                uploadStatus = transferProjectionState.backgroundStatusMessage(
                    for: snapshot,
                    verb: "上传"
                )
            }
        }

        if downloadTask == nil, downloadOperation == nil {
            trackedBackgroundDownload = transferStore.snapshots(kind: .download).first
            if let snapshot = trackedBackgroundDownload {
                isDownloading = true
                downloadProgress = snapshot.imBackgroundProgress
                downloadStatus = transferProjectionState.backgroundStatusMessage(
                    for: snapshot,
                    verb: "下载"
                )
            }
        }
    }

    func applyBackgroundTransferUpdate(_ snapshot: BackgroundTransferSnapshot) async {
        if applyRecoveredBackgroundDownloadCompletion(snapshot) {
            return
        }

        let transferSnapshot = transferStore.apply(snapshot)
        switch transferSnapshot.kind {
        case .upload:
            await applyUploadBackgroundSnapshot(transferSnapshot)
        case .download:
            await applyDownloadBackgroundSnapshot(transferSnapshot)
        }
    }

    @discardableResult
    func applyRecoveredBackgroundDownloadCompletion(_ snapshot: BackgroundTransferSnapshot) -> Bool {
        guard snapshot.kind == .download,
              case .completed = snapshot.state
        else {
            return false
        }

        let transferSnapshot = snapshot.imTransferSnapshot
        if let trackedBackgroundDownload,
           trackedBackgroundDownload.taskID != transferSnapshot.taskID,
           downloadTask != nil || downloadOperation != nil {
            return true
        }

        trackedBackgroundDownload = nil
        isDownloading = false
        downloadProgress = nil
        downloadedFileURL = snapshot.destinationURL
        downloadStatus = "后台下载完成：\(snapshot.destinationURL?.lastPathComponent ?? "文件已保存")"
        delegate?.fileTransferManagerDidSucceed()
        return true
    }

    private func applyUploadBackgroundSnapshot(_ snapshot: IMTransferSnapshot) async {
        if uploadTask != nil || uploadOperation != nil {
            return
        }

        switch snapshot.state {
        case .running, .waitingForConnectivity:
            trackedBackgroundUpload = snapshot
            isUploading = true
            uploadProgress = snapshot.imBackgroundProgress
            uploadStatus = transferProjectionState.backgroundStatusMessage(
                for: snapshot,
                verb: "上传"
            )
        case .completed:
            guard trackedBackgroundUpload?.taskID == snapshot.taskID else {
                return
            }
            trackedBackgroundUpload = nil
            isUploading = false
            uploadProgress = nil
            uploadStatus = "后台上传完成。"
            delegate?.fileTransferManagerDidSucceed()
            applyRecoveredBackgroundTransfers(
                backgroundTransferMonitor.currentSnapshots(),
                excludingTaskID: snapshot.taskID
            )
        case .cancelled:
            guard trackedBackgroundUpload?.taskID == snapshot.taskID else {
                return
            }
            trackedBackgroundUpload = nil
            isUploading = false
            uploadProgress = nil
            uploadStatus = "后台上传已取消。"
            applyRecoveredBackgroundTransfers(
                backgroundTransferMonitor.currentSnapshots(),
                excludingTaskID: snapshot.taskID
            )
        case .failed(let message, let shouldPreserveSession, let shouldMarkServerOffline):
            guard trackedBackgroundUpload?.taskID == snapshot.taskID else {
                return
            }
            trackedBackgroundUpload = nil
            isUploading = false
            uploadProgress = nil
            uploadStatus = message
            await delegate?.fileTransferManagerDidReceiveFailure(
                ProbeFailureContext(
                    message: message,
                    shouldPreserveSession: shouldPreserveSession,
                    shouldMarkServerOffline: shouldMarkServerOffline
                )
            )
            applyRecoveredBackgroundTransfers(
                backgroundTransferMonitor.currentSnapshots(),
                excludingTaskID: snapshot.taskID
            )
        }
    }

    private func applyDownloadBackgroundSnapshot(_ snapshot: IMTransferSnapshot) async {
        switch snapshot.state {
        case .running, .waitingForConnectivity:
            if downloadTask != nil || downloadOperation != nil {
                return
            }
            trackedBackgroundDownload = snapshot
            isDownloading = true
            downloadProgress = snapshot.imBackgroundProgress
            downloadStatus = transferProjectionState.backgroundStatusMessage(
                for: snapshot,
                verb: "下载"
            )
        case .completed:
            if let trackedBackgroundDownload,
               trackedBackgroundDownload.taskID != snapshot.taskID {
                return
            }
            trackedBackgroundDownload = nil
            isDownloading = false
            downloadProgress = nil
            downloadedFileURL = snapshot.destinationURL
            downloadStatus = "后台下载完成：\(snapshot.destinationURL?.lastPathComponent ?? "文件已保存")"
            delegate?.fileTransferManagerDidSucceed()
            applyRecoveredBackgroundTransfers(
                backgroundTransferMonitor.currentSnapshots(),
                excludingTaskID: snapshot.taskID
            )
        case .cancelled:
            guard trackedBackgroundDownload?.taskID == snapshot.taskID else {
                return
            }
            trackedBackgroundDownload = nil
            isDownloading = false
            downloadProgress = nil
            downloadStatus = "后台下载已取消。"
            applyRecoveredBackgroundTransfers(
                backgroundTransferMonitor.currentSnapshots(),
                excludingTaskID: snapshot.taskID
            )
        case .failed(let message, let shouldPreserveSession, let shouldMarkServerOffline):
            guard trackedBackgroundDownload?.taskID == snapshot.taskID else {
                return
            }
            trackedBackgroundDownload = nil
            isDownloading = false
            downloadProgress = nil
            downloadStatus = message
            await delegate?.fileTransferManagerDidReceiveFailure(
                ProbeFailureContext(
                    message: message,
                    shouldPreserveSession: shouldPreserveSession,
                    shouldMarkServerOffline: shouldMarkServerOffline
                )
            )
            applyRecoveredBackgroundTransfers(
                backgroundTransferMonitor.currentSnapshots(),
                excludingTaskID: snapshot.taskID
            )
        }
    }
}

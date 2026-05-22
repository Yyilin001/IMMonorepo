import Foundation
import IMClientKit

@MainActor
final class FileTransferRuntimeController {
    private weak var manager: FileTransferManager?

    private var uploadTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var uploadOperation: FileTransferOperation<UploadTransferEvent<EmptyResponse>>?
    private var downloadOperation: FileTransferOperation<DownloadTransferEvent>?
    private var backgroundTransferUpdatesTask: Task<Void, Never>?
    private var transferStore = TransferStore()
    private var trackedBackgroundUpload: IMTransferSnapshot?
    private var trackedBackgroundDownload: IMTransferSnapshot?

    init(manager: FileTransferManager) {
        self.manager = manager
    }

    func startUpload() {
        guard let manager else {
            return
        }

        guard !manager.isUploading else {
            return
        }

        guard let fileURL = manager.selectedUploadFileURL else {
            manager.uploadStatus = "请先选择要上传的文件。"
            return
        }

        let path = manager.normalizedPath(manager.uploadPath)
        guard !path.isEmpty else {
            manager.uploadStatus = "请填写上传接口路径。"
            return
        }

        cancelUpload(resetStatus: false)
        manager.uploadProgress = nil
        manager.isUploading = true
        manager.uploadStatus = "正在上传 \(fileURL.lastPathComponent)..."

        uploadTask = Task { [weak self, weak manager] in
            guard let self, let manager else {
                return
            }
            let didAccessSecurityScopedResource = fileURL.startAccessingSecurityScopedResource()
            defer {
                if didAccessSecurityScopedResource {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let operation = try await manager.fileAPI.uploadWithProgress(
                    FileUploadRequest<EmptyResponse>(
                        path: path,
                        uploadBody: .file(
                            fileURL,
                            contentType: FileTransferManager.mimeType(for: fileURL)
                        )
                    )
                )
                self.uploadOperation = operation

                for try await event in operation.events {
                    switch event {
                    case .progress(let progress):
                        manager.uploadProgress = progress
                        manager.uploadStatus = FileTransferManager.progressMessage(
                            prefix: "上传中",
                            progress: progress
                        )
                    case .completed:
                        manager.isUploading = false
                        self.uploadOperation = nil
                        self.uploadTask = nil
                        manager.uploadProgress = nil
                        manager.uploadStatus = "上传完成。"
                        manager.delegate?.fileTransferManagerDidSucceed()
                    }
                }
            } catch is CancellationError {
                manager.isUploading = false
                self.uploadOperation = nil
                self.uploadTask = nil
                manager.uploadProgress = nil
                manager.uploadStatus = "已取消上传。"
            } catch {
                manager.isUploading = false
                self.uploadOperation = nil
                self.uploadTask = nil
                manager.uploadProgress = nil
                manager.uploadStatus = error.localizedDescription
                await manager.delegate?.fileTransferManagerDidReceiveFailure(
                    manager.makeFailureContext(from: error)
                )
            }
        }
    }

    func cancelUpload(resetStatus: Bool = true) {
        guard let manager else {
            return
        }

        if uploadOperation == nil,
           uploadTask == nil,
           let snapshot = trackedBackgroundUpload
        {
            if resetStatus {
                manager.uploadStatus = "正在取消后台上传..."
            }
            Task { [backgroundTransferMonitor = manager.backgroundTransferMonitor] in
                await backgroundTransferMonitor.cancelTransfer(
                    sessionIdentifier: snapshot.taskID.sessionIdentifier,
                    taskIdentifier: snapshot.taskID.taskIdentifier
                )
            }
            return
        }

        uploadOperation?.cancel()
        uploadTask?.cancel()
        uploadOperation = nil
        uploadTask = nil
        manager.isUploading = false
        manager.uploadProgress = nil
        if resetStatus {
            manager.uploadStatus = "已取消上传。"
        }
    }

    func startDownload() {
        guard let manager else {
            return
        }

        guard !manager.isDownloading else {
            return
        }

        let path = manager.normalizedPath(manager.downloadPath)
        guard !path.isEmpty else {
            manager.downloadStatus = "请填写下载接口路径。"
            return
        }

        let fileName = manager.downloadFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileName.isEmpty else {
            manager.downloadStatus = "请填写下载后的文件名。"
            return
        }

        cancelDownload(resetStatus: false)
        manager.downloadProgress = nil
        manager.downloadedFileURL = nil
        manager.isDownloading = true
        manager.downloadStatus = "正在下载 \(fileName)..."

        let destinationURL = FileTransferManager.downloadsDirectory().appendingPathComponent(fileName)

        downloadTask = Task { [weak self, weak manager] in
            guard let self, let manager else {
                return
            }

            do {
                let operation = try await manager.fileAPI.downloadWithProgress(
                    FileDownloadRequest(
                        path: path,
                        destinationURL: destinationURL
                    )
                )
                self.downloadOperation = operation

                for try await event in operation.events {
                    switch event {
                    case .progress(let progress):
                        manager.downloadProgress = progress
                        manager.downloadStatus = FileTransferManager.progressMessage(
                            prefix: progress.resumedBytes > 0 ? "继续下载中" : "下载中",
                            progress: progress
                        )
                    case .completed(let fileURL):
                        manager.isDownloading = false
                        self.downloadOperation = nil
                        self.downloadTask = nil
                        manager.downloadProgress = nil
                        manager.downloadedFileURL = fileURL
                        manager.downloadStatus = "下载完成：\(fileURL.lastPathComponent)"
                        manager.delegate?.fileTransferManagerDidSucceed()
                    }
                }
            } catch is CancellationError {
                manager.isDownloading = false
                self.downloadOperation = nil
                self.downloadTask = nil
                manager.downloadProgress = nil
                manager.downloadStatus = "已取消下载。"
            } catch {
                manager.isDownloading = false
                self.downloadOperation = nil
                self.downloadTask = nil
                manager.downloadProgress = nil
                manager.downloadStatus = error.localizedDescription
                await manager.delegate?.fileTransferManagerDidReceiveFailure(
                    manager.makeFailureContext(from: error)
                )
            }
        }
    }

    func cancelDownload(resetStatus: Bool = true) {
        guard let manager else {
            return
        }

        if downloadOperation == nil,
           downloadTask == nil,
           let snapshot = trackedBackgroundDownload
        {
            if resetStatus {
                manager.downloadStatus = "正在取消后台下载..."
            }
            Task { [backgroundTransferMonitor = manager.backgroundTransferMonitor] in
                await backgroundTransferMonitor.cancelTransfer(
                    sessionIdentifier: snapshot.taskID.sessionIdentifier,
                    taskIdentifier: snapshot.taskID.taskIdentifier
                )
            }
            return
        }

        downloadOperation?.cancel()
        downloadTask?.cancel()
        downloadOperation = nil
        downloadTask = nil
        manager.isDownloading = false
        manager.downloadProgress = nil
        if resetStatus {
            manager.downloadStatus = "已取消下载。"
        }
    }

    func observeBackgroundTransfers() {
        guard let manager else {
            return
        }

        let updates = manager.backgroundTransferMonitor.updates()
        applyRecoveredBackgroundTransfers(manager.backgroundTransferMonitor.currentSnapshots())

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
        guard let manager else {
            return
        }

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
                manager.isUploading = true
                manager.uploadProgress = snapshot.imBackgroundProgress
                manager.uploadStatus = manager.transferProjectionState.backgroundStatusMessage(
                    for: snapshot,
                    verb: "上传"
                )
            }
        }

        if downloadTask == nil, downloadOperation == nil {
            trackedBackgroundDownload = transferStore.snapshots(kind: .download).first
            if let snapshot = trackedBackgroundDownload {
                manager.isDownloading = true
                manager.downloadProgress = snapshot.imBackgroundProgress
                manager.downloadStatus = manager.transferProjectionState.backgroundStatusMessage(
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
        guard let manager,
              snapshot.kind == .download,
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
        manager.isDownloading = false
        manager.downloadProgress = nil
        manager.downloadedFileURL = snapshot.destinationURL
        manager.downloadStatus = "后台下载完成：\(snapshot.destinationURL?.lastPathComponent ?? "文件已保存")"
        manager.delegate?.fileTransferManagerDidSucceed()
        return true
    }

    private func applyUploadBackgroundSnapshot(_ snapshot: IMTransferSnapshot) async {
        guard let manager else {
            return
        }

        if uploadTask != nil || uploadOperation != nil {
            return
        }

        switch snapshot.state {
        case .running, .waitingForConnectivity:
            trackedBackgroundUpload = snapshot
            manager.isUploading = true
            manager.uploadProgress = snapshot.imBackgroundProgress
            manager.uploadStatus = manager.transferProjectionState.backgroundStatusMessage(
                for: snapshot,
                verb: "上传"
            )
        case .completed:
            guard trackedBackgroundUpload?.taskID == snapshot.taskID else {
                return
            }
            trackedBackgroundUpload = nil
            manager.isUploading = false
            manager.uploadProgress = nil
            manager.uploadStatus = "后台上传完成。"
            manager.delegate?.fileTransferManagerDidSucceed()
            applyRecoveredBackgroundTransfers(
                manager.backgroundTransferMonitor.currentSnapshots(),
                excludingTaskID: snapshot.taskID
            )
        case .cancelled:
            guard trackedBackgroundUpload?.taskID == snapshot.taskID else {
                return
            }
            trackedBackgroundUpload = nil
            manager.isUploading = false
            manager.uploadProgress = nil
            manager.uploadStatus = "后台上传已取消。"
            applyRecoveredBackgroundTransfers(
                manager.backgroundTransferMonitor.currentSnapshots(),
                excludingTaskID: snapshot.taskID
            )
        case .failed(let message, let shouldPreserveSession, let shouldMarkServerOffline):
            guard trackedBackgroundUpload?.taskID == snapshot.taskID else {
                return
            }
            trackedBackgroundUpload = nil
            manager.isUploading = false
            manager.uploadProgress = nil
            manager.uploadStatus = message
            await manager.delegate?.fileTransferManagerDidReceiveFailure(
                ProbeFailureContext(
                    message: message,
                    shouldPreserveSession: shouldPreserveSession,
                    shouldMarkServerOffline: shouldMarkServerOffline
                )
            )
            applyRecoveredBackgroundTransfers(
                manager.backgroundTransferMonitor.currentSnapshots(),
                excludingTaskID: snapshot.taskID
            )
        }
    }

    private func applyDownloadBackgroundSnapshot(_ snapshot: IMTransferSnapshot) async {
        guard let manager else {
            return
        }

        switch snapshot.state {
        case .running, .waitingForConnectivity:
            if downloadTask != nil || downloadOperation != nil {
                return
            }
            trackedBackgroundDownload = snapshot
            manager.isDownloading = true
            manager.downloadProgress = snapshot.imBackgroundProgress
            manager.downloadStatus = manager.transferProjectionState.backgroundStatusMessage(
                for: snapshot,
                verb: "下载"
            )
        case .completed:
            if let trackedBackgroundDownload,
               trackedBackgroundDownload.taskID != snapshot.taskID {
                return
            }
            trackedBackgroundDownload = nil
            manager.isDownloading = false
            manager.downloadProgress = nil
            manager.downloadedFileURL = snapshot.destinationURL
            manager.downloadStatus = "后台下载完成：\(snapshot.destinationURL?.lastPathComponent ?? "文件已保存")"
            manager.delegate?.fileTransferManagerDidSucceed()
            applyRecoveredBackgroundTransfers(
                manager.backgroundTransferMonitor.currentSnapshots(),
                excludingTaskID: snapshot.taskID
            )
        case .cancelled:
            guard trackedBackgroundDownload?.taskID == snapshot.taskID else {
                return
            }
            trackedBackgroundDownload = nil
            manager.isDownloading = false
            manager.downloadProgress = nil
            manager.downloadStatus = "后台下载已取消。"
            applyRecoveredBackgroundTransfers(
                manager.backgroundTransferMonitor.currentSnapshots(),
                excludingTaskID: snapshot.taskID
            )
        case .failed(let message, let shouldPreserveSession, let shouldMarkServerOffline):
            guard trackedBackgroundDownload?.taskID == snapshot.taskID else {
                return
            }
            trackedBackgroundDownload = nil
            manager.isDownloading = false
            manager.downloadProgress = nil
            manager.downloadStatus = message
            await manager.delegate?.fileTransferManagerDidReceiveFailure(
                ProbeFailureContext(
                    message: message,
                    shouldPreserveSession: shouldPreserveSession,
                    shouldMarkServerOffline: shouldMarkServerOffline
                )
            )
            applyRecoveredBackgroundTransfers(
                manager.backgroundTransferMonitor.currentSnapshots(),
                excludingTaskID: snapshot.taskID
            )
        }
    }
}

import Foundation
import IMClientKit

@MainActor
extension FileTransferManager {
    func startDownload() {
        guard !isDownloading else {
            return
        }

        let path = normalizedPath(downloadPath)
        guard !path.isEmpty else {
            downloadStatus = "请填写下载接口路径。"
            return
        }

        let fileName = downloadFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileName.isEmpty else {
            downloadStatus = "请填写下载后的文件名。"
            return
        }

        cancelDownload(resetStatus: false)
        downloadProgress = nil
        downloadedFileURL = nil
        isDownloading = true
        downloadStatus = "正在下载 \(fileName)..."

        let destinationURL = Self.downloadsDirectory().appendingPathComponent(fileName)

        downloadTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let operation = try await self.fileAPI.downloadWithProgress(
                    FileDownloadRequest(
                        path: path,
                        destinationURL: destinationURL
                    )
                )
                self.downloadOperation = operation

                for try await event in operation.events {
                    switch event {
                    case .progress(let progress):
                        self.downloadProgress = progress
                        self.downloadStatus = Self.progressMessage(
                            prefix: progress.resumedBytes > 0 ? "继续下载中" : "下载中",
                            progress: progress
                        )
                    case .completed(let fileURL):
                        self.isDownloading = false
                        self.downloadOperation = nil
                        self.downloadTask = nil
                        self.downloadProgress = nil
                        self.downloadedFileURL = fileURL
                        self.downloadStatus = "下载完成：\(fileURL.lastPathComponent)"
                        self.delegate?.fileTransferManagerDidSucceed()
                    }
                }
            } catch is CancellationError {
                self.isDownloading = false
                self.downloadOperation = nil
                self.downloadTask = nil
                self.downloadProgress = nil
                self.downloadStatus = "已取消下载。"
            } catch {
                self.isDownloading = false
                self.downloadOperation = nil
                self.downloadTask = nil
                self.downloadProgress = nil
                self.downloadStatus = error.localizedDescription
                await self.delegate?.fileTransferManagerDidReceiveFailure(
                    self.makeFailureContext(from: error)
                )
            }
        }
    }

    func cancelDownload(resetStatus: Bool = true) {
        if downloadOperation == nil,
           downloadTask == nil,
           let snapshot = trackedBackgroundDownload
        {
            if resetStatus {
                downloadStatus = "正在取消后台下载..."
            }
            Task { [backgroundTransferMonitor] in
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
        isDownloading = false
        downloadProgress = nil
        if resetStatus {
            downloadStatus = "已取消下载。"
        }
    }
}

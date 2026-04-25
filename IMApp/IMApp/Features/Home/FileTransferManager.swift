import Combine
import Foundation
import IMClientKit
import UniformTypeIdentifiers

@MainActor
protocol FileTransferManagerDelegate: AnyObject {
    func fileTransferManagerDidSucceed()
    func fileTransferManagerDidReceiveFailure(_ failure: ProbeFailureContext) async
}

@MainActor
final class FileTransferManager: ObservableObject {
    @Published var uploadPath = "api/files/upload"
    @Published var downloadPath = "api/files/download"
    @Published var downloadFileName = "downloaded-demo.bin"

    @Published private(set) var selectedUploadFileURL: URL?
    @Published private(set) var selectedUploadFileName = "未选择文件"

    @Published private(set) var uploadStatus = "未开始"
    @Published private(set) var uploadProgress: FileTransferProgress?
    @Published private(set) var isUploading = false

    @Published private(set) var downloadStatus = "未开始"
    @Published private(set) var downloadProgress: FileTransferProgress?
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadedFileURL: URL?

    weak var delegate: (any FileTransferManagerDelegate)?

    private let fileAPI: FileAPI
    private let sessionClient: SessionClient
    private let backgroundTransferMonitor: any BackgroundTransferMonitoring
    private let transferProjectionState = TransferProjectionState()

    private var uploadTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var uploadOperation: FileTransferOperation<UploadTransferEvent<EmptyResponse>>?
    private var downloadOperation: FileTransferOperation<DownloadTransferEvent>?
    private var backgroundTransferUpdatesTask: Task<Void, Never>?
    private var transferStore = IMTransferStore()
    private var trackedBackgroundUpload: IMTransferSnapshot?
    private var trackedBackgroundDownload: IMTransferSnapshot?

    init(
        fileAPI: FileAPI,
        sessionClient: SessionClient,
        backgroundTransferMonitor: any BackgroundTransferMonitoring = BackgroundTransferCoordinator.shared
    ) {
        self.fileAPI = fileAPI
        self.sessionClient = sessionClient
        self.backgroundTransferMonitor = backgroundTransferMonitor
        observeBackgroundTransfers()
    }

    func selectUploadFile(_ url: URL) {
        selectedUploadFileURL = url
        selectedUploadFileName = url.lastPathComponent
        uploadStatus = "已选择文件：\(url.lastPathComponent)"
    }

    func clearSelectedUploadFile() {
        selectedUploadFileURL = nil
        selectedUploadFileName = "未选择文件"
        uploadStatus = "未开始"
        uploadProgress = nil
    }

    func setUploadStatus(_ message: String) {
        uploadStatus = message
    }

    func startUpload() {
        guard !isUploading else {
            return
        }

        guard let fileURL = selectedUploadFileURL else {
            uploadStatus = "请先选择要上传的文件。"
            return
        }

        let path = normalizedPath(uploadPath)
        guard !path.isEmpty else {
            uploadStatus = "请填写上传接口路径。"
            return
        }

        cancelUpload(resetStatus: false)
        uploadProgress = nil
        isUploading = true
        uploadStatus = "正在上传 \(fileURL.lastPathComponent)..."

        uploadTask = Task { [weak self] in
            guard let self else {
                return
            }
            let didAccessSecurityScopedResource = fileURL.startAccessingSecurityScopedResource()
            defer {
                if didAccessSecurityScopedResource {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let operation = try await self.fileAPI.uploadWithProgress(
                    FileUploadRequest<EmptyResponse>(
                        path: path,
                        uploadBody: .file(
                            fileURL,
                            contentType: Self.mimeType(for: fileURL)
                        )
                    )
                )
                self.uploadOperation = operation

                for try await event in operation.events {
                    switch event {
                    case .progress(let progress):
                        self.uploadProgress = progress
                        self.uploadStatus = Self.progressMessage(
                            prefix: "上传中",
                            progress: progress
                        )
                    case .completed:
                        self.isUploading = false
                        self.uploadOperation = nil
                        self.uploadTask = nil
                        self.uploadProgress = nil
                        self.uploadStatus = "上传完成。"
                        self.delegate?.fileTransferManagerDidSucceed()
                    }
                }
            } catch is CancellationError {
                self.isUploading = false
                self.uploadOperation = nil
                self.uploadTask = nil
                self.uploadProgress = nil
                self.uploadStatus = "已取消上传。"
            } catch {
                self.isUploading = false
                self.uploadOperation = nil
                self.uploadTask = nil
                self.uploadProgress = nil
                self.uploadStatus = error.localizedDescription
                await self.delegate?.fileTransferManagerDidReceiveFailure(
                    self.makeFailureContext(from: error)
                )
            }
        }
    }

    func cancelUpload(resetStatus: Bool = true) {
        if uploadOperation == nil,
           uploadTask == nil,
           let snapshot = trackedBackgroundUpload
        {
            if resetStatus {
                uploadStatus = "正在取消后台上传..."
            }
           Task { [backgroundTransferMonitor] in
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
        isUploading = false
        uploadProgress = nil
        if resetStatus {
            uploadStatus = "已取消上传。"
        }
    }

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

    func stopAllForSignedOut() {
        cancelUpload(resetStatus: false)
        cancelDownload(resetStatus: false)
        uploadStatus = "登录状态已失效，已停止上传。"
        downloadStatus = "登录状态已失效，已停止下载。"
    }

    private func makeFailureContext(from error: Error) async -> ProbeFailureContext {
        let shouldPreserveSession = await sessionClient.shouldPreserveSession(for: error)
        let shouldMarkServerOffline = await sessionClient.shouldMarkServerOffline(for: error)
        return ProbeFailureContext(
            message: error.localizedDescription,
            shouldPreserveSession: shouldPreserveSession,
            shouldMarkServerOffline: shouldMarkServerOffline
        )
    }

    private func normalizedPath(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func progressMessage(prefix: String, progress: FileTransferProgress) -> String {
        if let total = progress.totalBytes, total > 0 {
            let percentage = Int((Double(progress.transferredBytes) / Double(total)) * 100)
            return "\(prefix)：\(percentage)% (\(progress.transferredBytes)/\(total) 字节)"
        }
        return "\(prefix)：已传输 \(progress.transferredBytes) 字节"
    }

    private static func downloadsDirectory() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    private static func mimeType(for fileURL: URL) -> String {
        guard let type = UTType(filenameExtension: fileURL.pathExtension),
              let mimeType = type.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mimeType
    }

    private func observeBackgroundTransfers() {
        applyRecoveredBackgroundTransfers(backgroundTransferMonitor.currentSnapshots())

        let updates = backgroundTransferMonitor.updates()
        backgroundTransferUpdatesTask = Task { [weak self] in
            guard let self else {
                return
            }

            for await snapshot in updates {
                await self.applyBackgroundTransferUpdate(snapshot)
            }
        }
    }

    private func applyRecoveredBackgroundTransfers(_ snapshots: [BackgroundTransferSnapshot]) {
        transferStore.replace(with: snapshots)

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

    private func applyBackgroundTransferUpdate(_ snapshot: BackgroundTransferSnapshot) async {
        let transferSnapshot = transferStore.apply(snapshot)
        switch transferSnapshot.kind {
        case .upload:
            await applyUploadBackgroundSnapshot(transferSnapshot)
        case .download:
            await applyDownloadBackgroundSnapshot(transferSnapshot)
        }
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
            applyRecoveredBackgroundTransfers(backgroundTransferMonitor.currentSnapshots())
        case .cancelled:
            guard trackedBackgroundUpload?.taskID == snapshot.taskID else {
                return
            }
            trackedBackgroundUpload = nil
            isUploading = false
            uploadProgress = nil
            uploadStatus = "后台上传已取消。"
            applyRecoveredBackgroundTransfers(backgroundTransferMonitor.currentSnapshots())
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
            applyRecoveredBackgroundTransfers(backgroundTransferMonitor.currentSnapshots())
        }
    }

    private func applyDownloadBackgroundSnapshot(_ snapshot: IMTransferSnapshot) async {
        if downloadTask != nil || downloadOperation != nil {
            return
        }

        switch snapshot.state {
        case .running, .waitingForConnectivity:
            trackedBackgroundDownload = snapshot
            isDownloading = true
            downloadProgress = snapshot.imBackgroundProgress
            downloadStatus = transferProjectionState.backgroundStatusMessage(
                for: snapshot,
                verb: "下载"
            )
        case .completed:
            guard trackedBackgroundDownload?.taskID == snapshot.taskID else {
                return
            }
            trackedBackgroundDownload = nil
            isDownloading = false
            downloadProgress = nil
            downloadedFileURL = snapshot.destinationURL
            downloadStatus = "后台下载完成：\(snapshot.destinationURL?.lastPathComponent ?? "文件已保存")"
            delegate?.fileTransferManagerDidSucceed()
            applyRecoveredBackgroundTransfers(backgroundTransferMonitor.currentSnapshots())
        case .cancelled:
            guard trackedBackgroundDownload?.taskID == snapshot.taskID else {
                return
            }
            trackedBackgroundDownload = nil
            isDownloading = false
            downloadProgress = nil
            downloadStatus = "后台下载已取消。"
            applyRecoveredBackgroundTransfers(backgroundTransferMonitor.currentSnapshots())
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
            applyRecoveredBackgroundTransfers(backgroundTransferMonitor.currentSnapshots())
        }
    }
}

private extension IMTransferSnapshot {
    var imBackgroundProgress: FileTransferProgress? {
        switch state {
        case .running(let progress), .waitingForConnectivity(let progress), .cancelled(let progress):
            return progress?.progress
        case .completed, .failed:
            return nil
        }
    }
}

import Combine
import Foundation
import IMClientKit

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

    @Published var selectedUploadFileURL: URL?
    @Published var selectedUploadFileName = "未选择文件"

    @Published var uploadStatus = "未开始"
    @Published var uploadProgress: FileTransferProgress?
    @Published var isUploading = false

    @Published var downloadStatus = "未开始"
    @Published var downloadProgress: FileTransferProgress?
    @Published var isDownloading = false
    @Published var downloadedFileURL: URL?

    weak var delegate: (any FileTransferManagerDelegate)?

    let fileAPI: FileAPI
    let sessionClient: SessionClient
    let backgroundTransferMonitor: any BackgroundTransferMonitoring
    let transferProjectionState = TransferProjectionState()

    var uploadTask: Task<Void, Never>?
    var downloadTask: Task<Void, Never>?
    var uploadOperation: FileTransferOperation<UploadTransferEvent<EmptyResponse>>?
    var downloadOperation: FileTransferOperation<DownloadTransferEvent>?
    var backgroundTransferUpdatesTask: Task<Void, Never>?
    var transferStore = TransferStore()
    var trackedBackgroundUpload: IMTransferSnapshot?
    var trackedBackgroundDownload: IMTransferSnapshot?

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

    func stopAllForSignedOut() {
        cancelUpload(resetStatus: false)
        cancelDownload(resetStatus: false)
        uploadStatus = "登录状态已失效，已停止上传。"
        downloadStatus = "登录状态已失效，已停止下载。"
    }

    func makeFailureContext(from error: Error) async -> ProbeFailureContext {
        let shouldPreserveSession = await sessionClient.shouldPreserveSession(for: error)
        let shouldMarkServerOffline = await sessionClient.shouldMarkServerOffline(for: error)
        return ProbeFailureContext(
            message: error.localizedDescription,
            shouldPreserveSession: shouldPreserveSession,
            shouldMarkServerOffline: shouldMarkServerOffline
        )
    }
}

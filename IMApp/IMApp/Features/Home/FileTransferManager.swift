import Foundation
import IMClientKit
import Observation

@MainActor
protocol FileTransferManagerDelegate: AnyObject {
    func fileTransferManagerDidSucceed()
    func fileTransferManagerDidReceiveFailure(_ failure: ProbeFailureContext) async
}

@MainActor
@Observable
final class FileTransferManager {
    var uploadPath = "api/files/upload"
    var downloadPath = "api/files/download"
    var downloadFileName = "downloaded-demo.bin"

    var selectedUploadFileURL: URL?
    var selectedUploadFileName = "未选择文件"

    var uploadStatus = "未开始"
    var uploadProgress: FileTransferProgress?
    var isUploading = false

    var downloadStatus = "未开始"
    var downloadProgress: FileTransferProgress?
    var isDownloading = false
    var downloadedFileURL: URL?

    @ObservationIgnored
    weak var delegate: (any FileTransferManagerDelegate)?

    @ObservationIgnored
    let fileAPI: FileAPI
    @ObservationIgnored
    let sessionClient: SessionClient
    @ObservationIgnored
    let backgroundTransferMonitor: any BackgroundTransferMonitoring
    @ObservationIgnored
    let transferProjectionState = TransferProjectionState()

    @ObservationIgnored
    lazy var runtimeController = FileTransferRuntimeController(manager: self)

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

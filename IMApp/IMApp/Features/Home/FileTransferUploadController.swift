import Foundation
import IMClientKit

@MainActor
extension FileTransferManager {
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
}

import SwiftUI
import IMClientKit
import UniformTypeIdentifiers

struct FileTransferView: View {
    @ObservedObject var fileTransferManager: FileTransferManager

    @State private var isPickingUploadFile = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                uploadSection
                downloadSection
            }
            .padding(24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("文件传输")
        .fileImporter(
            isPresented: $isPickingUploadFile,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else {
                    return
                }
                fileTransferManager.selectUploadFile(url)
            case .failure(let error):
                fileTransferManager.setUploadStatus("选择文件失败：\(error.localizedDescription)")
            }
        }
    }

    private var uploadSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("上传文件", systemImage: "square.and.arrow.up")
                .font(.headline)

            TextField("上传接口路径", text: $fileTransferManager.uploadPath)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            statusRow(title: "已选文件", value: fileTransferManager.selectedUploadFileName)
            statusRow(title: "上传状态", value: fileTransferManager.uploadStatus)

            if let progress = fileTransferManager.uploadProgress {
                progressBlock(title: "上传进度", progress: progress)
            }

            HStack(spacing: 12) {
                Button("选择文件") {
                    isPickingUploadFile = true
                }
                .buttonStyle(.bordered)

                Button("开始上传") {
                    fileTransferManager.startUpload()
                }
                .buttonStyle(.borderedProminent)
                .disabled(fileTransferManager.isUploading)

                Button("取消上传") {
                    fileTransferManager.cancelUpload()
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(!fileTransferManager.isUploading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var downloadSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("下载文件", systemImage: "square.and.arrow.down")
                .font(.headline)

            TextField("下载接口路径", text: $fileTransferManager.downloadPath)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            TextField("保存后的文件名", text: $fileTransferManager.downloadFileName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            statusRow(title: "下载状态", value: fileTransferManager.downloadStatus)

            if let progress = fileTransferManager.downloadProgress {
                progressBlock(title: "下载进度", progress: progress)
            }

            if let fileURL = fileTransferManager.downloadedFileURL {
                statusRow(title: "本地文件", value: fileURL.path)
            }

            HStack(spacing: 12) {
                Button("开始下载") {
                    fileTransferManager.startDownload()
                }
                .buttonStyle(.borderedProminent)
                .disabled(fileTransferManager.isDownloading)

                Button("取消下载") {
                    fileTransferManager.cancelDownload()
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(!fileTransferManager.isDownloading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private func progressBlock(title: String, progress: FileTransferProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ProgressView(value: progressFraction(progress))
                .progressViewStyle(.linear)

            statusRow(title: "已传输", value: "\(progress.transferredBytes) 字节")

            if let total = progress.totalBytes {
                statusRow(title: "总大小", value: "\(total) 字节")
            }

            if progress.resumedBytes > 0 {
                statusRow(title: "续传起点", value: "\(progress.resumedBytes) 字节")
            }
        }
    }

    private func progressFraction(_ progress: FileTransferProgress) -> Double? {
        progress.fractionCompleted
    }

    private func statusRow(title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

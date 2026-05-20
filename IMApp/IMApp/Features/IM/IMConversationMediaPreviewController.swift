import SwiftUI
import IMClientKit
import UniformTypeIdentifiers

extension IMConversationDetailView {
    func handleMediaImport(_ result: Result<[URL], Error>) {
        guard canSendMessages else {
            return
        }

        switch result {
        case .success(let fileURLs):
            guard let fileURL = fileURLs.first else {
                runtimeStore.setStatusMessage("未选择任何附件。")
                return
            }
            Task {
                await sendImportedMedia(from: fileURL)
            }
        case .failure:
            runtimeStore.setStatusMessage("选择附件失败，请重试。")
        }
    }

    func sendImportedMedia(from fileURL: URL) async {
        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        let metadata = inferredMediaMetadata(for: fileURL)
        let didSend = await runtimeStore.sendMedia(
            fileURL: fileURL,
            kind: metadata.kind,
            mimeType: metadata.mimeType,
            filename: metadata.filename,
            byteSize: metadata.byteSize,
            to: conversationID
        )

        if didSend {
            replyTarget = nil
            editingTarget = nil
        }
    }

    func startMediaDownload(_ asset: IMMediaAsset) {
        let assetID = asset.assetID
        let destinationURL: URL

        do {
            destinationURL = try Self.mediaDownloadDestinationURL(for: asset)
        } catch {
            mediaDownloadStates[assetID] = .failed("无法准备下载目录。")
            return
        }

        cancelMediaDownload(for: assetID, nextState: nil)
        if let messageID = messageID(for: assetID) {
            conversationStore.updateLocalDownloadState(
                messageID: messageID,
                state: IMMessageLocalDownloadState(
                    destinationFilePath: destinationURL.path,
                    status: .downloading(
                        progress: nil,
                        backgroundTransfer: nil
                    )
                )
            )
            runtimeStore.persistConversationCacheSoon()
        } else {
            mediaDownloadStates[assetID] = .downloading(progress: nil)
        }

        mediaDownloadTasks[assetID] = Task {
            do {
                try await runtimeStore.startBackgroundMediaDownload(asset, to: destinationURL)
                await MainActor.run {
                    mediaDownloadTasks[assetID] = nil
                    mediaDownloadStates.removeValue(forKey: assetID)
                }
            } catch is CancellationError {
                await MainActor.run {
                    mediaDownloadTasks[assetID] = nil
                }
            } catch {
                await MainActor.run {
                    mediaDownloadTasks[assetID] = nil
                    let failureMessage = mediaDownloadFailureMessage(for: asset, error: error)
                    if let messageID = messageID(for: assetID) {
                        conversationStore.updateLocalDownloadState(
                            messageID: messageID,
                            state: IMMessageLocalDownloadState(
                                destinationFilePath: destinationURL.path,
                                status: .failed(message: failureMessage)
                            )
                        )
                        runtimeStore.persistConversationCacheSoon()
                    } else {
                        mediaDownloadStates[assetID] = .failed(failureMessage)
                    }
                }
            }
        }
    }

    func pauseMediaDownload(for assetID: String) {
        let message = messages.first { $0.mediaAsset?.assetID == assetID }
        let progress: FileTransferProgress?
        let backgroundTransfer: IMMessageBackgroundTransferReference?

        if let localDownloadState = message?.localDownloadState {
            switch localDownloadState.status {
            case .downloading(let snapshot, let reference),
                 .waitingForConnectivity(let snapshot, let reference):
                progress = snapshot?.progress
                backgroundTransfer = reference
            case .paused(let snapshot):
                progress = snapshot?.progress
                backgroundTransfer = nil
            case .downloaded, .failed:
                progress = nil
                backgroundTransfer = nil
            }
        } else if case .downloading(let currentProgress) = mediaDownloadStates[assetID] {
            progress = currentProgress
            backgroundTransfer = nil
        } else {
            progress = nil
            backgroundTransfer = nil
        }

        if let messageID = messageID(for: assetID),
           let asset = mediaAsset(for: assetID),
           let destinationURL = try? Self.mediaDownloadDestinationURL(for: asset) {
            conversationStore.updateLocalDownloadState(
                messageID: messageID,
                state: IMMessageLocalDownloadState(
                    destinationFilePath: destinationURL.path,
                    status: .paused(progress: progress.map(IMMessageLocalDownloadProgressSnapshot.init))
                )
            )
            runtimeStore.persistConversationCacheSoon()
        }

        cancelMediaDownload(for: assetID, nextState: .paused(progress: progress))
        if let backgroundTransfer {
            Task {
                await runtimeStore.cancelBackgroundMediaDownload(backgroundTransfer)
            }
        }
    }

    func deleteDownloadedMedia(_ asset: IMMediaAsset) {
        let assetID = asset.assetID
        cancelMediaDownload(for: assetID, nextState: nil)

        do {
            let destinationURL = try Self.mediaDownloadDestinationURL(for: asset)
            let metadataURL = Self.downloadMetadataURL(for: destinationURL)
            try? FileManager.default.removeItem(at: destinationURL)
            try? FileManager.default.removeItem(at: metadataURL)
            if let messageID = messageID(for: assetID) {
                conversationStore.updateLocalDownloadState(messageID: messageID, state: nil)
                runtimeStore.persistConversationCacheSoon()
            }
            mediaDownloadStates[assetID] = .idle
        } catch {
            mediaDownloadStates[assetID] = .failed("无法删除已下载文件。")
        }
    }

    func cancelMediaDownload(for assetID: String, nextState: IMMediaDownloadState?) {
        mediaDownloadTasks[assetID]?.cancel()
        mediaDownloadTasks[assetID] = nil
        if let nextState {
            mediaDownloadStates[assetID] = nextState
        }
    }

    func pauseAllMediaDownloads() {
        for assetID in Set(mediaDownloadTasks.keys).union(
            messages.compactMap { message in
                switch message.localDownloadState?.status {
                case .downloading, .waitingForConnectivity:
                    return message.mediaAsset?.assetID
                case .paused, .downloaded, .failed, .none:
                    return nil
                }
            }
        ) {
            pauseMediaDownload(for: assetID)
        }
    }

    static func mediaDownloadDestinationURL(for asset: IMMediaAsset) throws -> URL {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let downloadsDirectory = baseDirectory
            .appending(path: "IMMediaDownloads", directoryHint: .isDirectory)
        try fileManager.createDirectory(
            at: downloadsDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let preferredFilename = sanitizedDownloadFilename(
            asset.filename.trimmingCharacters(in: .whitespacesAndNewlines),
            fallbackAssetID: asset.assetID
        )
        return downloadsDirectory.appending(path: preferredFilename)
    }

    static func downloadMetadataURL(for destinationURL: URL) -> URL {
        destinationURL.appendingPathExtension("resume.json")
    }

    static func sanitizedDownloadFilename(_ filename: String?, fallbackAssetID: String) -> String {
        let rawFilename = filename?.isEmpty == false ? filename! : fallbackAssetID
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let components = rawFilename.components(separatedBy: invalidCharacters)
        let sanitized = components.joined(separator: "-")
        return sanitized.isEmpty ? fallbackAssetID : sanitized
    }

    func resolvedMediaDownloadState(for message: IMConversationMessage) -> IMMediaDownloadState? {
        guard let asset = message.mediaAsset else {
            return nil
        }

        if let localDownloadState = message.localDownloadState {
            switch localDownloadState.status {
            case .downloading(let progress, _), .waitingForConnectivity(let progress, _):
                return .downloading(progress: progress?.progress)
            case .paused(let progress):
                return .paused(progress: progress?.progress)
            case .downloaded:
                if FileManager.default.fileExists(atPath: localDownloadState.destinationFilePath) {
                    return .downloaded(localDownloadState.destinationFileURL)
                }
            case .failed(let message):
                return .failed(message)
            }
        }

        if let state = mediaDownloadStates[asset.assetID] {
            return state
        }

        guard let destinationURL = try? Self.mediaDownloadDestinationURL(for: asset),
              FileManager.default.fileExists(atPath: destinationURL.path)
        else {
            return .idle
        }

        return .downloaded(destinationURL)
    }

    func messageID(for assetID: String) -> String? {
        messages.first { $0.mediaAsset?.assetID == assetID }?.id
    }

    func mediaAsset(for assetID: String) -> IMMediaAsset? {
        messages.first { $0.mediaAsset?.assetID == assetID }?.mediaAsset
    }

    func mediaDownloadFailureMessage(for asset: IMMediaAsset, error: Error) -> String {
        let prefix = "\(asset.kind.displayName)下载失败"

        if let apiError = error as? APIError {
            switch apiError {
            case .forbidden, .unauthorized:
                return "\(prefix)：你当前无权访问这个附件。"
            case .connectivity:
                return "\(prefix)：当前无法连接服务器。"
            case .timeout:
                return "\(prefix)：请求超时，请重试。"
            case .server(let statusCode, _):
                if statusCode == 404 {
                    return "\(prefix)：附件已不可用。"
                }
                return "\(prefix)：\(apiError.localizedDescription)"
            default:
                return "\(prefix)：\(apiError.localizedDescription)"
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError {
            return "\(prefix)：设备存储空间不足。"
        }

        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "\(prefix)：网络连接已中断。"
            case NSURLErrorTimedOut:
                return "\(prefix)：请求超时，请重试。"
            default:
                break
            }
        }

        return "\(prefix)：\(error.localizedDescription)"
    }

    func inferredMediaMetadata(for fileURL: URL) -> (
        kind: IMMediaAssetKind,
        mimeType: String,
        filename: String,
        byteSize: Int64?
    ) {
        let filename = fileURL.lastPathComponent
        let mimeType = preferredMimeType(for: fileURL)
        let kind: IMMediaAssetKind
        if let type = UTType(filenameExtension: fileURL.pathExtension.lowercased()) {
            if type.conforms(to: .image) {
                kind = .image
            } else if type.conforms(to: .audio) {
                kind = .audio
            } else {
                kind = .file
            }
        } else {
            kind = .file
        }

        let byteSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        return (kind, mimeType, filename, byteSize)
    }

    func preferredMimeType(for fileURL: URL) -> String {
        guard let type = UTType(filenameExtension: fileURL.pathExtension.lowercased()),
              let mimeType = type.preferredMIMEType
        else {
            return "application/octet-stream"
        }
        return mimeType
    }
}

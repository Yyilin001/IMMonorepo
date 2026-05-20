import Foundation
import IMClientKit

extension ConversationRuntimeController {
    func sendMedia(
        fileURL: URL,
        kind: IMMediaAssetKind,
        mimeType: String,
        filename: String? = nil,
        byteSize: Int64? = nil,
        width: Int? = nil,
        height: Int? = nil,
        durationMillis: Int? = nil,
        previewAssetID: String? = nil,
        to conversationID: String
    ) async -> Bool {
        guard let user = currentUserProvider() else {
            return false
        }

        let resolvedFilename = resolvedMediaFilename(for: fileURL, filename: filename)
        guard !resolvedFilename.isEmpty else {
            imConversationStore.setStatusMessage("附件文件名不能为空。")
            return false
        }

        let resolvedByteSize: Int64
        do {
            resolvedByteSize = try resolvedMediaByteSize(for: fileURL, byteSize: byteSize)
        } catch {
            imConversationStore.setStatusMessage("无法读取附件大小。")
            return false
        }

        let placeholderAsset = IMMediaAsset(
            assetID: "local-\(UUID().uuidString.lowercased())",
            kind: kind,
            mimeType: mimeType,
            byteSize: resolvedByteSize,
            filename: resolvedFilename,
            width: width,
            height: height,
            durationMillis: durationMillis,
            previewAssetID: previewAssetID
        )

        guard let placeholder = imConversationStore.stageOutgoingMediaUpload(
            asset: placeholderAsset,
            conversationID: conversationID,
            senderUserID: user.id,
            sourceFileURL: fileURL
        ) else {
            return false
        }
        scheduleConversationCachePersist()

        do {
            imConversationStore.markOutgoingPreparing(
                localMessageID: placeholder.localMessageID,
                message: "正在创建上传会话。"
            )
            let session = try await sessionClient.createMediaUploadSession(
                kind: kind,
                mimeType: mimeType,
                byteSize: resolvedByteSize,
                filename: resolvedFilename,
                width: width,
                height: height,
                durationMillis: durationMillis,
                previewAssetID: previewAssetID
            )
            markServerOnline()

            imConversationStore.markOutgoingUploading(
                localMessageID: placeholder.localMessageID,
                message: "正在上传附件。",
                uploadID: session.uploadID
            )
            try await sessionClient.uploadMediaChunk(
                uploadID: session.uploadID,
                uploadBody: .file(fileURL, contentType: mimeType)
            )
            let uploadedAsset = try await sessionClient.completeMediaUpload(uploadID: session.uploadID)
            markServerOnline()

            if let connection = imConnection {
                guard let request = imConversationStore.prepareUploadedOutgoingMedia(
                    asset: uploadedAsset,
                    localMessageID: placeholder.localMessageID,
                    conversationID: conversationID
                ) else {
                    scheduleConversationCachePersist()
                    return false
                }
                scheduleConversationCachePersist()

                let generation = imConnectionGeneration
                do {
                    try await connection.sendMessage(request.payload, requestID: request.requestID)
                    return true
                } catch {
                    await handleIMConnectionFailure(error, generation: generation)
                    return false
                }
            }

            let didQueue = imConversationStore.queueUploadedOutgoingMedia(
                asset: uploadedAsset,
                localMessageID: placeholder.localMessageID,
                conversationID: conversationID
            )
            if didQueue {
                scheduleConversationCachePersist()
                scheduleConnectionIfNeeded()
            }
            return didQueue
        } catch {
            imConversationStore.markOutgoingUploadFailed(
                localMessageID: placeholder.localMessageID,
                message: "附件上传失败，请稍后重试。"
            )
            scheduleConversationCachePersist()
            await handleIMDataRequestError(error)
            return false
        }
    }

    func resumeRecoverableMediaUploadsIfNeeded() {
        guard let currentUserID = currentUserProvider()?.id else {
            return
        }

        for pendingUpload in imConversationStore.recoverableOutgoingMediaUploads() {
            guard mediaUploadRecoveryTasks[pendingUpload.localMessageID] == nil else {
                continue
            }

            mediaUploadRecoveryTasks[pendingUpload.localMessageID] = Task { [weak self] in
                await self?.resumeRecoverableMediaUpload(
                    pendingUpload,
                    expectedUserID: currentUserID
                )
            }
        }
    }

    func downloadMedia(
        _ asset: IMMediaAsset,
        to destinationURL: URL,
        resumeIfPossible: Bool = true
    ) async throws -> FileTransferOperation<DownloadTransferEvent> {
        try await sessionClient.downloadMediaAssetWithProgress(
            assetID: asset.assetID,
            to: destinationURL,
            resumeIfPossible: resumeIfPossible
        )
    }

    func downloadMediaToFile(
        _ asset: IMMediaAsset,
        to destinationURL: URL,
        resumeIfPossible: Bool = true
    ) async throws -> URL {
        let operation = try await downloadMedia(
            asset,
            to: destinationURL,
            resumeIfPossible: resumeIfPossible
        )

        var completedURL: URL?
        for try await event in operation.events {
            if case .completed(let finalURL) = event {
                completedURL = finalURL
            }
        }

        return completedURL ?? destinationURL
    }

    func resumeRecoverableMediaUpload(
        _ pendingUpload: IMRecoverableOutgoingMediaUpload,
        expectedUserID: UUID
    ) async {
        defer {
            mediaUploadRecoveryTasks[pendingUpload.localMessageID] = nil
        }

        guard currentUserProvider()?.id == expectedUserID else {
            return
        }

        guard imConversationStore.containsConversation(id: pendingUpload.conversationID) else {
            return
        }

        let sourceFileURL = pendingUpload.transferState.sourceFileURL
        guard FileManager.default.fileExists(atPath: sourceFileURL.path) else {
            imConversationStore.abandonRecoverableOutgoingMediaUpload(
                localMessageID: pendingUpload.localMessageID,
                message: "附件原文件不存在，无法继续上传。"
            )
            scheduleConversationCachePersist()
            return
        }

        do {
            var uploadID = pendingUpload.transferState.uploadID
            if uploadID == nil {
                imConversationStore.markOutgoingPreparing(
                    localMessageID: pendingUpload.localMessageID,
                    message: "正在恢复附件上传。"
                )
                let session = try await sessionClient.createMediaUploadSession(
                    kind: pendingUpload.asset.kind,
                    mimeType: pendingUpload.asset.mimeType,
                    byteSize: pendingUpload.asset.byteSize,
                    filename: pendingUpload.asset.filename,
                    width: pendingUpload.asset.width,
                    height: pendingUpload.asset.height,
                    durationMillis: pendingUpload.asset.durationMillis,
                    previewAssetID: pendingUpload.asset.previewAssetID
                )
                uploadID = session.uploadID
                markServerOnline()
            }

            guard let uploadID else {
                imConversationStore.abandonRecoverableOutgoingMediaUpload(
                    localMessageID: pendingUpload.localMessageID,
                    message: "附件上传会话无效，无法恢复。"
                )
                scheduleConversationCachePersist()
                return
            }

            imConversationStore.markOutgoingUploading(
                localMessageID: pendingUpload.localMessageID,
                message: "正在恢复上传附件。",
                uploadID: uploadID
            )
            scheduleConversationCachePersist()

            try await sessionClient.uploadMediaChunk(
                uploadID: uploadID,
                uploadBody: .file(sourceFileURL, contentType: pendingUpload.asset.mimeType)
            )
            let uploadedAsset = try await sessionClient.completeMediaUpload(uploadID: uploadID)
            markServerOnline()

            if let connection = imConnection {
                guard let request = imConversationStore.prepareUploadedOutgoingMedia(
                    asset: uploadedAsset,
                    localMessageID: pendingUpload.localMessageID,
                    conversationID: pendingUpload.conversationID
                ) else {
                    scheduleConversationCachePersist()
                    return
                }
                scheduleConversationCachePersist()

                let generation = imConnectionGeneration
                do {
                    try await connection.sendMessage(request.payload, requestID: request.requestID)
                } catch {
                    await handleIMConnectionFailure(error, generation: generation)
                }
                return
            }

            let didQueue = imConversationStore.queueUploadedOutgoingMedia(
                asset: uploadedAsset,
                localMessageID: pendingUpload.localMessageID,
                conversationID: pendingUpload.conversationID
            )
            if didQueue {
                scheduleConversationCachePersist()
                scheduleConnectionIfNeeded()
            }
        } catch {
            imConversationStore.markOutgoingUploadFailed(
                localMessageID: pendingUpload.localMessageID,
                message: "附件上传失败，请稍后重试。"
            )
            scheduleConversationCachePersist()
            await handleIMDataRequestError(error)
        }
    }

    func resolvedMediaFilename(for fileURL: URL, filename: String?) -> String {
        let provided = filename?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !provided.isEmpty {
            return provided
        }
        return fileURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func resolvedMediaByteSize(for fileURL: URL, byteSize: Int64?) throws -> Int64 {
        if let byteSize, byteSize > 0 {
            return byteSize
        }

        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize, fileSize > 0 {
            return Int64(fileSize)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        if let fileSize = attributes[.size] as? NSNumber, fileSize.int64Value > 0 {
            return fileSize.int64Value
        }

        throw CocoaError(.fileReadUnknown)
    }

}

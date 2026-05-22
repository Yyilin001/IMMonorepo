import Foundation
import IMClientKit

@MainActor
extension AuthManager {
    func downloadIMMedia(
        _ asset: IMMediaAsset,
        to destinationURL: URL,
        resumeIfPossible: Bool = true
    ) async throws -> FileTransferOperation<DownloadTransferEvent> {
        try await conversationRuntimeController.downloadMedia(
            asset,
            to: destinationURL,
            resumeIfPossible: resumeIfPossible
        )
    }

    func downloadIMMediaToFile(
        _ asset: IMMediaAsset,
        to destinationURL: URL,
        resumeIfPossible: Bool = true
    ) async throws -> URL {
        try await conversationRuntimeController.downloadMediaToFile(
            asset,
            to: destinationURL,
            resumeIfPossible: resumeIfPossible
        )
    }

    func startBackgroundIMMediaDownload(
        _ asset: IMMediaAsset,
        to destinationURL: URL
    ) async throws {
        try await conversationRuntimeController.startBackgroundMediaDownload(asset, to: destinationURL)
    }

    func cancelBackgroundIMMediaDownload(
        _ reference: IMMessageBackgroundTransferReference
    ) async {
        await conversationRuntimeController.cancelBackgroundMediaDownload(reference)
    }

    func sendIMMedia(
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
        guard currentUser != nil else {
            return false
        }

        return await conversationRuntimeController.sendMedia(
            fileURL: fileURL,
            kind: kind,
            mimeType: mimeType,
            filename: filename,
            byteSize: byteSize,
            width: width,
            height: height,
            durationMillis: durationMillis,
            previewAssetID: previewAssetID,
            to: conversationID
        )
    }
}

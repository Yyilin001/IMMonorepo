import Foundation
import IMClientKit

extension ConversationRuntimeController {
    func startBackgroundMediaDownload(
        _ asset: IMMediaAsset,
        to destinationURL: URL
    ) async throws {
        if let match = localDownloadMessageMatch(for: destinationURL.path) {
            imConversationStore.updateLocalDownloadState(
                messageID: match.messageID,
                state: IMMessageLocalDownloadState(
                    destinationFilePath: destinationURL.path,
                    status: .downloading(
                        progress: match.state?.pausedProgress,
                        backgroundTransfer: nil
                    )
                )
            )
            scheduleConversationCachePersist()
        }

        _ = try await sessionClient.downloadMediaAsset(
            assetID: asset.assetID,
            to: destinationURL,
            backgroundTransfer: BackgroundTransferConfiguration(
                isDiscretionary: false,
                waitsForConnectivity: true
            )
        )
    }

    func cancelBackgroundMediaDownload(
        _ reference: IMMessageBackgroundTransferReference
    ) async {
        await backgroundTransferMonitor.cancelTransfer(
            sessionIdentifier: reference.sessionIdentifier,
            taskIdentifier: reference.taskIdentifier
        )
    }

    func reconcileBackgroundMediaDownloadSnapshots() {
        applyRecoveredBackgroundMediaSnapshots(backgroundTransferMonitor.currentSnapshots())
    }

    func cachedTransferSnapshots() -> [IMTransferSnapshot] {
        mediaTransferStore.snapshots()
    }

    func restoreTransferSnapshots(_ snapshots: [IMTransferSnapshot]) {
        guard !snapshots.isEmpty else {
            return
        }

        mediaTransferStore.replace(with: snapshots)
        replayCachedMediaTransferProjections()
    }

    func startObservingBackgroundMediaDownloads() {
        guard mediaDownloadBackgroundObserveTask == nil else {
            return
        }

        applyRecoveredBackgroundMediaSnapshots(backgroundTransferMonitor.currentSnapshots())
        let updates = backgroundTransferMonitor.updates()
        mediaDownloadBackgroundObserveTask = Task { [weak self] in
            guard let self else {
                return
            }

            for await snapshot in updates {
                await MainActor.run {
                    self.applyBackgroundMediaSnapshot(snapshot)
                }
            }
        }
    }

    private func applyRecoveredBackgroundMediaSnapshots(_ snapshots: [BackgroundTransferSnapshot]) {
        mediaTransferStore.merge(snapshots.filter { $0.kind == .download })
        replayCachedMediaTransferProjections()
    }

    private func applyBackgroundMediaSnapshot(_ snapshot: BackgroundTransferSnapshot) {
        applyBackgroundMediaTransferSnapshot(mediaTransferStore.apply(snapshot))
    }

    private func replayCachedMediaTransferProjections() {
        for snapshot in mediaTransferStore.snapshots(kind: .download) {
            applyBackgroundMediaTransferSnapshot(snapshot)
        }
    }

    private func applyBackgroundMediaTransferSnapshot(_ snapshot: IMTransferSnapshot) {
        guard snapshot.kind == .download,
              let destinationURL = snapshot.destinationURL,
              let match = localDownloadMessageMatch(for: snapshot, destinationPath: destinationURL.path)
        else {
            return
        }

        let nextState = transferProjectionState.localDownloadState(
            from: snapshot,
            destinationFilePath: destinationURL.path,
            existing: match.state
        )

        guard match.state != nextState else {
            return
        }

        imConversationStore.updateLocalDownloadState(
            messageID: match.messageID,
            state: nextState
        )
        scheduleConversationCachePersist()
    }

    private func localDownloadMessageMatch(
        for snapshot: IMTransferSnapshot,
        destinationPath: String
    ) -> (messageID: String, state: IMMessageLocalDownloadState?)? {
        for conversation in imConversationStore.conversations {
            if let message = conversation.messages.first(where: { $0.resolvedTransferTaskID == snapshot.taskID }) {
                return (message.id, message.localDownloadState)
            }
        }

        return localDownloadMessageMatch(for: destinationPath)
    }

    private func localDownloadMessageMatch(for destinationPath: String) -> (messageID: String, state: IMMessageLocalDownloadState?)? {
        let normalizedTargetPath = URL(fileURLWithPath: destinationPath).standardizedFileURL.path

        for conversation in imConversationStore.conversations {
            if let message = conversation.messages.first(where: {
                guard let localDownloadState = $0.localDownloadState else {
                    return false
                }
                return URL(fileURLWithPath: localDownloadState.destinationFilePath)
                    .standardizedFileURL
                    .path == normalizedTargetPath
            }) {
                return (message.id, message.localDownloadState)
            }
        }

        return nil
    }
}

import Foundation
@testable import IMClientKit
import Testing
@testable import IMApp

private final class MockBackgroundTransferMonitor: BackgroundTransferMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [BackgroundTransferSnapshot]
    private var continuations: [UUID: AsyncStream<BackgroundTransferSnapshot>.Continuation] = [:]
    private var cancelledTransfers: [(String, Int)] = []

    init(initialSnapshots: [BackgroundTransferSnapshot] = []) {
        self.snapshots = initialSnapshots
    }

    func currentSnapshots() -> [BackgroundTransferSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return snapshots
    }

    func updates() -> AsyncStream<BackgroundTransferSnapshot> {
        AsyncStream { continuation in
            let identifier = UUID()
            lock.lock()
            continuations[identifier] = continuation
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuations.removeValue(forKey: identifier)
                self?.lock.unlock()
            }
        }
    }

    func cancelTransfer(sessionIdentifier: String, taskIdentifier: Int) async {
        lock.lock()
        cancelledTransfers.append((sessionIdentifier, taskIdentifier))
        lock.unlock()
    }

    func emit(_ snapshot: BackgroundTransferSnapshot) {
        let activeState: Bool
        switch snapshot.state {
        case .running, .waitingForConnectivity:
            activeState = true
        case .completed, .cancelled, .failed:
            activeState = false
        }

        lock.lock()
        if activeState {
            snapshots.removeAll { $0.id == snapshot.id }
            snapshots.append(snapshot)
        } else {
            snapshots.removeAll { $0.id == snapshot.id }
        }
        let currentContinuations = Array(continuations.values)
        lock.unlock()

        currentContinuations.forEach { $0.yield(snapshot) }
    }

    func recordedCancels() -> [(String, Int)] {
        lock.lock()
        defer { lock.unlock() }
        return cancelledTransfers
    }
}

struct FileTransferManagerTests {
    @MainActor
    @Test func restoresRecoveredBackgroundTransfersIntoPublishedState() async throws {
        let uploadSnapshot = BackgroundTransferSnapshot(
            sessionIdentifier: "tests.upload",
            taskIdentifier: 1,
            kind: .upload,
            state: .running,
            progress: FileTransferProgress(
                transferredBytes: 5,
                totalBytes: 10,
                resumedBytes: 0
            ),
            destinationURL: nil
        )
        let downloadURL = FileManager.default.temporaryDirectory.appending(path: "restored-download.bin")
        let downloadSnapshot = BackgroundTransferSnapshot(
            sessionIdentifier: "tests.download",
            taskIdentifier: 2,
            kind: .download,
            state: .waitingForConnectivity,
            progress: nil,
            destinationURL: downloadURL
        )

        let monitor = MockBackgroundTransferMonitor(
            initialSnapshots: [uploadSnapshot, downloadSnapshot]
        )
        let manager = makeManager(backgroundTransferMonitor: monitor)

        #expect(manager.isUploading)
        #expect(manager.uploadProgress == uploadSnapshot.progress)
        #expect(manager.uploadStatus.contains("后台上传中"))

        #expect(manager.isDownloading)
        #expect(manager.downloadProgress == nil)
        #expect(manager.downloadStatus == "后台下载等待网络...")
    }

    @MainActor
    @Test func appliesRecoveredBackgroundCompletionToDownloadState() async throws {
        let destinationURL = FileManager.default.temporaryDirectory.appending(path: "completed-download-\(UUID().uuidString).bin")
        let runningSnapshot = BackgroundTransferSnapshot(
            sessionIdentifier: "tests.download",
            taskIdentifier: 3,
            kind: .download,
            state: .running,
            progress: FileTransferProgress(
                transferredBytes: 4,
                totalBytes: 8,
                resumedBytes: 0
            ),
            destinationURL: destinationURL
        )

        let monitor = MockBackgroundTransferMonitor(initialSnapshots: [runningSnapshot])
        let manager = makeManager(backgroundTransferMonitor: monitor)
        try? await Task.sleep(for: .milliseconds(50))

        monitor.emit(
            BackgroundTransferSnapshot(
                sessionIdentifier: runningSnapshot.sessionIdentifier,
                taskIdentifier: runningSnapshot.taskIdentifier,
                kind: .download,
                state: .completed,
                progress: runningSnapshot.progress,
                destinationURL: destinationURL
            )
        )
        try? await Task.sleep(for: .milliseconds(50))

        #expect(!manager.isDownloading)
        #expect(manager.downloadProgress == nil)
        #expect(manager.downloadedFileURL == destinationURL)
        #expect(manager.downloadStatus.contains("后台下载完成"))
    }

    @MainActor
    @Test func cancelRecoveredBackgroundUploadDelegatesToMonitor() async throws {
        let uploadSnapshot = BackgroundTransferSnapshot(
            sessionIdentifier: "tests.upload.cancel",
            taskIdentifier: 9,
            kind: .upload,
            state: .running,
            progress: nil,
            destinationURL: nil
        )

        let monitor = MockBackgroundTransferMonitor(initialSnapshots: [uploadSnapshot])
        let manager = makeManager(backgroundTransferMonitor: monitor)
        try? await Task.sleep(for: .milliseconds(50))

        manager.cancelUpload()
        try? await Task.sleep(for: .milliseconds(50))

        let cancels = monitor.recordedCancels()
        #expect(cancels.count == 1)
        #expect(cancels.first?.0 == uploadSnapshot.sessionIdentifier)
        #expect(cancels.first?.1 == uploadSnapshot.taskIdentifier)
        #expect(manager.uploadStatus == "正在取消后台上传...")
    }

    @MainActor
    private func makeManager(
        backgroundTransferMonitor: any BackgroundTransferMonitoring
    ) -> FileTransferManager {
        let transport = MockHTTPTransport { _ in
            HTTPFixtures.response(statusCode: 200)
        }
        let sessionClient = SessionClient(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache()
        )
        return FileTransferManager(
            fileAPI: FileAPI(sessionClient: sessionClient),
            sessionClient: sessionClient,
            backgroundTransferMonitor: backgroundTransferMonitor
        )
    }
}

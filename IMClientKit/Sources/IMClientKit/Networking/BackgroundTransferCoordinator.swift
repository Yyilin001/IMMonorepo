import Foundation

public struct BackgroundTransferSnapshot: Identifiable, Sendable, Equatable {
    public struct Failure: Sendable, Equatable {
        public let message: String
        public let shouldPreserveSession: Bool
        public let shouldMarkServerOffline: Bool

        init(error: Error) {
            let apiError = error as? APIError
            self.message = error.localizedDescription
            self.shouldPreserveSession = apiError?.shouldPreserveSession ?? false
            self.shouldMarkServerOffline = apiError?.shouldMarkServerOffline ?? false
        }
    }

    public enum Kind: Sendable, Equatable {
        case upload
        case download
    }

    public enum State: Sendable, Equatable {
        case running
        case waitingForConnectivity
        case completed
        case cancelled
        case failed(Failure)
    }

    public let sessionIdentifier: String
    public let taskIdentifier: Int
    public let kind: Kind
    public let state: State
    public let progress: FileTransferProgress?
    public let destinationURL: URL?

    public init(
        sessionIdentifier: String,
        taskIdentifier: Int,
        kind: Kind,
        state: State,
        progress: FileTransferProgress?,
        destinationURL: URL?
    ) {
        self.sessionIdentifier = sessionIdentifier
        self.taskIdentifier = taskIdentifier
        self.kind = kind
        self.state = state
        self.progress = progress
        self.destinationURL = destinationURL
    }

    public var id: String {
        "\(sessionIdentifier)#\(taskIdentifier)"
    }
}

public protocol BackgroundTransferMonitoring: Sendable {
    func currentSnapshots() -> [BackgroundTransferSnapshot]
    func updates() -> AsyncStream<BackgroundTransferSnapshot>
    func cancelTransfer(sessionIdentifier: String, taskIdentifier: Int) async
}

public final class BackgroundTransferCoordinator: NSObject, @unchecked Sendable, BackgroundTransferMonitoring {
    public static let shared = BackgroundTransferCoordinator()

    private struct TaskKey: Hashable, Sendable {
        let sessionIdentifier: String
        let taskIdentifier: Int
    }

    private struct UploadState {
        let stagedFileURL: URL?
        let ownedStagedFileURL: Bool
        var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        var responseData = Data()
        var response: HTTPURLResponse?
    }

    private struct DownloadState {
        let destinationURL: URL
        var continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>?
        var temporaryFileURL: URL?
        var response: HTTPURLResponse?
    }

    private let lock = NSLock()
    private let recordStore: BackgroundTransferRecordStore
    private let coding: HTTPCodingConfiguration

    private var sessions: [String: URLSession] = [:]
    private var uploadStates: [TaskKey: UploadState] = [:]
    private var downloadStates: [TaskKey: DownloadState] = [:]
    private var activeSnapshots: [TaskKey: BackgroundTransferSnapshot] = [:]
    private var sessionCompletionHandlers: [String: [() -> Void]] = [:]
    private var snapshotContinuations: [UUID: AsyncStream<BackgroundTransferSnapshot>.Continuation] = [:]

    private override init() {
        self.recordStore = .shared
        self.coding = .default
    }

    public func upload(
        request: URLRequest,
        uploadBody: UploadBody,
        configuration: BackgroundTransferConfiguration
    ) async throws -> (Data, HTTPURLResponse) {
        let sessionIdentifier = configuration.sessionIdentifier(suffix: "upload")
        let stagedUpload = try stageUploadBody(uploadBody)
        let session = session(for: sessionIdentifier, configuration: configuration)
        let task = session.uploadTask(with: request, fromFile: stagedUpload.fileURL)

        let taskKey = TaskKey(
            sessionIdentifier: sessionIdentifier,
            taskIdentifier: task.taskIdentifier
        )
        withLock {
            uploadStates[taskKey] = UploadState(
                stagedFileURL: stagedUpload.fileURL,
                ownedStagedFileURL: stagedUpload.ownedByCoordinator,
                continuation: nil
            )
        }
        storeSnapshot(
            for: taskKey,
            kind: .upload,
            state: .running,
            progress: nil,
            destinationURL: nil
        )
        await recordStore.save(
            BackgroundTransferRecord(
                sessionIdentifier: sessionIdentifier,
                taskIdentifier: task.taskIdentifier,
                kind: .upload,
                destinationPath: nil,
                stagedFilePath: stagedUpload.ownedByCoordinator ? stagedUpload.fileURL.path : nil
            )
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
        withLock {
            if var state = uploadStates[taskKey] {
                state.continuation = continuation
                uploadStates[taskKey] = state
            }
        }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    public func download(
        request: URLRequest,
        destinationURL: URL,
        configuration: BackgroundTransferConfiguration
    ) async throws -> (URL, HTTPURLResponse) {
        let sessionIdentifier = configuration.sessionIdentifier(suffix: "download")
        let session = session(for: sessionIdentifier, configuration: configuration)
        let task = session.downloadTask(with: request)

        let taskKey = TaskKey(
            sessionIdentifier: sessionIdentifier,
            taskIdentifier: task.taskIdentifier
        )
        withLock {
            downloadStates[taskKey] = DownloadState(
                destinationURL: destinationURL,
                continuation: nil
            )
        }
        storeSnapshot(
            for: taskKey,
            kind: .download,
            state: .running,
            progress: nil,
            destinationURL: destinationURL
        )
        await recordStore.save(
            BackgroundTransferRecord(
                sessionIdentifier: sessionIdentifier,
                taskIdentifier: task.taskIdentifier,
                kind: .download,
                destinationPath: destinationURL.path,
                stagedFilePath: nil
            )
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
        withLock {
            if var state = downloadStates[taskKey] {
                state.continuation = continuation
                downloadStates[taskKey] = state
            }
        }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    public func resumePendingSessions() {
        Task {
            let records = await recordStore.records()

            for record in records {
                let taskKey = TaskKey(
                    sessionIdentifier: record.sessionIdentifier,
                    taskIdentifier: record.taskIdentifier
                )

                withLock {
                    switch record.kind {
                    case .upload:
                        if uploadStates[taskKey] == nil {
                            uploadStates[taskKey] = UploadState(
                                stagedFileURL: record.stagedFileURL,
                                ownedStagedFileURL: record.stagedFileURL != nil,
                                continuation: nil
                            )
                        }
                        if activeSnapshots[taskKey] == nil {
                            activeSnapshots[taskKey] = BackgroundTransferSnapshot(
                                sessionIdentifier: record.sessionIdentifier,
                                taskIdentifier: record.taskIdentifier,
                                kind: .upload,
                                state: .running,
                                progress: nil,
                                destinationURL: nil
                            )
                        }
                    case .download:
                        guard let destinationURL = record.destinationURL else {
                            break
                        }
                        if downloadStates[taskKey] == nil {
                            downloadStates[taskKey] = DownloadState(
                                destinationURL: destinationURL,
                                continuation: nil
                            )
                        }
                        if activeSnapshots[taskKey] == nil {
                            activeSnapshots[taskKey] = BackgroundTransferSnapshot(
                                sessionIdentifier: record.sessionIdentifier,
                                taskIdentifier: record.taskIdentifier,
                                kind: .download,
                                state: .running,
                                progress: nil,
                                destinationURL: destinationURL
                            )
                        }
                    }
                }

                if let snapshot = withLock({ activeSnapshots[taskKey] }) {
                    publishActiveSnapshot(snapshot, for: taskKey)
                }

                _ = session(for: record.sessionIdentifier)
            }
        }
    }

    public func handleEvents(
        forSessionIdentifier identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        withLock {
            sessionCompletionHandlers[identifier, default: []].append(completionHandler)
        }
        _ = session(for: identifier)
    }

    public func currentSnapshots() -> [BackgroundTransferSnapshot] {
        withLock {
            activeSnapshots.values.sorted {
                ($0.kindSortOrder, $0.taskIdentifier) < ($1.kindSortOrder, $1.taskIdentifier)
            }
        }
    }

    public func updates() -> AsyncStream<BackgroundTransferSnapshot> {
        AsyncStream { continuation in
            let identifier = UUID()
            withLock {
                snapshotContinuations[identifier] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else {
                    return
                }
                _ = self.withLock {
                    self.snapshotContinuations.removeValue(forKey: identifier)
                }
            }
        }
    }

    public func cancelTransfer(sessionIdentifier: String, taskIdentifier: Int) async {
        let taskKey = TaskKey(
            sessionIdentifier: sessionIdentifier,
            taskIdentifier: taskIdentifier
        )
        let session = session(for: sessionIdentifier)
        let tasks = await tasks(for: session)
        if let task = tasks.first(where: { $0.taskIdentifier == taskIdentifier }) {
            task.cancel()
            return
        }

        if let snapshot = withLock({ activeSnapshots[taskKey] }) {
            publishTerminalSnapshot(
                BackgroundTransferSnapshot(
                    sessionIdentifier: snapshot.sessionIdentifier,
                    taskIdentifier: snapshot.taskIdentifier,
                    kind: snapshot.kind,
                    state: .cancelled,
                    progress: snapshot.progress,
                    destinationURL: snapshot.destinationURL
                ),
                for: taskKey
            )
        }
        await recordStore.remove(sessionIdentifier: sessionIdentifier, taskIdentifier: taskIdentifier)
    }

    private func tasks(for session: URLSession) async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks)
            }
        }
    }

    private func stageUploadBody(_ uploadBody: UploadBody) throws -> (fileURL: URL, ownedByCoordinator: Bool) {
        switch uploadBody {
        case .file(let fileURL, _):
            return (fileURL, false)
        case .data(let data, _):
            return (try writeStagedFile(data), true)
        case .multipart(let formData):
            return (try writeStagedFile(formData.encoded()), true)
        }
    }

    private func writeStagedFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "background-upload-\(UUID().uuidString)")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func session(
        for identifier: String,
        configuration: BackgroundTransferConfiguration? = nil
    ) -> URLSession {
        withLock {
            if let session = sessions[identifier] {
                return session
            }

            let sessionConfiguration: URLSessionConfiguration
            if let configuration {
                sessionConfiguration = configuration.sessionConfiguration(identifier: identifier)
            } else {
                sessionConfiguration = BackgroundTransferConfiguration().sessionConfiguration(identifier: identifier)
            }

            let session = URLSession(
                configuration: sessionConfiguration,
                delegate: self,
                delegateQueue: nil
            )
            sessions[identifier] = session
            return session
        }
    }

    private func moveDownloadedFile(from temporaryURL: URL, to destinationURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let directoryURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }

    private func finishUploadTask(
        key: TaskKey,
        result: Result<(Data, HTTPURLResponse), Error>
    ) {
        let state = withLock {
            uploadStates.removeValue(forKey: key)
        }

        guard let state else {
            return
        }

        if state.ownedStagedFileURL, let stagedFileURL = state.stagedFileURL {
            try? FileManager.default.removeItem(at: stagedFileURL)
        }

        Task {
            await recordStore.remove(
                sessionIdentifier: key.sessionIdentifier,
                taskIdentifier: key.taskIdentifier
            )
        }

        publishTerminalSnapshot(
            terminalSnapshot(for: key, result: result.map { _ in () }),
            for: key
        )

        switch result {
        case .success(let value):
            state.continuation?.resume(returning: value)
        case .failure(let error):
            state.continuation?.resume(throwing: error)
        }
    }

    private func finishDownloadTask(
        key: TaskKey,
        result: Result<(URL, HTTPURLResponse), Error>
    ) {
        let state = withLock {
            downloadStates.removeValue(forKey: key)
        }

        guard let state else {
            return
        }

        Task {
            await recordStore.remove(
                sessionIdentifier: key.sessionIdentifier,
                taskIdentifier: key.taskIdentifier
            )
        }

        publishTerminalSnapshot(
            terminalSnapshot(for: key, result: result.map { _ in () }),
            for: key
        )

        switch result {
        case .success(let value):
            state.continuation?.resume(returning: value)
        case .failure(let error):
            state.continuation?.resume(throwing: error)
        }
    }

    private func completeBackgroundSessionEvents(for identifier: String) {
        let (handlers, session) = withLock { () -> ([() -> Void], URLSession?) in
            let handlers = sessionCompletionHandlers.removeValue(forKey: identifier) ?? []
            let session = sessions.removeValue(forKey: identifier)
            return (handlers, session)
        }

        session?.finishTasksAndInvalidate()
        handlers.forEach { $0() }
    }

    private func storeSnapshot(
        for key: TaskKey,
        kind: BackgroundTransferSnapshot.Kind,
        state: BackgroundTransferSnapshot.State,
        progress: FileTransferProgress?,
        destinationURL: URL?
    ) {
        let snapshot = BackgroundTransferSnapshot(
            sessionIdentifier: key.sessionIdentifier,
            taskIdentifier: key.taskIdentifier,
            kind: kind,
            state: state,
            progress: progress,
            destinationURL: destinationURL
        )
        publishActiveSnapshot(snapshot, for: key)
    }

    private func publishActiveSnapshot(_ snapshot: BackgroundTransferSnapshot, for key: TaskKey) {
        let continuations = withLock { () -> [AsyncStream<BackgroundTransferSnapshot>.Continuation] in
            activeSnapshots[key] = snapshot
            return Array(snapshotContinuations.values)
        }
        continuations.forEach { $0.yield(snapshot) }
    }

    private func publishTerminalSnapshot(_ snapshot: BackgroundTransferSnapshot, for key: TaskKey) {
        let continuations = withLock { () -> [AsyncStream<BackgroundTransferSnapshot>.Continuation] in
            activeSnapshots.removeValue(forKey: key)
            return Array(snapshotContinuations.values)
        }
        continuations.forEach { $0.yield(snapshot) }
    }

    private func terminalSnapshot(for key: TaskKey, result: Result<Void, Error>) -> BackgroundTransferSnapshot {
        let existingSnapshot = withLock { activeSnapshots[key] }
        let state: BackgroundTransferSnapshot.State

        switch result {
        case .success:
            state = .completed
        case .failure(let error as URLError) where error.code == .cancelled:
            state = .cancelled
        case .failure(let error):
            state = .failed(BackgroundTransferSnapshot.Failure(error: error))
        }

        return BackgroundTransferSnapshot(
            sessionIdentifier: key.sessionIdentifier,
            taskIdentifier: key.taskIdentifier,
            kind: existingSnapshot?.kind ?? .download,
            state: state,
            progress: existingSnapshot?.progress,
            destinationURL: existingSnapshot?.destinationURL
        )
    }

    private func validatedUploadResult(
        data: Data,
        response: HTTPURLResponse
    ) -> Result<(Data, HTTPURLResponse), Error> {
        do {
            try HTTPResponseProcessor.validate(
                response: response,
                data: data,
                coding: coding
            )
        } catch {
            return .failure(error)
        }
        return .success((data, response))
    }

    private func validatedDownloadResult(
        temporaryFileURL: URL,
        destinationURL: URL,
        response: HTTPURLResponse
    ) -> Result<(URL, HTTPURLResponse), Error> {
        if 200..<300 ~= response.statusCode {
            do {
                let finalURL = try moveDownloadedFile(
                    from: temporaryFileURL,
                    to: destinationURL
                )
                return .success((finalURL, response))
            } catch {
                return .failure(error)
            }
        }

        let data = (try? Data(contentsOf: temporaryFileURL)) ?? Data()
        try? FileManager.default.removeItem(at: temporaryFileURL)
        do {
            try HTTPResponseProcessor.validate(
                response: response,
                data: data,
                coding: coding
            )
            return .failure(APIError.server(statusCode: response.statusCode, message: "后台下载失败（HTTP \(response.statusCode)）。"))
        } catch {
            return .failure(error)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

extension BackgroundTransferCoordinator: URLSessionDataDelegate, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        isWaitingForConnectivity connectivity: Bool
    ) {
        guard connectivity,
              let sessionIdentifier = session.configuration.identifier else {
            return
        }

        let key = TaskKey(
            sessionIdentifier: sessionIdentifier,
            taskIdentifier: task.taskIdentifier
        )
        guard let snapshot = withLock({ activeSnapshots[key] }) else {
            return
        }

        publishActiveSnapshot(
            BackgroundTransferSnapshot(
                sessionIdentifier: snapshot.sessionIdentifier,
                taskIdentifier: snapshot.taskIdentifier,
                kind: snapshot.kind,
                state: .waitingForConnectivity,
                progress: snapshot.progress,
                destinationURL: snapshot.destinationURL
            ),
            for: key
        )
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let sessionIdentifier = session.configuration.identifier else {
            return
        }

        let key = TaskKey(
            sessionIdentifier: sessionIdentifier,
            taskIdentifier: task.taskIdentifier
        )
        guard let snapshot = withLock({ activeSnapshots[key] }) else {
            return
        }

        let progress = FileTransferProgress(
            transferredBytes: totalBytesSent,
            totalBytes: totalBytesExpectedToSend > 0 ? totalBytesExpectedToSend : nil,
            resumedBytes: 0
        )
        publishActiveSnapshot(
            BackgroundTransferSnapshot(
                sessionIdentifier: snapshot.sessionIdentifier,
                taskIdentifier: snapshot.taskIdentifier,
                kind: .upload,
                state: .running,
                progress: progress,
                destinationURL: snapshot.destinationURL
            ),
            for: key
        )
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let sessionIdentifier = session.configuration.identifier else {
            completionHandler(.allow)
            return
        }

        let key = TaskKey(
            sessionIdentifier: sessionIdentifier,
            taskIdentifier: dataTask.taskIdentifier
        )
        withLock {
            if var state = uploadStates[key] {
                state.response = response as? HTTPURLResponse
                uploadStates[key] = state
            }
            if var state = downloadStates[key] {
                state.response = response as? HTTPURLResponse
                downloadStates[key] = state
            }
        }
        completionHandler(.allow)
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard let sessionIdentifier = session.configuration.identifier else {
            return
        }

        let key = TaskKey(
            sessionIdentifier: sessionIdentifier,
            taskIdentifier: dataTask.taskIdentifier
        )
        withLock {
            if var state = uploadStates[key] {
                state.responseData.append(data)
                uploadStates[key] = state
            }
        }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let sessionIdentifier = session.configuration.identifier else {
            return
        }

        let key = TaskKey(
            sessionIdentifier: sessionIdentifier,
            taskIdentifier: downloadTask.taskIdentifier
        )
        guard let snapshot = withLock({ activeSnapshots[key] }) else {
            return
        }

        let progress = FileTransferProgress(
            transferredBytes: totalBytesWritten,
            totalBytes: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil,
            resumedBytes: 0
        )
        publishActiveSnapshot(
            BackgroundTransferSnapshot(
                sessionIdentifier: snapshot.sessionIdentifier,
                taskIdentifier: snapshot.taskIdentifier,
                kind: .download,
                state: .running,
                progress: progress,
                destinationURL: snapshot.destinationURL
            ),
            for: key
        )
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let sessionIdentifier = session.configuration.identifier else {
            return
        }

        let key = TaskKey(
            sessionIdentifier: sessionIdentifier,
            taskIdentifier: downloadTask.taskIdentifier
        )
        withLock {
            if var state = downloadStates[key] {
                state.temporaryFileURL = location
                downloadStates[key] = state
            }
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let sessionIdentifier = session.configuration.identifier else {
            return
        }

        let key = TaskKey(
            sessionIdentifier: sessionIdentifier,
            taskIdentifier: task.taskIdentifier
        )

        if withLock({ uploadStates[key] != nil }) {
            let result: Result<(Data, HTTPURLResponse), Error>
            if let error {
                result = .failure(error)
            } else if let state = withLock({ uploadStates[key] }),
                      let response = state.response ?? (task.response as? HTTPURLResponse)
            {
                result = validatedUploadResult(data: state.responseData, response: response)
            } else {
                result = .failure(APIError.invalidResponse)
            }

            finishUploadTask(key: key, result: result)
            return
        }

        if withLock({ downloadStates[key] != nil }) {
            let result: Result<(URL, HTTPURLResponse), Error>
            if let error {
                result = .failure(error)
            } else if let state = withLock({ downloadStates[key] }),
                      let temporaryFileURL = state.temporaryFileURL,
                      let response = state.response ?? (task.response as? HTTPURLResponse)
            {
                result = validatedDownloadResult(
                    temporaryFileURL: temporaryFileURL,
                    destinationURL: state.destinationURL,
                    response: response
                )
            } else {
                result = .failure(APIError.invalidResponse)
            }

            finishDownloadTask(key: key, result: result)
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else {
            return
        }
        completeBackgroundSessionEvents(for: identifier)
    }
}

private extension BackgroundTransferSnapshot {
    var kindSortOrder: Int {
        switch kind {
        case .upload:
            return 0
        case .download:
            return 1
        }
    }
}

private actor BackgroundTransferRecordStore {
    public static let shared = BackgroundTransferRecordStore()

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            return
        }

        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = baseDirectory.appendingPathComponent("BackgroundTransfers", isDirectory: true)
        self.fileURL = directory.appendingPathComponent("records.json")
    }

    public func records() -> [BackgroundTransferRecord] {
        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        return (try? JSONDecoder().decode([BackgroundTransferRecord].self, from: data)) ?? []
    }

    public func save(_ record: BackgroundTransferRecord) {
        var currentRecords = records()
        currentRecords.removeAll {
            $0.sessionIdentifier == record.sessionIdentifier &&
            $0.taskIdentifier == record.taskIdentifier
        }
        currentRecords.append(record)
        write(currentRecords)
    }

    public func remove(sessionIdentifier: String, taskIdentifier: Int) {
        var currentRecords = records()
        currentRecords.removeAll {
            $0.sessionIdentifier == sessionIdentifier &&
            $0.taskIdentifier == taskIdentifier
        }
        write(currentRecords)
    }

    private func write(_ records: [BackgroundTransferRecord]) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try? JSONEncoder().encode(records)
        try? data?.write(to: fileURL, options: .atomic)
    }
}

private struct BackgroundTransferRecord: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case upload
        case download
    }

    public let sessionIdentifier: String
    public let taskIdentifier: Int
    public let kind: Kind
    public let destinationPath: String?
    public let stagedFilePath: String?

    public var destinationURL: URL? {
        destinationPath.map(URL.init(fileURLWithPath:))
    }

    public var stagedFileURL: URL? {
        stagedFilePath.map(URL.init(fileURLWithPath:))
    }
}

private extension BackgroundTransferConfiguration {
    func sessionIdentifier(suffix: String) -> String {
        if let identifier, !identifier.isEmpty {
            return identifier
        }

        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "IMApp"
        return "\(bundleIdentifier).network.\(suffix).\(UUID().uuidString)"
    }

    func sessionConfiguration(identifier: String) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.isDiscretionary = isDiscretionary
        configuration.waitsForConnectivity = waitsForConnectivity
        configuration.sessionSendsLaunchEvents = true
        return configuration
    }
}

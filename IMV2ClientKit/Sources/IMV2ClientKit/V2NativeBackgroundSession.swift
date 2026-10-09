import Foundation
import Synchronization
#if os(iOS)
import UIKit

/// URLSession owns the OS task. Its serial delegate queue persists only opaque results;
/// protected business SQLite is never a prerequisite for the system completion handler.
public final class V2NativeBackgroundSession: NSObject, V2BackgroundSessionDriving, V2BackgroundDownloadSessionDriving, V2BackgroundProtectedDataChecking, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct State {
        var wake: @Sendable () async -> Void = {}
        var completed: Set<Int> = []
        var drains: [Int:[CheckedContinuation<Void,Never>]] = [:]
        var responseBytes: [Int:Int] = [:]
        var downloadErrors: [Int:Int] = [:]
    }
    private let state=Mutex(State())
    private let inbox:V2BackgroundResultInbox
    private let isDownload: Bool
    public let identifier:String
    private var session:URLSession!
    private var protectedDataObserver:(any NSObjectProtocol)?
    private static let registry=Mutex<[String:V2NativeBackgroundSession]>([:])
    public static func shared(sessionID:UUID,root:URL) throws -> V2NativeBackgroundSession {
        try shared(sessionID: sessionID, root: root, download: false)
    }
    public static func sharedDownload(sessionID: UUID, root: URL) throws -> V2NativeBackgroundSession {
        try shared(sessionID: sessionID, root: root, download: true)
    }
    private static func shared(sessionID: UUID, root: URL, download: Bool) throws -> V2NativeBackgroundSession {
        let name = (download ? "imv2.background.download." : "imv2.background.") + sessionID.uuidString.lowercased()
        return try registry.withLock { values in
            if let existing=values[name] { return existing }
            guard values.count<16 else { throw V2BackgroundTransferError.capacityExceeded }
            let value=try V2NativeBackgroundSession(sessionID:sessionID,root:root,download:download);values[name]=value;return value
        }
    }
    private init(sessionID:UUID,root:URL,download:Bool) throws {
        isDownload = download
        identifier = (download ? "imv2.background.download." : "imv2.background.") + sessionID.uuidString.lowercased()
        inbox = try .init(root: download ? root.appendingPathComponent("downloads", isDirectory: true) : root, sessionID: sessionID)
        super.init()
        protectedDataObserver=NotificationCenter.default.addObserver(forName:UIApplication.protectedDataDidBecomeAvailableNotification,object:nil,queue:nil) { [weak self] _ in
            guard let self else { return }
            let wake=self.state.withLock { $0.wake }
            Task { await wake() }
        }
        let configuration=URLSessionConfiguration.background(withIdentifier:identifier)
        configuration.httpCookieStorage=nil;configuration.httpShouldSetCookies=false;configuration.urlCache=nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest=30;configuration.timeoutIntervalForResource=900
        configuration.httpMaximumConnectionsPerHost=2;configuration.isDiscretionary=false
        configuration.sessionSendsLaunchEvents=true;configuration.waitsForConnectivity=true
        let queue=OperationQueue();queue.maxConcurrentOperationCount=1;queue.name="IMV2.BackgroundTransferDelegate"
        session=URLSession(configuration:configuration,delegate:self,delegateQueue:queue)
    }
    public func installWake(_ wake:@escaping @Sendable () async -> Void) async { state.withLock { $0.wake=wake } }
    private func rawTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in session.getAllTasks { continuation.resume(returning:$0) } }
    }
    public func tasks() async -> [V2BackgroundSystemTask] {
        await rawTasks().map { .init(identifier:$0.taskIdentifier,mappingID:$0.taskDescription.flatMap(UUID.init(uuidString:)),suspended:$0.state == .suspended) }
    }
    public func create(request:URLRequest,file:URL,mappingID:UUID) async throws -> Int {
        try Task.checkCancellation()
        guard !isDownload else { throw V2BackgroundTransferError.unsupported }
        let task=session.uploadTask(with:request,fromFile:file)
        task.taskDescription=mappingID.uuidString
        return task.taskIdentifier
    }
    public func create(target: V2ClientMediaTransferTarget, mappingID: UUID) async throws -> Int {
        try Task.checkCancellation()
        guard isDownload else { throw V2BackgroundTransferError.unsupported }
        let task = session.downloadTask(with: try V2BackgroundDownloadRequest.make(target: target))
        task.taskDescription = mappingID.uuidString
        return task.taskIdentifier
    }
    /// A protected staging hint, never a published presentation file. The account
    /// coordinator must verify its durable mapping and freshly reauthorize before use.
    public func downloadedFile(mappingID: UUID) -> URL {
        inbox.directory.appendingPathComponent("files", isDirectory: true).appendingPathComponent(mappingID.uuidString)
    }
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard isDownload, let mappingID = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else {
            downloadTask.cancel(); return
        }
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let facts = try location.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard facts.isRegularFile == true, let size = facts.fileSize, size > 0, size <= 512 * 1_024 * 1_024
            else { throw V2BackgroundTransferError.capacityExceeded }
            let file = downloadedFile(mappingID: mappingID), directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let protection = V2SystemResourceFileProtectionWriter()
            try protection.apply(.complete, to: directory)
            var excluded = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            // The serial system delegate owns this short file handoff. It must
            // retain the OS temporary file before this callback returns.
            try V2ResourceStagingBudget.withCopy(directory: directory, additionalBytes: Int64(size)) {
                guard !FileManager.default.fileExists(atPath: file.path) else { throw V2BackgroundTransferError.mappingConflict }
                try FileManager.default.moveItem(at: location, to: file)
                do {
                    try protection.apply(.complete, to: file)
                    let handle = try FileHandle(forWritingTo: file)
                    defer { try? handle.close() }
                    try handle.synchronize()
                } catch { try? FileManager.default.removeItem(at: file); throw error }
            }
        } catch {
            state.withLock { $0.downloadErrors[downloadTask.taskIdentifier] = URLError.cannotWriteToFile.rawValue }
        }
    }
    public func resume(_ identifier:Int) async throws {
        try Task.checkCancellation()
        guard let task=await rawTasks().first(where:{$0.taskIdentifier==identifier}) else { throw V2BackgroundTransferError.mappingConflict }
        task.resume()
    }
    public func cancelAndDrain(_ identifiers:[Int]) async {
        let targets=await rawTasks().filter { identifiers.contains($0.taskIdentifier) }
        await withTaskGroup(of:Void.self) { group in
            for target in targets {
                group.addTask {
                    await withCheckedContinuation { continuation in
                        let complete=self.state.withLock { value in
                            if value.completed.contains(target.taskIdentifier) { return true }
                            value.drains[target.taskIdentifier,default:[]].append(continuation);return false
                        }
                        if complete { continuation.resume() }
                        else { target.cancel() }
                    }
                }
            }
            await group.waitForAll()
        }
    }
    public func invalidateAfterDrain() {
        if let observer=protectedDataObserver { NotificationCenter.default.removeObserver(observer);protectedDataObserver=nil }
        session.invalidateAndCancel()
        Self.registry.withLock { $0[identifier]=nil }
        // Logout may invalidate the session before Foundation delivers its final
        // events callback. Actual tasks have already drained; never strand UIKit.
        Task { @MainActor in V2BackgroundTransferEvents.finished(identifier:self.identifier) }
    }
    public func protectedDataAvailable() async -> Bool {
        await MainActor.run { UIApplication.shared.isProtectedDataAvailable }
    }
    public func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data) {
        let tooLarge=state.withLock { value in
            let count=value.responseBytes[dataTask.taskIdentifier,default:0]
            guard data.count<=65_536-count else { return true }
            value.responseBytes[dataTask.taskIdentifier]=count+data.count;return false
        }
        if tooLarge { dataTask.cancel() }
    }
    public func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:(any Error)?) {
        let response=task.response as? HTTPURLResponse
        let downloadError = state.withLock { $0.downloadErrors.removeValue(forKey: task.taskIdentifier) }
        if let mappingID=task.taskDescription.flatMap(UUID.init(uuidString:)) {
            let result=V2BackgroundTransferResult(mappingID:mappingID,taskIdentifier:task.taskIdentifier,
                statusCode:response?.statusCode,errorCode:(error as NSError?)?.code ?? downloadError,sentBytes:task.countOfBytesSent,
                originDigest:V2BackgroundResultInbox.originDigest(response?.url),
                retryNotBefore:V2RetryAfter.date(from:response?.value(forHTTPHeaderField:"Retry-After")),
                receivedBytes:task.countOfBytesReceived)
            // If first-unlock protection prevents this write, the Complete business mapping
            // remains. Missing system tasks reconcile the original job after unlock.
            try? inbox.write(result)
            if isDownload {
                if error != nil || downloadError != nil { try? FileManager.default.removeItem(at: downloadedFile(mappingID: mappingID)) }
            } else {
                let source=inbox.directory.appendingPathComponent("sources",isDirectory:true).appendingPathComponent(mappingID.uuidString)
                try? FileManager.default.removeItem(at:source)
            }
        }
        let callbacks=state.withLock { value -> ([CheckedContinuation<Void,Never>],@Sendable () async -> Void) in
            value.completed.insert(task.taskIdentifier)
            if value.completed.count>128 { value.completed=Set(value.completed.sorted().suffix(128)) }
            value.responseBytes[task.taskIdentifier]=nil
            return (value.drains.removeValue(forKey:task.taskIdentifier) ?? [],value.wake)
        }
        for callback in callbacks.0 { callback.resume() }
        Task { await callbacks.1() }
    }
    public func urlSessionDidFinishEvents(forBackgroundURLSession session:URLSession) {
        // Every preceding completion persisted its inbox synchronously on this serial queue.
        Task { @MainActor in V2BackgroundTransferEvents.finished(identifier:self.identifier) }
    }
    // Background sessions do not call redirect rejection delegates. Only native redirect-free
    // provider grants are eligible, and result origin is independently checked before reconciliation.
}

@MainActor
public enum V2BackgroundTransferEvents {
    private static var handlers:[String:() -> Void]=[:]
    public static func handle(identifier:String,root:URL,completion:@escaping () -> Void) {
        let download = identifier.hasPrefix("imv2.background.download.")
        let prefix = download ? "imv2.background.download." : "imv2.background."
        guard identifier.hasPrefix(prefix),let id=UUID(uuidString:String(identifier.dropFirst(prefix.count))) else { completion();return }
        guard handlers.count<16 || handlers[identifier] != nil else { completion();return }
        if let previous=handlers.updateValue(completion,forKey:identifier) { previous() }
        do {
            if download { _ = try V2NativeBackgroundSession.sharedDownload(sessionID: id, root: root) }
            else { _ = try V2NativeBackgroundSession.shared(sessionID:id,root:root) }
        }
        catch { finished(identifier:identifier) }
    }
    static func finished(identifier:String) { handlers.removeValue(forKey:identifier)?() }
}
#endif

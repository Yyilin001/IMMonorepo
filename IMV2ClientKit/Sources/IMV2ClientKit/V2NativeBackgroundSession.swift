import Foundation
import Synchronization
#if os(iOS)
import UIKit

/// URLSession owns the OS task. Its serial delegate queue persists only opaque results;
/// protected business SQLite is never a prerequisite for the system completion handler.
public final class V2NativeBackgroundSession: NSObject, V2BackgroundSessionDriving, V2BackgroundProtectedDataChecking, URLSessionDataDelegate, @unchecked Sendable {
    private struct State {
        var wake: @Sendable () async -> Void = {}
        var completed: Set<Int> = []
        var drains: [Int:[CheckedContinuation<Void,Never>]] = [:]
        var responseBytes: [Int:Int] = [:]
    }
    private let state=Mutex(State())
    private let inbox:V2BackgroundResultInbox
    public let identifier:String
    private var session:URLSession!
    private var protectedDataObserver:(any NSObjectProtocol)?
    private static let registry=Mutex<[String:V2NativeBackgroundSession]>([:])
    public static func shared(sessionID:UUID,root:URL) throws -> V2NativeBackgroundSession {
        let name="imv2.background."+sessionID.uuidString.lowercased()
        return try registry.withLock { values in
            if let existing=values[name] { return existing }
            guard values.count<16 else { throw V2BackgroundTransferError.capacityExceeded }
            let value=try V2NativeBackgroundSession(sessionID:sessionID,root:root);values[name]=value;return value
        }
    }
    private init(sessionID:UUID,root:URL) throws {
        identifier="imv2.background."+sessionID.uuidString.lowercased();inbox=try .init(root:root,sessionID:sessionID)
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
        let task=session.uploadTask(with:request,fromFile:file)
        task.taskDescription=mappingID.uuidString
        return task.taskIdentifier
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
        if let mappingID=task.taskDescription.flatMap(UUID.init(uuidString:)) {
            let result=V2BackgroundTransferResult(mappingID:mappingID,taskIdentifier:task.taskIdentifier,
                statusCode:response?.statusCode,errorCode:(error as NSError?)?.code,sentBytes:task.countOfBytesSent,
                originDigest:V2BackgroundResultInbox.originDigest(response?.url),
                retryNotBefore:V2RetryAfter.date(from:response?.value(forHTTPHeaderField:"Retry-After")),
                receivedBytes:task.countOfBytesReceived)
            // If first-unlock protection prevents this write, the Complete business mapping
            // remains. Missing system tasks reconcile the original job after unlock.
            try? inbox.write(result)
            let source=inbox.directory.appendingPathComponent("sources",isDirectory:true).appendingPathComponent(mappingID.uuidString)
            try? FileManager.default.removeItem(at:source)
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
        let prefix="imv2.background."
        guard identifier.hasPrefix(prefix),let id=UUID(uuidString:String(identifier.dropFirst(prefix.count))) else { completion();return }
        guard handlers.count<16 || handlers[identifier] != nil else { completion();return }
        if let previous=handlers.updateValue(completion,forKey:identifier) { previous() }
        do { _ = try V2NativeBackgroundSession.shared(sessionID:id,root:root) }
        catch { finished(identifier:identifier) }
    }
    static func finished(identifier:String) { handlers.removeValue(forKey:identifier)?() }
}
#endif
